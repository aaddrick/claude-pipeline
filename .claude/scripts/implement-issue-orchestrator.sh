#!/usr/bin/env bash
#
# implement-issue-orchestrator.sh
# Orchestrates implement-issue workflow via Claude CLI calls per stage
#
# Usage:
#   ./implement-issue-orchestrator.sh --issue 123 --branch test
#   ./implement-issue-orchestrator.sh --issue 123 --branch test --agent laravel-backend-developer
#
# Outputs:
#   - logs/implement-issue/<issue>-<timestamp>/status.json: Real-time progress (per-issue)
#   - logs/implement-issue/<issue>-<timestamp>/orchestrator.log: Combined log (tail -f friendly)
#   - logs/implement-issue/<issue>-<timestamp>/stages/: Per-stage logs
#

set -uo pipefail  # Note: not -e, we handle errors explicitly

# Allow nested Claude CLI invocations when run from within a Claude Code session
unset CLAUDECODE

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/schemas"

# Timeouts and limits
readonly STAGE_TIMEOUT=3600  # 1 hour per stage
readonly MAX_TASK_REVIEW_ATTEMPTS=3
readonly MAX_QUALITY_ITERATIONS=5
readonly MAX_TEST_ITERATIONS=10
readonly MAX_PR_REVIEW_ITERATIONS=3
readonly RATE_LIMIT_BUFFER=60
readonly RATE_LIMIT_DEFAULT_WAIT=3600
readonly LOCK_DIR="logs/implement-issue/locks"
readonly GIT_RETRY_ATTEMPTS=3
readonly GIT_RETRY_DELAY=2
readonly RETRO_MEMORY_FILE="logs/implement-issue/process-retrospective.md"
RETRO_RAN=false

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

ISSUE_NUMBER=""
BASE_BRANCH=""
AGENT=""
STATUS_FILE=""
RESUME_MODE=""
RESUME_LOG_DIR=""

usage() {
    cat <<EOF
Usage: $0 --issue <number> --branch <name> [options]
       $0 --resume --status-file <path>
       $0 --resume-from <log-dir>

Options:
  --issue <number>       GitHub issue number (required for new runs)
  --branch <name>        Base branch for PR (required for new runs)
  --agent <name>         Default agent for setup stage (optional)
  --status-file <path>   Custom status file path (default: <log-dir>/status.json)
  --resume               Resume from status file (requires --status-file or --resume-from)
  --resume-from <dir>    Resume from specific log directory

Resume modes:
  --resume --status-file <path>  resumes from the given status.json
  --resume-from <dir>            reads status.json from the specified log directory

Each run creates its own status.json in the log directory.
A per-issue lock prevents parallel sessions on the same issue number.
Agents are determined per-task from setup output.
EOF
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [[ -n "${2:-}" ]] || { echo "ERROR: --issue requires a value" >&2; exit 3; }
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --branch requires a value" >&2; exit 3; }
            BASE_BRANCH="$2"
            shift 2
            ;;
        --agent)
            [[ -n "${2:-}" ]] || { echo "ERROR: --agent requires a value" >&2; exit 3; }
            AGENT="$2"
            shift 2
            ;;
        --status-file)
            [[ -n "${2:-}" ]] || { echo "ERROR: --status-file requires a value" >&2; exit 3; }
            STATUS_FILE="$2"
            shift 2
            ;;
        --resume)
            RESUME_MODE="status"
            shift
            ;;
        --resume-from)
            [[ -n "${2:-}" ]] || { echo "ERROR: --resume-from requires a log directory path" >&2; exit 3; }
            RESUME_MODE="logdir"
            RESUME_LOG_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments based on mode
if [[ -n "$RESUME_MODE" ]]; then
    # Resume mode - issue and branch will be read from status.json
    :
elif [[ -z "$ISSUE_NUMBER" || -z "$BASE_BRANCH" ]]; then
    echo "ERROR: --issue and --branch are required (or use --resume/--resume-from)"
    usage
fi

# =============================================================================
# LOGGING FUNCTIONS (defined early so other functions can use log/log_error)
# Note: LOG_FILE and mkdir happen later after LOG_BASE is set
# =============================================================================

LOG_FILE=""
STAGE_COUNTER=0

