---
name: implement-issue
description: Use when given a GitHub issue number and base branch to implement end-to-end
argument-hint: "[issue-number] [base-branch]"
---

# Implement Issue

End-to-end issue implementation via orchestrator script.

**Announce at start:** "Using implement-issue to run orchestrator for #$ISSUE against $BRANCH"

**Arguments:**
- `$1` — GitHub issue number (required)
- `$2` — Base branch name (required)

## Invocation

Immediately launch the orchestrator:

```bash
.claude/scripts/implement-issue-orchestrator.sh \
  --issue $ISSUE_NUMBER \
  --branch $BASE_BRANCH
```

Or with explicit agent override:

```bash
.claude/scripts/implement-issue-orchestrator.sh \
  --issue $ISSUE_NUMBER \
  --branch $BASE_BRANCH \
  --agent bulletproof-frontend-developer
```

## Monitoring

Each run creates its own status.json inside the log directory:

```bash
# Find the latest run's status file
jq . logs/implement-issue/issue-${ISSUE_NUMBER}-*/status.json
```

Watch live:

```bash
# Replace with your actual log dir path (shown at startup)
watch -n 5 'jq -c "{state,stage:.current_stage,task:.current_task,quality:.quality_iterations}" logs/implement-issue/issue-123-20260221-153045-12345/status.json'
```

## Stages

| Stage | Agent | Description |
|-------|-------|-------------|
| setup | default | fetch, worktree, research, evaluate, plan |
| implement | per-task | execute each task from plan |
| task-review | spec-reviewer | verify task achieved goal |
| fix | per-task | address review findings (uses task's agent) |
| simplify | code-simplifier | clean up code |
| test | php-test-validator | run test suite |
| review | code-reviewer | internal code review |
| docs | phpdoc-writer | add PHPDoc blocks |
| pr | default | create/update PR |
| spec-review | spec-reviewer | verify PR achieves issue goals |
| code-review | code-reviewer | final code quality check |
| tech-docs | technical-doc-writer | assess/write/update docs in docs/{domain}/ |
| complete | default | post summary |

## Available Implementation Agents

The plan stage selects the best agent per task from:

| Agent | Use For |
|-------|---------|
| laravel-backend-developer | PHP/Laravel: controllers, models, services, middleware, migrations, API, PHPUnit |
| bulletproof-frontend-developer | CSS, responsive design, Blade templates, frontend code |
| bash-script-craftsman | Shell scripts, portability, BATS tests |
| technical-doc-writer | Architecture docs, design docs, data flows, API contracts in docs/{domain}/ |

## Schemas

Located in `.claude/scripts/schemas/implement-issue-*.json`

## Logging

Logs written to `logs/implement-issue/issue-N-timestamp/`:
- `orchestrator.log` — main log
- `stages/` — per-stage Claude output
- `context/` — parsed outputs (tasks.json, etc.)
- `status.json` — real-time status (primary location, no root-level status.json)

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success, PR created and approved |
| 1 | Error during a stage |
| 2 | Max iterations exceeded |
| 3 | Configuration/argument error |

## CLI Session Isolation

All `claude -p` invocations in orchestrator scripts **must** use `--no-resume` to prevent
session context contamination. Without it, the CLI may resume a cached session and the model
will return "already processed" instead of following the schema prompt — causing "No structured
output" failures.

**Exception:** Explicit `--resume $SESSION_ID` after rate limit recovery is intentional and correct.

## Integration

Called by `handle-issues` via `batch-orchestrator.sh`.
