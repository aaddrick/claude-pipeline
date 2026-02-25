# Skill Authoring Best Practices (Condensed Reference)

## Frontmatter Requirements

```yaml
---
name: Processing PDFs          # max 64 chars, gerund form preferred
description: Extract text...   # max 1024 chars, third person ONLY
---
```

**Frontmatter fields**: only `name` and `description` — nothing else.

**Name conventions:**
- Preferred: gerund form ("Processing PDFs", "Analyzing Spreadsheets")
- Acceptable: noun phrases ("PDF Processing") or action form ("Process PDFs")
- Avoid: "Helper", "Utils", "Tools", "Documents", "Data"

**Description rules:**
- Third person only. "Processes Excel files" not "I can help you" or "You can use this"
- Include WHAT it does AND WHEN to use it (triggers/keywords)
- This is the only signal Claude uses for skill selection among 100+ skills

Good description:
```yaml
description: Extract text and tables from PDF files, fill forms, merge documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction.
```

Bad descriptions:
```yaml
description: Helps with documents
description: Processes data
```

## File/Directory Structure

```
my-skill/
├── SKILL.md              # Main entry point (keep under 500 lines)
├── reference.md          # Loaded on demand
├── advanced.md           # Loaded on demand
└── scripts/
    ├── validate.py       # Executed, not read into context
    └── process.py
```

- SKILL.md body: hard limit of 500 lines for optimal performance. Split beyond this.
- Reference files are read only when Claude needs them (zero context cost until accessed).
- Scripts are executed via bash — their source code never consumes context tokens.
- Use forward slashes in all paths. Never backslashes, even on Windows.
- Name files descriptively: `form_validation_rules.md` not `doc2.md`.

## Progressive Disclosure

SKILL.md acts as a table of contents. Link to supplementary files:

```markdown
## Advanced features

**Form filling**: See [FORMS.md](FORMS.md) for complete guide
**API reference**: See [REFERENCE.md](REFERENCE.md) for all methods
```

**Critical rule: Keep references one level deep from SKILL.md.**

Bad (nested references — Claude may read files incompletely via `head`):
```
SKILL.md → advanced.md → details.md → actual_info.md
```

Good (all references point directly from SKILL.md):
```
SKILL.md → advanced.md
SKILL.md → reference.md
SKILL.md → examples.md
```

For reference files over 100 lines, add a table of contents at the top so Claude can orient itself even on partial reads.

## Discovery Anti-Pattern: Ignored Files

Watch for files Claude never accesses. If a bundled file is never read, either:
- The SKILL.md doesn't signal it clearly enough
- The content is unnecessary

Watch for files Claude over-accesses. If Claude repeatedly reads the same file, move that content into SKILL.md directly.

## Degrees of Freedom

Match instruction specificity to task fragility:

**High freedom** (multiple valid approaches, context-dependent):
```markdown
1. Analyze the code structure
2. Check for potential bugs
3. Suggest improvements
```

**Low freedom** (fragile operations, exact sequence required):
```markdown
Run exactly this script:
```bash
python scripts/migrate.py --verify --backup
```
Do not modify the command or add additional flags.
```

## Workflows and Feedback Loops

For multi-step tasks, provide a copyable checklist:

```markdown
Task Progress:
- [ ] Step 1: Analyze the form (run analyze_form.py)
- [ ] Step 2: Create field mapping (edit fields.json)
- [ ] Step 3: Validate mapping (run validate_fields.py)
- [ ] Step 4: Fill the form (run fill_form.py)
```

For quality-critical tasks, include an explicit validation loop:
```markdown
1. Make edits
2. Validate immediately: `python scripts/validate.py`
3. If validation fails: fix errors, run validation again
4. Only proceed when validation passes
```

If a workflow exceeds ~10 steps, move it to a separate file and instruct Claude to read it.

## MCP Tool References

Always use fully qualified tool names to avoid "tool not found" errors:

```markdown
Use the BigQuery:bigquery_schema tool to retrieve table schemas.
Use the GitHub:create_issue tool to create issues.
```

Format: `ServerName:tool_name`. Without the server prefix, Claude may fail to locate the tool when multiple MCP servers are active.

## Content Anti-Patterns

**Too many options** — pick a default, provide an escape hatch:
```markdown
Bad:  "You can use pypdf, or pdfplumber, or PyMuPDF, or pdf2image..."
Good: "Use pdfplumber. For scanned PDFs requiring OCR, use pdf2image instead."
```

**Time-sensitive information** — use "old patterns" section:
```markdown
Bad:  "If you're doing this before August 2025, use the old API."
Good: Use "## Old patterns" with <details> block for deprecated info.
```

**Inconsistent terminology** — pick one term per concept:
```markdown
Bad:  Mix "API endpoint", "URL", "API route", "path"
Good: Always "API endpoint"
```

**Voodoo constants in scripts** — always justify non-obvious values:
```python
# Bad
TIMEOUT = 47

# Good
# HTTP requests typically complete within 30s; 47s accounts for slow connections
TIMEOUT = 47
```

**Punting errors to Claude** — handle them in scripts:
```python
# Bad: just fail and let Claude figure it out
return open(path).read()

# Good: handle the error condition
try:
    return open(path).read()
except FileNotFoundError:
    print(f"File {path} not found, creating default")
    open(path, 'w').close()
    return ''
```

**Assuming packages are installed:**
```markdown
Bad:  "Use the pdf library to process the file."
Good: "Install: `pip install pypdf`
      Then: from pypdf import PdfReader"
```

## Testing Methodology

**Evaluation-driven development** — create evaluations BEFORE extensive documentation:

1. Run Claude on representative tasks without the skill. Document specific failures.
2. Create 3+ evaluation scenarios targeting those gaps.
3. Measure baseline (no skill).
4. Write minimal instructions to pass evaluations.
5. Iterate.

Evaluation structure:
```json
{
  "skills": ["my-skill"],
  "query": "Extract all text from this PDF and save to output.txt",
  "files": ["test-files/document.pdf"],
  "expected_behavior": [
    "Reads the PDF using an appropriate library",
    "Extracts text from all pages",
    "Saves to output.txt in a readable format"
  ]
}
```

**Model testing:** Test with all models you plan to use. Haiku may need more guidance than Opus. Instructions that work for Opus may over-explain for Haiku.

**Iterative refinement loop:**
- Claude A (skill author) writes and refines the skill
- Claude B (fresh instance with skill loaded) tests on real tasks
- Observe Claude B's unexpected navigation paths, missed connections, ignored files
- Return observations to Claude A for targeted fixes

## Pre-Publish Checklist

- [ ] Description is third person, specific, includes use-case triggers
- [ ] SKILL.md body under 500 lines
- [ ] All references are one level deep from SKILL.md
- [ ] Reference files over 100 lines have a table of contents
- [ ] No time-sensitive information (or isolated in "old patterns" section)
- [ ] Consistent terminology throughout
- [ ] Forward slashes in all file paths
- [ ] Scripts handle errors explicitly (no punting to Claude)
- [ ] Magic numbers are documented/justified
- [ ] Required packages explicitly listed with install commands
- [ ] MCP tool references use `ServerName:tool_name` format
- [ ] At least 3 evaluations created and passing
- [ ] Tested against all target models (Haiku if used)