log() {
    local msg="[$(date -Iseconds)] $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

log_error() {
    local msg="[$(date -Iseconds)] ERROR: $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

next_stage_log() {
    local stage_name="$1"
    STAGE_COUNTER=$((STAGE_COUNTER + 1))
    printf "%02d-%s.log" "$STAGE_COUNTER" "$stage_name"
}

# =============================================================================
# STATUS FILE MANAGEMENT
# =============================================================================

init_status() {
    jq -n \
        --arg state "initializing" \
        --argjson issue "$ISSUE_NUMBER" \
        --arg base_branch "$BASE_BRANCH" \
        --arg branch "" \
        --arg worktree "" \
        --arg current_stage "setup" \
        --argjson current_task "null" \
        --arg log_dir "$LOG_BASE" \
        --arg log_file "$LOG_BASE/orchestrator.log" \
        '{
            state: $state,
            issue: $issue,
            base_branch: $base_branch,
            branch: $branch,
            worktree: $worktree,
            current_stage: $current_stage,
            current_task: $current_task,
            log_file: $log_file,
            stages: {
                setup: {status: "pending", started_at: null, completed_at: null},
                research: {status: "pending", started_at: null, completed_at: null},
                evaluate: {status: "pending", started_at: null, completed_at: null},
                plan: {status: "pending", started_at: null, completed_at: null},
                implement: {status: "pending", task_progress: "0/0"},
                quality_loop: {status: "pending", iteration: 0},
                test_loop: {status: "pending", iteration: 0},
                docs: {status: "pending"},
                pr: {status: "pending"},
                pr_review: {status: "pending", iteration: 0},
                tech_docs: {status: "pending"},
                complete: {status: "pending"},
                retrospective: {status: "pending"}
            },
            tasks: [],
            quality_iterations: 0,
            test_iterations: 0,
            pr_review_iterations: 0,
            last_update: (now | todate),
            log_dir: $log_dir
        }' > "$STATUS_FILE"

    log "Initialized status file: $STATUS_FILE"
    sync_status_to_log
}

update_stage() {
    local stage="$1"
    local status="$2"
    local extra_field="${3:-}"
    local extra_value="${4:-}"

    if [[ -n "$extra_field" ]]; then
        jq --arg stage "$stage" \
           --arg status "$status" \
           --arg field "$extra_field" \
           --arg value "$extra_value" \
           '.stages[$stage].status = $status |
            .stages[$stage][$field] = $value |
            .current_stage = $stage |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    else
        jq --arg stage "$stage" \
           --arg status "$status" \
           '.stages[$stage].status = $status |
            .current_stage = $stage |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    fi
    sync_status_to_log
}

set_stage_started() {
    local stage="$1"
    jq --arg stage "$stage" \
       '.stages[$stage].started_at = (now | todate) |
        .stages[$stage].status = "in_progress" |
        .current_stage = $stage |
        .state = "running" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_stage_completed() {
    local stage="$1"
    jq --arg stage "$stage" \
       '.stages[$stage].completed_at = (now | todate) |
        .stages[$stage].status = "completed" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

update_task() {
    local task_id="$1"
    local status="$2"
    local review_attempts="${3:-0}"

    jq --argjson id "$task_id" \
       --arg status "$status" \
       --argjson attempts "$review_attempts" \
       '(.tasks[] | select(.id == $id)).status = $status |
        (.tasks[] | select(.id == $id)).review_attempts = $attempts |
        .current_task = $id |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_tasks() {
    local tasks_json="$1"
    jq --argjson tasks "$tasks_json" \
       '.tasks = $tasks |
        .stages.implement.task_progress = "0/\($tasks | length)" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_worktree_info() {
    local worktree="$1"
    local branch="$2"
    jq --arg worktree "$worktree" \
       --arg branch "$branch" \
       '.worktree = $worktree | .branch = $branch | .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_final_state() {
    local state="$1"
    jq --arg state "$state" \
       '.state = $state | .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_quality_iteration() {
    jq '.quality_iterations += 1 |
        .stages.quality_loop.iteration = .quality_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_test_iteration() {
    jq '.test_iterations += 1 |
        .stages.test_loop.iteration = .test_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_pr_review_iteration() {
    jq '.pr_review_iterations += 1 |
        .stages.pr_review.iteration = .pr_review_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

# =============================================================================
# RESUME FUNCTIONALITY
# =============================================================================

# Validate that a status file has required fields for resumption
# Returns 0 if valid, 1 if invalid
validate_resume_status() {
    local status_path="$1"

    if [[ ! -f "$status_path" ]]; then
        echo "ERROR: Status file not found: $status_path" >&2
        return 1
    fi

    # Check required fields exist
    local required_fields=("issue" "branch" "worktree" "current_stage" "log_dir")
    local field
    for field in "${required_fields[@]}"; do
        local value
        value=$(jq -r ".$field // empty" "$status_path" 2>/dev/null)
        if [[ -z "$value" || "$value" == "null" ]]; then
            echo "ERROR: Status file missing required field: $field" >&2
            return 1
        fi
    done

    # Check state is resumable (not already completed or in error)
    local state
    state=$(jq -r '.state' "$status_path" 2>/dev/null)
    if [[ "$state" == "completed" ]]; then
        echo "ERROR: Cannot resume - workflow already completed" >&2
        return 1
    fi

    return 0
}

# Load resume state from status file
# Sets global variables: ISSUE_NUMBER, BASE_BRANCH, LOG_BASE, WORKTREE, BRANCH
# Also sets: RESUME_STAGE, RESUME_TASK, RESUME_TASKS_JSON
load_resume_state() {
    local status_path="$1"

    ISSUE_NUMBER=$(jq -r '.issue' "$status_path")
    # Restore BASE_BRANCH from status file (fall back to command-line value if not stored)
    local stored_base_branch
    stored_base_branch=$(jq -r '.base_branch // empty' "$status_path")
    if [[ -n "$stored_base_branch" ]]; then
        BASE_BRANCH="$stored_base_branch"
    elif [[ -z "$BASE_BRANCH" ]]; then
        echo "WARNING: No base_branch in status file and none provided via --branch" >&2
    fi
    BRANCH=$(jq -r '.branch' "$status_path")
    WORKTREE=$(jq -r '.worktree' "$status_path")
    LOG_BASE=$(jq -r '.log_dir' "$status_path")

    RESUME_STAGE=$(jq -r '.current_stage' "$status_path")
    RESUME_TASK=$(jq -r '.current_task // 0' "$status_path")
    RESUME_TASKS_JSON=$(jq -c '.tasks // []' "$status_path")

    # Restore iteration counters
    RESUME_QUALITY_ITERATIONS=$(jq -r '.quality_iterations // 0' "$status_path")
    RESUME_TEST_ITERATIONS=$(jq -r '.test_iterations // 0' "$status_path")
    RESUME_PR_ITERATIONS=$(jq -r '.pr_review_iterations // 0' "$status_path")

    # Get PR number if it exists
    RESUME_PR_NUMBER=$(jq -r '.stages.pr.pr_number // empty' "$status_path")
}

# Check if a stage is completed in status file
# Returns 0 if completed, 1 if not
is_stage_completed() {
    local stage="$1"
    local status
    status=$(jq -r ".stages.$stage.status" "$STATUS_FILE" 2>/dev/null)
    [[ "$status" == "completed" ]]
}

# Get count of completed tasks
get_completed_task_count() {
    jq '[.tasks[] | select(.status == "completed")] | length' "$STATUS_FILE" 2>/dev/null || echo "0"
}

# Check if worktree exists and is valid
validate_worktree() {
    local worktree_path="$1"

    if [[ ! -d "$worktree_path" ]]; then
        echo "ERROR: Worktree not found: $worktree_path" >&2
        return 1
    fi

    if [[ ! -d "$worktree_path/.git" && ! -f "$worktree_path/.git" ]]; then
        echo "ERROR: Path is not a git worktree: $worktree_path" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# PER-ISSUE LOCK (prevents two sessions working on the same issue)
# =============================================================================

LOCK_FILE=""

acquire_issue_lock() {
    local issue="$1"
    mkdir -p "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/issue-${issue}.lock"

    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR: Another session is already working on issue #$issue (PID: $lock_pid)" >&2
            echo "  Lock file: $LOCK_FILE" >&2
            echo "  To force, remove the lock file and retry." >&2
            exit 3
        fi
        # Stale lock — previous process died
        echo "WARNING: Removing stale lock for issue #$issue (PID $lock_pid no longer running)" >&2
    fi

    echo $$ > "$LOCK_FILE"
    log "Acquired lock for issue #$issue (PID: $$)"
}

release_issue_lock() {
    if [[ -n "$LOCK_FILE" && -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # Only remove if we own it
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

cleanup_on_exit() {
    local trap_exit_code=$?
    # Run retrospective (non-blocking: failures don't change exit code)
    run_retrospective "$trap_exit_code" || true
    release_issue_lock
    exit "$trap_exit_code"
}
trap cleanup_on_exit EXIT

# =============================================================================
# GIT RETRY HELPER (serializes git operations with retry on lock contention)
# =============================================================================

git_with_retry() {
    local attempt=0
    while (( attempt < GIT_RETRY_ATTEMPTS )); do
        if git "$@" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        if (( attempt < GIT_RETRY_ATTEMPTS )); then
            log "Git operation failed (attempt $attempt/$GIT_RETRY_ATTEMPTS), retrying in ${GIT_RETRY_DELAY}s..."
            sleep "$GIT_RETRY_DELAY"
        fi
    done
    log_error "Git operation failed after $GIT_RETRY_ATTEMPTS attempts: git $*"
    return 1
}

# =============================================================================
# RESUME MODE INITIALIZATION
# =============================================================================

# These will be populated in resume mode
WORKTREE=""
BRANCH=""
RESUME_STAGE=""
RESUME_TASK=""
RESUME_TASKS_JSON=""
RESUME_QUALITY_ITERATIONS=0
RESUME_TEST_ITERATIONS=0
RESUME_PR_ITERATIONS=0
RESUME_PR_NUMBER=""

if [[ "$RESUME_MODE" == "logdir" ]]; then
    # Resume from specific log directory
    if [[ ! -d "$RESUME_LOG_DIR" ]]; then
        echo "ERROR: Log directory not found: $RESUME_LOG_DIR" >&2
        exit 1
    fi

    local_status_file="$RESUME_LOG_DIR/status.json"
    if [[ ! -f "$local_status_file" ]]; then
        # Try parent directory's status.json (log_dir may be relative)
        local_status_file="status.json"
    fi

    if ! validate_resume_status "$local_status_file"; then
        exit 1
    fi

    load_resume_state "$local_status_file"
    STATUS_FILE="$local_status_file"
    # LOG_BASE was set by load_resume_state

    if ! validate_worktree "$WORKTREE"; then
        exit 1
    fi

elif [[ "$RESUME_MODE" == "status" ]]; then
    # Resume from status file — requires --status-file since there's no global default
    if [[ -z "$STATUS_FILE" ]]; then
        echo "ERROR: --resume requires --status-file <path> (no default status.json exists)" >&2
        echo "  Tip: use --resume-from <log-dir> to resume from a log directory" >&2
        exit 3
    fi

    if ! validate_resume_status "$STATUS_FILE"; then
        exit 1
    fi

    load_resume_state "$STATUS_FILE"

    if ! validate_worktree "$WORKTREE"; then
        exit 1
    fi

else
    # Normal mode - set LOG_BASE with high-precision timestamp + PID to avoid collisions
    LOG_BASE="logs/implement-issue/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M%S)-$$"
fi

# Set STATUS_FILE to live inside LOG_BASE (per-issue, no shared root file)
if [[ -z "$STATUS_FILE" ]]; then
    STATUS_FILE="$LOG_BASE/status.json"
fi

# Acquire per-issue lock (prevents parallel sessions on same issue)
acquire_issue_lock "$ISSUE_NUMBER"

# Display mode info
if [[ -n "$RESUME_MODE" ]]; then
    echo "Implement Issue Orchestrator (RESUME MODE)"
    echo "Resuming from: $STATUS_FILE"
    echo "Issue: #$ISSUE_NUMBER"
    echo "Branch: $BRANCH"
    echo "Worktree: $WORKTREE"
    echo "Resume stage: $RESUME_STAGE"
    [[ -n "$RESUME_TASK" && "$RESUME_TASK" != "null" ]] && echo "Resume task: $RESUME_TASK"
    echo "Log dir: $LOG_BASE"
else
    echo "Implement Issue Orchestrator"
    echo "Issue: #$ISSUE_NUMBER"
    echo "Branch: $BASE_BRANCH"
    echo "Agent: ${AGENT:-default}"
    echo "Log dir: $LOG_BASE"
    echo "Status file: $STATUS_FILE"
    echo "Lock: $LOCK_FILE (PID: $$)"
fi

# Create log directories
mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
LOG_FILE="$LOG_BASE/orchestrator.log"
STAGE_COUNTER=0

# =============================================================================
# STATUS SYNC TO LOG DIRECTORY
# =============================================================================

# Sync status.json to log directory after every update
# Since STATUS_FILE now defaults to LOG_BASE/status.json, this is usually a no-op.
# It still handles the case where --status-file points elsewhere.
sync_status_to_log() {
	if [[ -n "$LOG_BASE" && -d "$LOG_BASE" && -f "$STATUS_FILE" ]]; then
		local target="$LOG_BASE/status.json"
		# Avoid copying file to itself (normal case: STATUS_FILE is already in LOG_BASE)
		if [[ "$(realpath "$STATUS_FILE" 2>/dev/null)" != "$(realpath "$target" 2>/dev/null)" ]]; then
			cp "$STATUS_FILE" "$target"
		fi
	fi
}

# =============================================================================
# GITHUB COMMENT HELPERS
# =============================================================================

REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s/\.git$//')

# comment_issue <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
comment_issue() {
	local title="$1"
	local body="$2"
	local agent="${3:-}"
	local attribution

	if [[ -n "$agent" ]]; then
		attribution="Written by \`$agent\`"
	else
		attribution="Posted by \`implement-issue-orchestrator\`"
	fi

	local comment
	comment=$(cat <<EOF
## $title
###### *$attribution*

$body
EOF
)

	log "Commenting on issue #$ISSUE_NUMBER: $title"
	if ! gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$comment" 2>/dev/null; then
		log_error "Failed to comment on issue #$ISSUE_NUMBER"
	fi
}

# comment_pr <pr_num> <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
comment_pr() {
	local pr_num="$1"
	local title="$2"
	local body="$3"
	local agent="${4:-}"
	local attribution

	if [[ -n "$agent" ]]; then
		attribution="Written by \`$agent\`"
	else
		attribution="Posted by \`implement-issue-orchestrator\`"
	fi

	local comment
	comment=$(cat <<EOF
## $title
###### *$attribution*

$body
EOF
)

	log "Commenting on PR #$pr_num: $title"
	if ! gh pr comment "$pr_num" --repo "$REPO" --body "$comment" 2>/dev/null; then
		log_error "Failed to comment on PR #$pr_num"
	fi
}

# =============================================================================
# RATE LIMIT DETECTION
# =============================================================================

detect_rate_limit() {
    local output="$1"

    # Check structured output first
    local status
    status=$(printf '%s' "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

    if [[ "$status" == "success" ]]; then
        return 1
    fi

    if [[ "$status" == "rate_limit" ]]; then
        return 0
    fi

    # Only check text patterns if there's an actual error
    # (prevents false positives when reviews mention "rate limiting" as a feature)
    local is_error
    is_error=$(printf '%s' "$output" | jq -r '.is_error // false' 2>/dev/null)

    if [[ "$is_error" != "true" ]]; then
        return 1
    fi

    # Fallback to text pattern matching (only for errors)
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    if printf '%s' "$result" | grep -qiE 'rate.limit|429|too many requests|quota.exceeded'; then
        return 0
    fi

    return 1
}

extract_wait_time() {
    local output="$1"
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    local search_text="$result $output"

    # Try retry-after
    local retry_after
    retry_after=$(printf '%s' "$search_text" | grep -oiE 'retry.after[^0-9]*([0-9]+)' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$retry_after" ]] && (( retry_after > 0 )); then
        printf '%s\n' "$retry_after"
        return
    fi

    # Try wait X minutes
    local wait_mins
    wait_mins=$(printf '%s' "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*min' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_mins" ]] && (( wait_mins > 0 )); then
        printf '%s\n' "$((wait_mins * 60))"
        return
    fi

    printf '%s\n' "$RATE_LIMIT_DEFAULT_WAIT"
}

handle_rate_limit() {
    local output="$1"
    local wait_time
    wait_time=$(extract_wait_time "$output")
    wait_time=$((wait_time + RATE_LIMIT_BUFFER))

    local resume_at
    resume_at=$(date -Iseconds -d "+${wait_time} seconds" 2>/dev/null || date -v+${wait_time}S -Iseconds 2>/dev/null)

    log "Rate limit hit. Waiting ${wait_time}s until $resume_at"
    sleep "$wait_time"
}

# =============================================================================
# STAGE RUNNERS
# =============================================================================

run_stage() {
    local stage_name="$1"
    local prompt="$2"
    local schema_file="$3"
    local agent="${4:-}"

    local stage_log="$LOG_BASE/stages/$(next_stage_log "$stage_name")"

    # Validate schema file exists
    if [[ ! -f "$SCHEMA_DIR/$schema_file" ]]; then
        log_error "Schema file not found: $SCHEMA_DIR/$schema_file"
        echo '{"status":"error","error":"schema not found"}'
        return 1
    fi

    local schema
    schema=$(jq -c . "$SCHEMA_DIR/$schema_file")

    log "Running stage: $stage_name"
    log "  Schema: $schema_file"
    log "  Agent: ${agent:-default}"
    log "  Log: $stage_log"

    local -a agent_args=()
    if [[ -n "$agent" ]]; then
        agent_args=(--agent "$agent")
    fi

    local output
    local exit_code=0

    # Run claude in the worktree directory when available (subshell preserves orchestrator cwd)
    local run_dir="${WORKTREE:-.}"
    output=$(cd "$run_dir" && timeout "$STAGE_TIMEOUT" claude -p "$prompt" \
        "${agent_args[@]}" \
        --no-session-persistence \
        --dangerously-skip-permissions \
        --strict-mcp-config \
        --output-format json \
        --json-schema "$schema" \
        < /dev/null 2>&1) || exit_code=$?

    printf '%s\n' "=== $stage_name output ===" >> "$stage_log"
    printf '%s\n' "$output" >> "$stage_log"
    printf '%s\n' "=== exit code: $exit_code ===" >> "$stage_log"

    # Also write to combined log for tail -f
    if [[ -n "$LOG_FILE" ]]; then
        printf '[%s] === %s output (exit: %d) ===\n' "$(date -Iseconds)" "$stage_name" "$exit_code" >> "$LOG_FILE"
        printf '%s\n' "$output" >> "$LOG_FILE"
    fi

    # Check timeout
    if (( exit_code == 124 )); then
        log_error "Stage $stage_name timed out after ${STAGE_TIMEOUT}s"
        echo '{"status":"error","error":"timeout"}'
        return 1
    fi

    # Check rate limit
    if detect_rate_limit "$output"; then
        handle_rate_limit "$output"
        # Retry
        output=$(cd "$run_dir" && timeout "$STAGE_TIMEOUT" claude -p "$prompt" \
            "${agent_args[@]}" \
            --no-session-persistence \
            --dangerously-skip-permissions \
            --strict-mcp-config \
            --output-format json \
            --json-schema "$schema" \
            < /dev/null 2>&1) || exit_code=$?

        printf '%s\n' "=== $stage_name retry output ===" >> "$stage_log"
        printf '%s\n' "$output" >> "$stage_log"

        # Also write retry to combined log
        if [[ -n "$LOG_FILE" ]]; then
            printf '[%s] === %s retry output ===\n' "$(date -Iseconds)" "$stage_name" >> "$LOG_FILE"
            printf '%s\n' "$output" >> "$LOG_FILE"
        fi
    fi

    # Extract structured output
    local structured
    structured=$(printf '%s' "$output" | jq -c '.structured_output // empty' 2>/dev/null)

    if [[ -z "$structured" ]]; then
        log_error "No structured output from $stage_name"
        echo '{"status":"error","error":"no structured output"}'
        return 1
    fi

    printf '%s\n' "$structured"
}

# =============================================================================
# QUALITY LOOP HELPER
# =============================================================================

# Run the quality loop (simplify -> review -> fix, repeat)
# Note: Testing is handled separately by run_test_loop after all tasks complete
# The code-reviewer recommends the best fix agent per iteration based on the issues found.
# Arguments:
#   $1 - worktree path
#   $2 - branch name
#   $3 - stage prefix for logging (e.g., "task-1" or "pr-fix")
# Returns:
#   0 on success (approved)
#   2 on max iterations exceeded (calls exit 2)
run_quality_loop() {
    local loop_worktree="$1"
    local loop_branch="$2"
    local stage_prefix="${3:-main}"

    local loop_approved=false
    local loop_iteration=0  # Per-loop counter (resets each call)

    while [[ "$loop_approved" != "true" ]]; do
        loop_iteration=$((loop_iteration + 1))
        increment_quality_iteration  # Global counter for status tracking

        if (( loop_iteration > MAX_QUALITY_ITERATIONS )); then
            log_error "Quality loop for $stage_prefix exceeded max iterations ($MAX_QUALITY_ITERATIONS)"
            set_final_state "max_iterations_quality"
            exit 2
        fi

        log "Quality loop iteration $loop_iteration/$MAX_QUALITY_ITERATIONS (prefix: $stage_prefix)"

        # -------------------------------------------------------------------------
        # SIMPLIFY → Issue comment #7
        # -------------------------------------------------------------------------
        local simplify_prompt="Run code-simplifier on modified PHP files in worktree $loop_worktree on branch $loop_branch.

IMPORTANT SCOPE CONSTRAINT: This is for issue #$ISSUE_NUMBER. Only simplify PHP code that is directly related to the issue's goals. Do NOT apply general PHP modernization (constructor promotion, match expressions, etc.) to files that were only incidentally touched or are outside the issue's focus area.

If no PHP files were modified as part of this issue's implementation, make no changes and report 'No PHP changes to simplify'.

Simplify code for clarity and consistency without changing functionality.
Output a summary of changes made."

        local simplify_result
        simplify_result=$(run_stage "simplify-${stage_prefix}-iter-$loop_iteration" "$simplify_prompt" "implement-issue-simplify.json" "code-simplifier")

        local simplify_summary
        simplify_summary=$(printf '%s' "$simplify_result" | jq -r '.summary // "No changes"')

        # Simplify summary (logged only, not posted to issue)
        log "Quality simplify [$stage_prefix] iter $loop_iteration: $simplify_summary"

        # -------------------------------------------------------------------------
        # REVIEW → Issue comment #9
        # -------------------------------------------------------------------------
        local review_prompt="Review the code changes for task scope '$stage_prefix' in worktree $loop_worktree on branch $loop_branch.

IMPORTANT: This is a task-level quality check within the implementation workflow, NOT a full PR review.
Your job is to verify code quality for the changes made in this task only.

Check:
- Code patterns and standards
- Consistency with codebase conventions
- Potential bugs or issues
- Security concerns

DO NOT recommend 'approve and merge' - this is not a PR review.
Simply output 'approved' if code quality is acceptable, or 'changes_requested' with specific issues to fix.

If changes are requested, set recommended_fix_agent to the most appropriate agent for the fixes:
- laravel-backend-developer: PHP/Laravel code (controllers, models, services, middleware, migrations, tests)
- bulletproof-frontend-developer: CSS, Blade templates, HTML, frontend code
- bash-script-craftsman: Shell scripts, BATS tests
- technical-doc-writer: Architecture docs, design docs, data flows in docs/{domain}/"

        local review_result
        review_result=$(run_stage "review-${stage_prefix}-iter-$loop_iteration" "$review_prompt" "implement-issue-review.json" "code-reviewer")

        local review_verdict review_summary
        review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')

        # Code review results (logged only, not posted to issue)
        log "Quality review [$stage_prefix] iter $loop_iteration: $review_verdict"

        if [[ "$review_verdict" == "approved" ]]; then
            loop_approved=true
            log "Quality loop for $stage_prefix approved on iteration $loop_iteration"
        else
            local review_comments
            review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')
            printf '%s\n' "$review_comments" >> "$LOG_BASE/context/review-comments.json"

            # Use reviewer's recommended agent, fall back to laravel-backend-developer
            local selected_fix_agent
            selected_fix_agent=$(printf '%s' "$review_result" | jq -r '.recommended_fix_agent // empty')
            if [[ -z "$selected_fix_agent" ]]; then
                selected_fix_agent="laravel-backend-developer"
            fi
            log "Quality loop fix agent: $selected_fix_agent (recommended by code-reviewer)"

            local fix_prompt="Address code review feedback in worktree $loop_worktree on branch $loop_branch:

$review_comments

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-review-${stage_prefix}-iter-$loop_iteration" "$fix_prompt" "implement-issue-fix.json" "$selected_fix_agent")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Review fix results (logged only, not posted to issue)
            log "Quality fix [$stage_prefix] iter $loop_iteration: $fix_summary"
        fi
    done

    return 0
}

# =============================================================================
# TEST LOOP HELPER
# =============================================================================

# Run the test loop (test -> validate -> fix, repeat until pass)
# Called once after all tasks complete
# Flow:
#   1. Run tests (php-test-validator)
#   2. If tests fail: fix with laravel-backend-developer, loop
#   3. If tests pass: validate test quality (php-test-validator, scoped to issue)
#   4. If validation fails: fix with laravel-backend-developer, loop
#   5. If validation passes: done
# Arguments:
#   $1 - worktree path
#   $2 - branch name
# Returns:
#   0 on success (tests pass and validated)
#   2 on max iterations exceeded (calls exit 2)
run_test_loop() {
    local loop_worktree="$1"
    local loop_branch="$2"

    local loop_complete=false
    local test_iteration=0

    log "Starting test loop after all tasks complete"

    while [[ "$loop_complete" != "true" ]]; do
        test_iteration=$((test_iteration + 1))
        increment_test_iteration  # Track iteration in status file

        if (( test_iteration > MAX_TEST_ITERATIONS )); then
            log_error "Test loop exceeded max iterations ($MAX_TEST_ITERATIONS)"
            set_final_state "max_iterations_test"
            exit 2
        fi

        log "Test loop iteration $test_iteration/$MAX_TEST_ITERATIONS"

        # -------------------------------------------------------------------------
        # TEST EXECUTION → Issue comment
        # -------------------------------------------------------------------------
        local test_prompt="Run the test suite in worktree $loop_worktree:

cd $loop_worktree && AWS_ENABLED=false USE_AWS_SECRETS=false php artisan test

Report pass/fail, test counts, and any failures. Output a summary suitable for a GitHub comment."

        local test_result
        test_result=$(run_stage "test-loop-iter-$test_iteration" "$test_prompt" "implement-issue-test.json" "php-test-validator")

        local test_status test_summary
        test_status=$(printf '%s' "$test_result" | jq -r '.result')
        test_summary=$(printf '%s' "$test_result" | jq -r '.summary // "Tests completed"')

        # Test results (logged only, not posted to issue)
        log "Test loop iter $test_iteration: $test_status"

        if [[ "$test_status" == "failed" ]]; then
            log "Tests failed. Getting failures and fixing..."
            local failures
            failures=$(printf '%s' "$test_result" | jq -c '.failures')

            local fix_prompt="Fix test failures in worktree $loop_worktree on branch $loop_branch:

Failures:
$failures

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-tests-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "laravel-backend-developer")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Test fix results (logged only, not posted to issue)
            log "Test fix iter $test_iteration: $fix_summary"
            continue
        fi

        # -------------------------------------------------------------------------
        # TEST VALIDATION → Issue comment (only if tests passed)
        # -------------------------------------------------------------------------
        log "Tests passed. Running test validation for issue #$ISSUE_NUMBER..."

        local validate_prompt="Validate test comprehensiveness and integrity for issue #$ISSUE_NUMBER in worktree $loop_worktree.

SCOPE: Only validate tests related to this issue's implementation. Get modified PHP files with:
git -C $loop_worktree diff $BASE_BRANCH...HEAD --name-only -- '*.php' | grep -E '^app/'

IMPORTANT SCOPE CONSTRAINTS:
- If NO testable PHP code was modified (e.g., CSS-only, Blade templates, config changes), output 'passed' immediately. Do NOT request new tests for non-PHP changes.
- Only validate tests for modified PHP files in app/ (Services, Controllers, Models, etc.)
- Do NOT request tests for views, routes, config, or frontend assets

For each modified implementation file that warrants testing, identify the corresponding test file and audit:
1. Run the test suite: cd $loop_worktree && AWS_ENABLED=false USE_AWS_SECRETS=false php artisan test
2. Check for TODO/FIXME/incomplete tests
3. Check for hollow assertions (assertTrue(true), no assertions)
4. Verify edge cases and error conditions are tested
5. Check for mock abuse patterns

Output:
- result: 'passed' if tests are comprehensive OR if no testable PHP was modified, 'failed' if issues found
- issues: array of issues found (if any)
- summary: suitable for a GitHub comment (note if validation was skipped due to no testable PHP changes)"

        local validate_result
        validate_result=$(run_stage "test-validate-iter-$test_iteration" "$validate_prompt" "implement-issue-review.json" "php-test-validator")

        local validate_status validate_summary
        validate_status=$(printf '%s' "$validate_result" | jq -r '.result')
        validate_summary=$(printf '%s' "$validate_result" | jq -r '.summary // "Validation completed"')

        # Validation results (logged only, not posted to issue)
        log "Test validation iter $test_iteration: $validate_status"

        if [[ "$validate_status" == "approved" || "$validate_status" == "passed" ]]; then
            loop_complete=true
            log "Test loop complete on iteration $test_iteration (tests passed and validated)"
        else
            log "Test validation found issues. Fixing..."
            local validate_comments
            validate_comments=$(printf '%s' "$validate_result" | jq -r '.comments // .summary // "Fix test quality issues"')

            local fix_prompt="Address test quality issues in worktree $loop_worktree on branch $loop_branch:

$validate_comments

Fix the test quality issues (add missing assertions, remove TODOs, add edge case tests, etc.) and commit.
Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-test-quality-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "laravel-backend-developer")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Validation fix results (logged only, not posted to issue)
            log "Test validation fix iter $test_iteration: $fix_summary"
        fi
    done

    return 0
}

# =============================================================================
# RETROSPECTIVE (non-blocking, runs after every issue)
# =============================================================================

run_retrospective() {
    local exit_code="${1:-$?}"

    # Double-execution guard
    if [[ "$RETRO_RAN" == "true" ]]; then
        return 0
    fi
    RETRO_RAN=true

    # Need LOG_BASE and STATUS_FILE to proceed
    if [[ -z "$LOG_BASE" || ! -d "$LOG_BASE" || ! -f "$STATUS_FILE" ]]; then
        return 0
    fi

    log "Running process retrospective (exit_code=$exit_code)..."
    set_stage_started "retrospective"

    # Seed memory file if it does not exist
    if [[ ! -f "$RETRO_MEMORY_FILE" ]]; then
        mkdir -p "$(dirname "$RETRO_MEMORY_FILE")"
        cat > "$RETRO_MEMORY_FILE" <<'SEED'
# Process Retrospective Memory

## Active Learnings

### agent_selection

### quality_loop

### test_loop

### performance

### error_patterns

### workflow

## Deprecated Learnings

## Run History
| Run | Issue | Duration | State | Quality Iters | Test Iters | PR Iters | Key Finding |
|-----|-------|----------|-------|---------------|------------|----------|-------------|
SEED
        log "Seeded retrospective memory file: $RETRO_MEMORY_FILE"
    fi

    # Build paths for the prompt
    local abs_status abs_log abs_stages abs_context abs_memory
    abs_status="$(realpath "$STATUS_FILE")"
    abs_log="$(realpath "$LOG_FILE")"
    abs_stages="$(realpath "$LOG_BASE/stages")"
    abs_context="$(realpath "$LOG_BASE/context")"
    abs_memory="$(realpath "$RETRO_MEMORY_FILE")"

    local retro_prompt="Analyze the implement-issue orchestrator run and produce a retrospective.

## Run Data Locations

- **status.json:** $abs_status
- **orchestrator.log:** $abs_log
- **Stage logs directory:** $abs_stages
- **Context files directory:** $abs_context
- **Memory file:** $abs_memory

## Instructions

1. Read status.json to get run metrics (stages, iterations, tasks, final state)
2. Read orchestrator.log for timing and error patterns
3. Scan stage logs in $abs_stages for anomalies (timeouts, rate limits, excessive output)
4. Read context files in $abs_context for structured stage outputs
5. Read the memory file at $abs_memory for prior learnings
6. Compute run metrics, identify findings, generate recommendations
7. Update the memory file with new/updated/deprecated learnings (enforce caps: 20 active, 10 deprecated, 20 history rows)
8. Output structured retrospective data

The run ended with exit code $exit_code."

    local retro_stage_log="$LOG_BASE/stages/$(next_stage_log "retrospective")"

    # NOTE: The process-retrospective agent and implement-issue-retrospective.json schema
    # need to be created for this project. Until then, this stage will fail gracefully.
    local retro_output retro_exit=0
    retro_output=$(cd "${WORKTREE:-.}" && timeout "$STAGE_TIMEOUT" claude -p "$retro_prompt" \
        --agent "process-retrospective" \
        --no-session-persistence \
        --dangerously-skip-permissions \
        --strict-mcp-config \
        --output-format json \
        --json-schema "$(jq -c . "$SCHEMA_DIR/implement-issue-retrospective.json")" \
        < /dev/null 2>&1) || retro_exit=$?

    # Write to stage log
    printf '%s\n' "=== retrospective output ===" >> "$retro_stage_log"
    printf '%s\n' "$retro_output" >> "$retro_stage_log"
    printf '%s\n' "=== exit code: $retro_exit ===" >> "$retro_stage_log"

    # Write to combined log for tail -f
    if [[ -n "$LOG_FILE" ]]; then
        printf '[%s] === retrospective output (exit: %d) ===\n' "$(date -Iseconds)" "$retro_exit" >> "$LOG_FILE"
        printf '%s\n' "$retro_output" >> "$LOG_FILE"
    fi

    # Save structured output to context/
    local retro_structured
    retro_structured=$(printf '%s' "$retro_output" | jq -c '.structured_output // empty' 2>/dev/null)
    if [[ -n "$retro_structured" ]]; then
        printf '%s\n' "$retro_structured" > "$LOG_BASE/context/retrospective-output.json"
        log "Retrospective output saved to context/retrospective-output.json"

        # Log the summary
        local retro_summary
        retro_summary=$(printf '%s' "$retro_structured" | jq -r '.summary // "No summary"')
        log "Retrospective summary: $retro_summary"
    else
        log "Warning: No structured output from retrospective (exit=$retro_exit)"
    fi

    set_stage_completed "retrospective"
    log "Retrospective complete."
}

# =============================================================================
# MAIN FLOW
# =============================================================================

main() {
    # Declare local variables used throughout main
    local worktree branch tasks_json task_count completed_tasks

    # -------------------------------------------------------------------------
    # RESUME VS FRESH START INITIALIZATION
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]]; then
        log "=========================================="
        log "Implement Issue Orchestrator RESUMING"
        log "=========================================="
        log "Issue: #$ISSUE_NUMBER"
        log "Branch: $BRANCH"
        log "Worktree: $WORKTREE"
        log "Resume stage: $RESUME_STAGE"
        log "Resume task: ${RESUME_TASK:-none}"
        log "Log dir: $LOG_BASE"

        # Use values from resume state
        worktree="$WORKTREE"
        branch="$BRANCH"
        tasks_json="$RESUME_TASKS_JSON"

        # Update status to indicate resumption
        jq --arg state "running" \
           '.state = $state | .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        sync_status_to_log

        # Comment on issue about resumption
        comment_issue "Resuming Automated Processing" "Resuming processing of issue #$ISSUE_NUMBER.

**Resuming from stage:** \`$RESUME_STAGE\`
**Worktree:** \`$worktree\`
**Branch:** \`$branch\`

Log directory: \`$LOG_BASE\`"

    else
        log "=========================================="
        log "Implement Issue Orchestrator Starting"
        log "=========================================="
        log "Issue: #$ISSUE_NUMBER"
        log "Branch: $BASE_BRANCH"
        log "Agent: ${AGENT:-default}"
        log "Log dir: $LOG_BASE"

        init_status

        # -------------------------------------------------------------------------
        # COMMENT #1: Starting automated processing
        # -------------------------------------------------------------------------
        comment_issue "Starting Automated Processing" "Processing issue #$ISSUE_NUMBER against branch \`$BASE_BRANCH\`.

**Stages:**
1. Setup worktree
2. Research context
3. Evaluate approach
4. Create implementation plan
5. Implement tasks (with per-task quality loop: simplify, review)
6. Test loop (run tests, fix failures)
7. PHPDoc documentation
8. Create/update PR
9. PR review loop
10. Technical docs (assess if new/updated docs needed, add to PR)

Log directory: \`$LOG_BASE\`"
    fi

    # -------------------------------------------------------------------------
    # SMOKE TEST: verify claude CLI and API are functional before real work
    # -------------------------------------------------------------------------
    log "Running smoke test..."
    local smoke_output smoke_exit=0
    smoke_output=$(cd "${WORKTREE:-.}" && timeout 60 claude -p "Respond with exactly: SMOKE_OK" \
        --no-session-persistence \
        --dangerously-skip-permissions \
        --strict-mcp-config \
        --output-format text \
        < /dev/null 2>&1) || smoke_exit=$?

    if (( smoke_exit != 0 )) || [[ "$smoke_output" != *"SMOKE_OK"* ]]; then
        log_error "Smoke test failed (exit=$smoke_exit). Claude CLI or API may be unavailable."
        log_error "Output: $smoke_output"
        set_final_state "error"
        exit 1
    fi
    log "Smoke test passed."

    # -------------------------------------------------------------------------
    # STAGE: SETUP (worktree creation)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "setup"; then
        log "Skipping setup stage (already completed)"
    else
        set_stage_started "setup"

        local setup_prompt="Set up worktree for issue #$ISSUE_NUMBER against branch $BASE_BRANCH.

You must:
1. Fetch the issue title and body from GitHub using: gh issue view $ISSUE_NUMBER --repo $REPO --json title,body
2. Check for existing PR (if re-implementation)
3. Create or checkout worktree using using-git-worktrees skill

Output the worktree path and branch name."

        local setup_result
        setup_result=$(run_stage "setup" "$setup_prompt" "implement-issue-setup.json" "$AGENT")

        local setup_status
        setup_status=$(printf '%s' "$setup_result" | jq -r '.status')

        if [[ "$setup_status" != "success" ]]; then
            local error
            error=$(printf '%s' "$setup_result" | jq -r '.error // "unknown error"')
            log_error "Setup failed: $error"
            set_final_state "error"
            exit 1
        fi

        worktree=$(printf '%s' "$setup_result" | jq -r '.worktree')
        branch=$(printf '%s' "$setup_result" | jq -r '.branch')

        set_worktree_info "$worktree" "$branch"
        printf '%s\n' "$setup_result" > "$LOG_BASE/context/setup-output.json"

        set_stage_completed "setup"
        log "Setup complete. Worktree: $worktree, Branch: $branch"

        # Self-assign the issue to prevent duplicate work from concurrent batches
        if gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-assignee @me 2>/dev/null; then
            log "Self-assigned issue #$ISSUE_NUMBER"
        else
            log "Warning: Could not self-assign issue #$ISSUE_NUMBER (non-blocking)"
        fi

        # -------------------------------------------------------------------------
        # BUILD FRONTEND ASSETS (required for tests that render views)
        # -------------------------------------------------------------------------
        log "Building frontend assets in worktree..."
        if [[ -f "$worktree/package.json" ]]; then
            (
                cd "$worktree" || exit 1
                npm install --silent 2>/dev/null
                npm run build --silent 2>/dev/null
            ) && log "Frontend assets built successfully" \
              || log "Frontend build skipped or failed (non-blocking)"
        else
            log "No package.json found, skipping frontend build"
        fi
    fi

    # -------------------------------------------------------------------------
    # STAGE: RESEARCH (no comment per user request)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "research"; then
        log "Skipping research stage (already completed)"
    else
        set_stage_started "research"

        local research_prompt="Research context for issue #$ISSUE_NUMBER in worktree $worktree.

You must:
1. Read the issue details AND all comments from GitHub:
   gh issue view $ISSUE_NUMBER --repo $REPO --json title,body,comments
2. Check for existing or closed PRs that reference this issue:
   gh pr list --repo $REPO --state all --search \"$ISSUE_NUMBER\" --json number,title,state,body,reviews
3. If prior work exists (comments with implementation details, closed/rejected PRs, review feedback):
   a. Summarize what was previously attempted and the outcome
   b. Extract specific review feedback or rejection reasons
   c. Identify what should be preserved vs. changed in this attempt
   d. Note any partial branches or commits that could be built upon
4. Explore related files and code structure in the worktree
5. Identify dependencies and related components
6. Document all relevant context for implementation, clearly separating:
   - Issue requirements (from issue body)
   - Prior work context (from comments and closed PRs)
   - Codebase context (from file exploration)

Output the research findings."

        local research_result
        research_result=$(run_stage "research" "$research_prompt" "implement-issue-research.json" "$AGENT")

        printf '%s\n' "$research_result" > "$LOG_BASE/context/research-output.json"

        set_stage_completed "research"
        log "Research complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: EVALUATE → Issue comment #3
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "evaluate"; then
        log "Skipping evaluate stage (already completed)"
    else
        set_stage_started "evaluate"

        local evaluate_prompt="Evaluate the best implementation approach for issue #$ISSUE_NUMBER.

Based on the research, determine:
1. The recommended approach (if prior work exists, explain how this builds on or diverges from it)
2. Rationale for this approach
3. Potential risks or concerns
4. Alternative approaches considered
5. If prior attempts failed or were rejected, explain how this approach addresses the previous feedback

Output your evaluation with a summary suitable for a GitHub comment."

        local evaluate_result
        evaluate_result=$(run_stage "evaluate" "$evaluate_prompt" "implement-issue-evaluate.json" "$AGENT")

        local evaluate_status
        evaluate_status=$(printf '%s' "$evaluate_result" | jq -r '.status')

        # Comment #3: Evaluate findings (always post, format based on status)
        local eval_summary approach rationale
        eval_summary=$(printf '%s' "$evaluate_result" | jq -r '.summary')
        approach=$(printf '%s' "$evaluate_result" | jq -r '.approach // ""')
        rationale=$(printf '%s' "$evaluate_result" | jq -r '.rationale // ""')

        if [[ "$evaluate_status" == "success" ]]; then
            local eval_body="**Approach:** $approach

**Rationale:** $rationale

$eval_summary"
            comment_issue "Evaluation: Best Path" "$eval_body" "${AGENT:-}"
        else
            local eval_error risks_text
            eval_error=$(printf '%s' "$evaluate_result" | jq -r '.error // "Unknown error"')
            risks_text=$(printf '%s' "$evaluate_result" | jq -r '.risks // [] | map("- " + .) | join("\n")')

            local eval_body="⚠️ **Status:** Error - requires attention

**Approach:** $approach

**Rationale:** $rationale

**Error:** $eval_error"

            if [[ -n "$risks_text" ]]; then
                eval_body="$eval_body

**Risks:**
$risks_text"
            fi

            comment_issue "Evaluation: Issue Concerns" "$eval_body" "${AGENT:-}"

            # Exit early - evaluation found blocking issues
            printf '%s\n' "$evaluate_result" > "$LOG_BASE/context/evaluate-output.json"
            set_stage_completed "evaluate"
            log_error "Evaluation found blocking issues. Exiting."
            set_final_state "blocked"
            exit 1
        fi

        printf '%s\n' "$evaluate_result" > "$LOG_BASE/context/evaluate-output.json"

        set_stage_completed "evaluate"
        log "Evaluation complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: PLAN → Issue comments #4 (plan) and #5 (task list)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "plan"; then
        log "Skipping plan stage (already completed)"
        # Load tasks from status file for implement stage
        tasks_json=$(jq -c '.tasks' "$STATUS_FILE")
    else
        set_stage_started "plan"

        # Build retrospective learnings block if memory file exists
        local retro_learnings=""
        if [[ -f "$RETRO_MEMORY_FILE" ]]; then
            # Extract Active Learnings section (first 60 lines after the header)
            retro_learnings=$(sed -n '/^## Active Learnings/,/^## Deprecated Learnings/p' "$RETRO_MEMORY_FILE" | head -60)
            if [[ -n "$retro_learnings" ]]; then
                retro_learnings="

## Learnings from Previous Runs

The following patterns were observed in prior orchestrator runs. Use these to inform agent selection and task decomposition:

$retro_learnings"
            fi
        fi

        local plan_prompt="Create an implementation plan for issue #$ISSUE_NUMBER in worktree $worktree on branch $branch.

Based on the evaluation, you must:
1. Write a detailed implementation plan using writing-plans skill
2. Break down into tasks with agent assignments
3. Each task should specify: id, description, and the most appropriate agent

Available agents for task assignment:
- laravel-backend-developer: PHP/Laravel controllers, models, services, middleware, Eloquent, migrations, API endpoints, auth, PHPUnit tests
- bulletproof-frontend-developer: CSS architecture, responsive design, Blade templates, frontend code -- defers PHP to laravel-backend-developer
- bash-script-craftsman: Shell scripts, portability, BATS testing -- use for any .sh file changes
- technical-doc-writer: Architecture docs, design docs, data flow docs, API contracts in docs/{domain}/ folders -- GitHub Markdown with Mermaid diagrams

Choose the agent whose expertise best matches each task. Most tasks will use laravel-backend-developer or bulletproof-frontend-developer, but infrastructure and script tasks should use the appropriate specialist.
$retro_learnings
Output the plan path, task list, a summary of the plan, and a markdown-formatted task list for GitHub."

        local plan_result
        plan_result=$(run_stage "plan" "$plan_prompt" "implement-issue-plan.json" "$AGENT")

        local plan_status
        plan_status=$(printf '%s' "$plan_result" | jq -r '.status')

        if [[ "$plan_status" != "success" ]]; then
            local error
            error=$(printf '%s' "$plan_result" | jq -r '.error // "unknown error"')
            log_error "Plan failed: $error"
            set_final_state "error"
            exit 1
        fi

        local plan_summary task_list_md plan_path
        tasks_json=$(printf '%s' "$plan_result" | jq -c '.tasks')
        plan_summary=$(printf '%s' "$plan_result" | jq -r '.summary')
        task_list_md=$(printf '%s' "$plan_result" | jq -r '.task_list_markdown')
        plan_path=$(printf '%s' "$plan_result" | jq -r '.plan_path // empty')

        set_tasks "$tasks_json"
        printf '%s\n' "$plan_result" > "$LOG_BASE/context/plan-output.json"
        printf '%s\n' "$tasks_json" > "$LOG_BASE/context/tasks.json"

        # Comment #4: Implementation Plan (with full plan in collapsible)
        local plan_body="$plan_summary"
        if [[ -n "$plan_path" && -f "$worktree/$plan_path" ]]; then
            local plan_content
            plan_content=$(cat "$worktree/$plan_path")
            plan_body="$plan_summary

<details>
<summary>Full Implementation Plan</summary>

\`\`\`markdown
$plan_content
\`\`\`

</details>"
        fi
        comment_issue "Implementation Plan" "$plan_body"

        # Comment #5: Task List
        comment_issue "Task List" "$task_list_md"

        set_stage_completed "plan"
        log "Plan complete. Tasks: $(printf '%s' "$tasks_json" | jq length)"
    fi

    # -------------------------------------------------------------------------
    # STAGE: IMPLEMENT (per-task loop)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "implement"; then
        log "Skipping implement stage (already completed)"
    else
        set_stage_started "implement"

        task_count=$(printf '%s' "$tasks_json" | jq length)

        # In resume mode, count already completed tasks
        if [[ -n "$RESUME_MODE" ]]; then
            completed_tasks=$(get_completed_task_count)
            log "Resuming implementation: $completed_tasks/$task_count tasks already completed"
        else
            completed_tasks=0
        fi

        for ((i=0; i<task_count; i++)); do
            local task
            task=$(printf '%s' "$tasks_json" | jq ".[$i]")
            local task_id task_desc task_agent task_status
            task_id=$(printf '%s' "$task" | jq -r '.id')
            task_desc=$(printf '%s' "$task" | jq -r '.description')
            task_agent=$(printf '%s' "$task" | jq -r '.agent')

            # In resume mode, check if this task is already completed
            if [[ -n "$RESUME_MODE" ]]; then
                task_status=$(jq -r ".tasks[] | select(.id == $task_id) | .status" "$STATUS_FILE" 2>/dev/null)
                if [[ "$task_status" == "completed" ]]; then
                    log "Skipping task $task_id (already completed)"
                    continue
                fi
            fi

            log "Implementing task $task_id: $task_desc (agent: $task_agent)"
            update_task "$task_id" "in_progress"

            local review_attempts=0
            local task_approved=false

            while [[ "$task_approved" != "true" ]] && (( review_attempts < MAX_TASK_REVIEW_ATTEMPTS )); do
                # Implement
                local impl_prompt="Implement task $task_id in worktree $worktree on branch $branch:

$task_desc

Commit your changes with a descriptive message."

                local impl_result
                impl_result=$(run_stage "implement-task-$task_id" "$impl_prompt" "implement-issue-implement.json" "$task_agent")

                local impl_status
                impl_status=$(printf '%s' "$impl_result" | jq -r '.status')

                if [[ "$impl_status" != "success" ]]; then
                    log_error "Task $task_id implementation failed"
                    update_task "$task_id" "failed" "$review_attempts"
                    break
                fi

                local commit_sha
                commit_sha=$(printf '%s' "$impl_result" | jq -r '.commit')

                # Review task
                local review_prompt="Review task $task_id implementation (commit $commit_sha):

Task description: $task_desc

Did the implementation achieve the task's goal? Are there suggested improvements?"

                local review_result
                review_result=$(run_stage "task-review-$task_id-attempt-$((review_attempts+1))" "$review_prompt" "implement-issue-task-review.json" "spec-reviewer")

                local review_verdict suggested_improvements
                review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
                suggested_improvements=$(printf '%s' "$review_result" | jq -r '.suggested_improvements')

                if [[ "$review_verdict" == "passed" && "$suggested_improvements" != "yes" ]]; then
                    task_approved=true
                    update_task "$task_id" "completed" "$((review_attempts+1))"
                    completed_tasks=$((completed_tasks+1))

                    # Comment #6: Task complete (with summary from implementing agent)
                    local impl_summary
                    impl_summary=$(printf '%s' "$impl_result" | jq -r '.summary // "Implementation completed"')
                    comment_issue "Task $task_id Complete" "**$task_desc**

**Commit:** \`$commit_sha\`

$impl_summary" "$task_agent"

                    # Run quality loop for this task
                    log "Running quality loop for task $task_id"
                    run_quality_loop "$worktree" "$branch" "task-$task_id"

                else
                    review_attempts=$((review_attempts+1))
                    local review_comments
                    review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')

                    log "Task $task_id needs fixes (attempt $review_attempts/$MAX_TASK_REVIEW_ATTEMPTS)"

                    # Fix
                    local fix_prompt="Fix issues in task $task_id (commit $commit_sha) in worktree $worktree on branch $branch:

Review feedback:
$review_comments

Address the issues and commit."

                    run_stage "fix-task-$task_id-attempt-$review_attempts" "$fix_prompt" "implement-issue-fix.json" "$task_agent"
                fi
            done

            # Update progress
            jq --arg progress "$completed_tasks/$task_count" \
               '.stages.implement.task_progress = $progress | .last_update = (now | todate)' \
               "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            sync_status_to_log
        done

        set_stage_completed "implement"
        set_stage_completed "quality_loop"  # Quality loop ran per-task
        log "Implementation complete. $completed_tasks/$task_count tasks completed (with per-task quality loops)."
    fi

    # -------------------------------------------------------------------------
    # STAGE: TEST LOOP (after all tasks complete)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "test_loop"; then
        log "Skipping test_loop stage (already completed)"
    else
        set_stage_started "test_loop"
        log "Running test loop after all tasks complete..."

        run_test_loop "$worktree" "$branch"

        set_stage_completed "test_loop"
        log "Test loop complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: DOCS
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "docs"; then
        log "Skipping docs stage (already completed)"
    else
        set_stage_started "docs"

        local docs_prompt="Write PHPDoc blocks for all modified PHP files in worktree $worktree on branch $branch.

Get modified files with: git diff $BASE_BRANCH...HEAD --name-only -- '*.php' | grep -E '^app/'

Add comprehensive docblocks and commit with message: docs(issue-$ISSUE_NUMBER): add PHPDoc blocks"

        run_stage "docs" "$docs_prompt" "implement-issue-implement.json" "phpdoc-writer"

        set_stage_completed "docs"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PR
    # -------------------------------------------------------------------------
    local pr_number

    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "pr"; then
        log "Skipping PR creation stage (already completed)"
        # Load PR number from status
        pr_number=$(jq -r '.stages.pr.pr_number // empty' "$STATUS_FILE")
        if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
            log_error "PR stage marked complete but no PR number found in status"
            set_final_state "error"
            exit 1
        fi
        log "Using existing PR #$pr_number"
    else
        set_stage_started "pr"

        local pr_prompt="Create or update PR for issue #$ISSUE_NUMBER in worktree $worktree.

If no PR exists, create one:
gh pr create --base $BASE_BRANCH --title 'feat(issue-$ISSUE_NUMBER): <description>'

If PR exists, push and comment.

Include 'Closes #$ISSUE_NUMBER' in the body."

        local pr_result
        pr_result=$(run_stage "pr" "$pr_prompt" "implement-issue-pr.json")

        local pr_status
        pr_status=$(printf '%s' "$pr_result" | jq -r '.status')
        pr_number=$(printf '%s' "$pr_result" | jq -r '.pr_number')

        if [[ "$pr_status" != "success" ]]; then
            log_error "PR creation failed"
            set_final_state "error"
            exit 1
        fi

        log "PR #$pr_number created/updated"

        # Store PR info in status
        jq --argjson pr "$pr_number" \
           '.stages.pr.pr_number = $pr | .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        sync_status_to_log
        set_stage_completed "pr"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PR REVIEW LOOP
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "pr_review"; then
        log "Skipping pr_review stage (already completed)"
    else
        set_stage_started "pr_review"

        local pr_approved=false

    while [[ "$pr_approved" != "true" ]]; do
        increment_pr_review_iteration
        local pr_iteration
        pr_iteration=$(jq -r '.pr_review_iterations' "$STATUS_FILE")

        if (( pr_iteration > MAX_PR_REVIEW_ITERATIONS )); then
            log_error "PR review loop exceeded max iterations ($MAX_PR_REVIEW_ITERATIONS)"
            set_final_state "max_iterations_pr_review"
            exit 2
        fi

        log "PR review iteration $pr_iteration"

        # -------------------------------------------------------------------------
        # SPEC REVIEW → PR comment #11
        # -------------------------------------------------------------------------
        local spec_prompt="Verify PR #$pr_number achieves the goals of issue #$ISSUE_NUMBER.

Check goal achievement, not code quality. Flag scope creep.

IMPORTANT: Before flagging any acceptance criterion as missing, check the BASE BRANCH ($BASE_BRANCH) to see if the feature already exists there. If a criterion is already satisfied by pre-existing code on the base branch that the PR preserves, mark it as met (🔄 Met differently — pre-existing on base branch), NOT as missing. Only flag criteria as unmet if the feature is absent from BOTH the PR diff AND the base branch.

Working directory: $worktree

Output a summary suitable for a GitHub comment."

        local spec_result
        spec_result=$(run_stage "spec-review-iter-$pr_iteration" "$spec_prompt" "implement-issue-review.json" "spec-reviewer")

        local spec_verdict spec_summary
        spec_verdict=$(printf '%s' "$spec_result" | jq -r '.result')
        spec_summary=$(printf '%s' "$spec_result" | jq -r '.summary // "Review completed"')

        # Comment #11: PR Spec Review Result
        local spec_icon="✅"
        [[ "$spec_verdict" == "changes_requested" ]] && spec_icon="🔄"
        comment_pr "$pr_number" "Spec Review (Iteration $pr_iteration)" "$spec_icon **Result:** $spec_verdict

$spec_summary" "spec-reviewer"

        # -------------------------------------------------------------------------
        # CODE REVIEW → PR comment #12
        # -------------------------------------------------------------------------
        local code_prompt="Review code quality of PR #$pr_number against base $BASE_BRANCH.

Check patterns, standards, security. Approve or request changes.
Output a summary suitable for a GitHub comment.

If changes are requested, set recommended_fix_agent to the most appropriate agent for the fixes:
- laravel-backend-developer: PHP/Laravel code (controllers, models, services, middleware, migrations, tests)
- bulletproof-frontend-developer: CSS, Blade templates, HTML, frontend code
- bash-script-craftsman: Shell scripts, BATS tests
- technical-doc-writer: Architecture docs, design docs, data flows in docs/{domain}/"

        local code_result
        code_result=$(run_stage "code-review-iter-$pr_iteration" "$code_prompt" "implement-issue-review.json" "code-reviewer")

        local code_verdict code_summary
        code_verdict=$(printf '%s' "$code_result" | jq -r '.result')
        code_summary=$(printf '%s' "$code_result" | jq -r '.summary // "Review completed"')

        # Comment #12: PR Code Review Result
        local code_icon="✅"
        [[ "$code_verdict" == "changes_requested" ]] && code_icon="🔄"
        comment_pr "$pr_number" "Code Review (Iteration $pr_iteration)" "$code_icon **Result:** $code_verdict

$code_summary" "code-reviewer"

        if [[ "$spec_verdict" == "approved" && "$code_verdict" == "approved" ]]; then
            pr_approved=true
            log "PR approved on iteration $pr_iteration"
        else
            log "PR review requested changes. Fixing and re-running quality loop."

            # Collect feedback
            local spec_comments code_comments
            spec_comments=$(printf '%s' "$spec_result" | jq -r '.comments // ""')
            code_comments=$(printf '%s' "$code_result" | jq -r '.comments // ""')

            local fix_prompt="Address PR review feedback in worktree $worktree on branch $branch:

Spec review:
$spec_comments

Code review:
$code_comments

Fix the issues and commit. Output a summary of fixes applied."

            # Use code-reviewer's recommended agent, fall back to laravel-backend-developer
            local pr_fix_agent
            pr_fix_agent=$(printf '%s' "$code_result" | jq -r '.recommended_fix_agent // empty')
            if [[ -z "$pr_fix_agent" ]]; then
                pr_fix_agent="laravel-backend-developer"
            fi
            log "PR review fix agent: $pr_fix_agent (recommended by code-reviewer)"

            local fix_result
            fix_result=$(run_stage "fix-pr-review-iter-$pr_iteration" "$fix_prompt" "implement-issue-fix.json" "$pr_fix_agent")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment #13: PR Fix Result
            comment_pr "$pr_number" "PR Review Fix (Iteration $pr_iteration)" "$fix_summary" "$pr_fix_agent"

            # Re-run quality loop after PR review fixes
            log "Re-running quality loop after PR review fixes..."
            run_quality_loop "$worktree" "$branch" "pr-fix"

            # Push updates
            log "Pushing updates to PR..."
            git_with_retry -C "$worktree" push origin "$branch" || log "Warning: Could not push to origin"
        fi
        done

        set_stage_completed "pr_review"
    fi

    # -------------------------------------------------------------------------
    # STAGE: TECH DOCS (assess and write/update technical documentation)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "tech_docs"; then
        log "Skipping tech_docs stage (already completed)"
    else
        set_stage_started "tech_docs"

        local tech_docs_prompt="Assess whether the changes in PR #$pr_number for issue #$ISSUE_NUMBER require new or updated technical documentation in docs/{domain}/ folders.

Working in worktree $worktree on branch $branch.

Step 1: Analyze the scope of changes:
  git -C $worktree diff $BASE_BRANCH...HEAD --stat
  git -C $worktree diff $BASE_BRANCH...HEAD --name-only

Step 2: Review existing docs:
  ls $worktree/docs/

Step 3: Determine if documentation changes are needed. Docs ARE needed when:
  - A new subsystem, service, or integration was added
  - An existing architecture or data flow changed significantly
  - New API endpoints were introduced
  - A complex feature was added that needs design explanation
  - Infrastructure or deployment configuration changed

Docs are NOT needed when:
  - Only minor bug fixes or small tweaks
  - CSS/styling changes only
  - Test-only changes
  - Changes already covered by existing docs

Step 4: If docs are needed:
  - Create new docs in the appropriate docs/{domain}/ folder
  - Or update existing docs to reflect the changes
  - Use GitHub Markdown with Mermaid diagrams, alerts, tables, collapsible sections
  - Ensure the domain README.md links to any new docs
  - Commit with message: docs(issue-$ISSUE_NUMBER): add/update technical documentation
  - Push to branch: git -C $worktree push origin $branch

Step 5: If no docs are needed, set status to 'skipped' and explain why.

Output the assessment result, any docs created/updated, and a summary."

        local tech_docs_result
        tech_docs_result=$(run_stage "tech-docs" "$tech_docs_prompt" "implement-issue-tech-docs.json" "technical-doc-writer")

        local tech_docs_status tech_docs_summary docs_needed
        tech_docs_status=$(printf '%s' "$tech_docs_result" | jq -r '.status')
        tech_docs_summary=$(printf '%s' "$tech_docs_result" | jq -r '.summary // "Documentation assessment completed"')
        docs_needed=$(printf '%s' "$tech_docs_result" | jq -r '.docs_needed')

        if [[ "$docs_needed" == "true" ]]; then
            # Build actions list for comment
            local actions_md
            actions_md=$(printf '%s' "$tech_docs_result" | jq -r '.actions // [] | map("- **\(.action):** `\(.file)` — \(.description)") | join("\n")')

            comment_pr "$pr_number" "Technical Documentation" "**Documentation updated for this PR.**

$actions_md

$tech_docs_summary" "technical-doc-writer"
        else
            comment_pr "$pr_number" "Technical Documentation" "No documentation changes needed.

$tech_docs_summary" "technical-doc-writer"
        fi

        printf '%s\n' "$tech_docs_result" > "$LOG_BASE/context/tech-docs-output.json"
        set_stage_completed "tech_docs"
        log "Tech docs stage complete. Docs needed: $docs_needed"
    fi

    # -------------------------------------------------------------------------
    # STAGE: COMPLETE → PR comment #14
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "complete"; then
        log "Workflow already completed"
    else
        set_stage_started "complete"

        local complete_prompt="Generate a completion summary for PR #$pr_number implementing issue #$ISSUE_NUMBER.

Include:
- Issue and branch info
- Decisions made during implementation
- Reviews passed
- Final status

Output a summary suitable for a GitHub PR comment."

        local complete_result
        complete_result=$(run_stage "complete" "$complete_prompt" "implement-issue-complete.json")

        local complete_summary
        complete_summary=$(printf '%s' "$complete_result" | jq -r '.summary // "Implementation completed successfully"')

        # Comment #14: Implementation complete
        comment_pr "$pr_number" "Implementation Complete" "Issue #$ISSUE_NUMBER has been implemented!

**Branch:** \`$branch\`
**PR:** #$pr_number

$complete_summary

---
*This PR is ready for human review and merge.*"

        set_stage_completed "complete"
        set_final_state "completed"
    fi

    # Ensure final status is in log dir (no-op if STATUS_FILE is already there)
    sync_status_to_log

    # Run retrospective before final exit (explicit call for successful runs)
    run_retrospective 0

    log "=========================================="
    log "Implement Issue Complete"
    log "=========================================="
    log "Issue: #$ISSUE_NUMBER"
    log "PR: #$pr_number"
    log "Branch: $branch"
    log "Status: completed"

    exit 0
}

# Run main
main "$@"
