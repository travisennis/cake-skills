---
name: analyzing-cake-sessions
description: Analyze a persisted cake session (`~/.local/share/cake/sessions/{uuid}.jsonl`, or `$CAKE_DATA_DIR/sessions/`) to find issues, recommend setup improvements, or score how cake performed. Use `debugging-cake` for reactive triage of a just-failed run, `debugging-cake-sandbox` for sandbox errors.
---

# Analyzing Cake Sessions

Inspect persisted cake session files and produce a concise, evidence-backed
report. The workflow always produces a **findings report**. When the request is
phrased as evaluation, scoring, assessment, or quality review (rather than
investigation), also append the **Quality scoring appendix** in Phase 5.
Triggers like "how well did cake do", "rate this run", "evaluate this session"
call for the appendix; "what went wrong", "find issues", "audit this session" do
not.

## Phase 0: Ground the analysis

Analyze what cake can actually do and what the user actually configured - not
what the analyzing agent assumes.

1. Read the session's own `prompt_context` records: they are the exact AGENTS.md,
   skills, environment, and tool context that run received. This is the primary
   evidence for prompt/context findings.
2. Ground recommendations in the user's setup. By default, name changes to the
   user's own artifacts: `AGENTS.md`, skills, the system prompt, tool selection,
   and `settings.toml`. Recommend cake-upstream code changes only when the user
   is developing cake or explicitly wants to file an issue, and say so.
3. Only raise issues valid for cake's actual toolset. A user-facing tool list is
   in the session's `prompt_context`; if you have the cake source, its tool
   definitions are authoritative under `src/clients/tools/`.

## Phase 1: Locate and validate the session

Accept: an absolute session path; a session UUID (resolved under the sessions
directory); or an implicit request to find the most recent/interesting session.

```bash
if [ -n "${CAKE_DATA_DIR:-}" ]; then
  SESSION_DIR="$CAKE_DATA_DIR/sessions"
  TELEMETRY_DIR="$CAKE_DATA_DIR/session-telemetry"
else
  SESSION_DIR="$HOME/.local/share/cake/sessions"
  TELEMETRY_DIR="$HOME/.cache/cake/session-telemetry"
fi

ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -10   # recent candidates
SESSION="$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)"
printf '%s\n' "$SESSION"
```

If the input is ambiguous, list candidates and choose by working directory,
timestamp, and visible task content. The newest file may be the session running
this analysis; check its first user message and skip it if so.

Current persisted sessions are append-only JSONL format version 4:

1. First non-empty line: one `session_meta`.
2. Each CLI invocation appends `task_start`.
3. The invocation may append `prompt_context` audit records.
4. Conversation records: `message`, `reasoning`, `function_call`,
   `function_call_output`.
5. The invocation should end with `task_complete`.

Validate: the file exists and is valid JSONL (allow a possible partial trailing
record); the first record is `session_meta` with `format_version: 4`. Inspect
`session_id`, `working_directory`, `model`, `tools`, `cake_version`, git
metadata. Files beginning with `session_start`, `init`, or `result` are legacy;
redirected `--output-format stream-json` output is not a resumable session.

### Liveness

Before treating a missing trailing `task_complete` as truncation or a crash,
check whether cake is still writing. Mtimes are only a signal.

```bash
SESSION_ID="$(awk 'NF { print; exit }' "$SESSION" | jq -r '.session_id')"
TELEMETRY="$TELEMETRY_DIR/$SESSION_ID.ndjson"

printf 'Current UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
TZ=UTC stat -f 'JSONL mtime: %Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$SESSION"   # macOS
[ -f "$TELEMETRY" ] && TZ=UTC stat -f 'telemetry mtime: %Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$TELEMETRY"
tail -3 "$SESSION"
[ -f "$TELEMETRY" ] && tail -3 "$TELEMETRY"

if command -v lsof >/dev/null 2>&1; then
  lsof -t "$SESSION" 2>/dev/null
elif command -v fuser >/dev/null 2>&1; then
  fuser "$SESSION" 2>/dev/null
else
  echo 'No lsof or fuser; liveness unknown.' >&2
fi
```

On Linux, use `TZ=UTC stat -c 'JSONL mtime: %y' "$SESSION"`. A non-empty
`lsof`/`fuser` result means cake still holds the session; if either mtime
advances, wait and recheck. Classify a missing trailing `task_complete` as
truncated only after mtimes stop advancing and no writer is found.

Do not modify the session file during analysis.

## Phase 2: Understand record types

Distinguish records restored into model history (they consume LLM context) from
diagnostic metadata. This matters for any "session bloat" or "context growth"
recommendation.

**LLM-visible** (restored via `--resume`/`--fork`): `message`, `reasoning`,
`function_call`, `function_call_output`.

**Metadata / audit-only** (never restored): `session_meta`, `task_start`,
`task_complete`, `prompt_context`, `hook_event`, `skill_activated`.

Implications: `hook_event`, `prompt_context`, `skill_activated`, and task
boundaries add zero LLM context; `prompt_context` is an audit snapshot, not what
the model saw on later turns.

> **Reasoning `summary` caveat**: it is a protocol artifact, not a human summary.
> On Chat Completions cake hardcodes `["Thinking..."]`; on the Responses API it is
> echoed for multi-turn but its value depends on the provider. Judge reasoning by
> the `content` field, never `summary`.

## Phase 3: Segment tasks and reconstruct flow

- Group records from each `task_start` to its matching `task_complete`. Capture
  task id, timestamp, duration, subtype, `is_error`, turns, `tool_call_count`,
  usage, final result/error, `permission_denials`.
- Flag trailing tasks without `task_complete`, incomplete assistant messages,
  malformed final records, abrupt endings.
- Correlate every `function_call` with its `function_call_output` by `call_id`.
  Flag missing outputs, orphan outputs, duplicate ids, malformed arguments,
  invalid tool names, unexpected ordering.
- Summarize each user request and final assistant response.

## Phase 4: Inspect each surface

### Tool use

Tool call errors, result errors, sandbox/permission denials, network failures,
parse failures, missing files, command failures, failed tests, edit conflicts;
repeated or near-identical calls (stuck patterns); verbose results that polluted
context (full logs, broad dumps, unfiltered searches, whole build output); cases
where `rg`, `jq`, a targeted read, a narrower command, or a structured parser
would have worked.

If the session shows extensive or repeated Edit failures, load
`reference/edit-tool-session-analysis.md` for a deeper failure/attribution
methodology.

### Prompt and context

Review `prompt_context` for AGENTS.md, skills, environment, cwd, date, sandbox
permissions, and available tools. Flag missing, stale, unclear, or conflicting
context; whether repository instructions were followed (especially verification
after code/config/dependency changes); missing tools, unclear tool descriptions,
or permission guidance that would have helped.

### Reasoning

Clear decomposition vs. stuck patterns; appropriate planning and sequencing;
self-correction. Use `content`, not `summary`.

### Instruction following

Compare the user's request with the actions and final answer. Flag premature
finals, partial implementation, unnecessary questions, ignored constraints,
missing verification, unreported blockers, overbroad changes, poor preservation
of user changes; cases where the agent should have read local docs first, used a
skill, asked permission, or avoided a risky action.

### Performance and cost

Use `task_complete.duration_ms`, `turn_count`, and `usage` for slow, expensive,
or inefficient tasks: high reasoning tokens, many turns for simple tasks,
repeated high-token tool outputs, large context growth, retry loops, truncation,
timeout risks. Correlate session id and timestamps with
`$CAKE_DATA_DIR/cake.YYYY-MM-DD.log` or `~/.cache/cake/cake.YYYY-MM-DD.log`.

### Vanished uncommitted work

Use this branch when a session reports that uncommitted files disappeared, or a
worktree is clean in a way the session cannot explain. A clean reflog and empty
`git stash list` do **not** exclude a hook-runner worktree snapshot: a runner
installed as a Git hook shim (for example `prek` or `pre-commit`) can write the
dirty tracked files to a patch in its own cache, revert them so the hook sees a
clean tree, then re-apply the patch afterward - leaving no commit, stash, reflog
entry, or branch move. If the hook is killed first (Bash timeout, cancelled turn,
crash), the files stay gone and the runner's patch, stored outside the repo, is
the only record.

Keep the procedure read-only and separate evidence from inference: a patch whose
contents match the missing work at a consistent timestamp is direct evidence;
"a hook could have done this" is not. Follow
`reference/vanished-work-hook-patches.md`, and use `reference/jq-recipes.md` for
timestamp correlation.

## Phase 5: Produce the report

### Issue categories

`tool_call_error`, `tool_result_error`, `repeated_tool_call`,
`permission_issue`, `performance_issue`, `missing_context`,
`prompt_or_instruction_gap`, `instruction_following_issue`,
`missing_tool_or_capability`, `session_integrity_issue`.

### Evidence requirements

For every finding include: record type and line number when available; task id
and timestamp when available; tool name and `call_id` for tool findings; the
smallest useful excerpt; impact on the task; and a specific recommendation.
Never paste large tool outputs.

### Findings report (always produced)

1. **Executive Summary** - overall health, top three opportunities.
2. **Session Metadata** - id, format version, model, working directory, cake
   version, tools, task count, duration, turns, token usage.
3. **Findings** - severity, category, evidence, impact, recommendation.
4. **Task Timeline** - request, outcome, duration, turns, tools, errors, context.
5. **Tool Call Analysis** - counts by tool, failures, repeats, large outputs,
   permission denials, missing/orphan outputs.
6. **Prompt and Context Analysis** - sufficiency of AGENTS.md, skills, tools,
   environment.
7. **Performance Notes** - slow tasks, high tokens, excessive turns, truncation
   or timeout risks.
8. **Recommended Improvements** - prioritized and implementation-ready. Default
   to the user's own setup: system prompt, tool descriptions they control, tool
   selection, AGENTS.md, skills, and settings. Add a separate, clearly labeled
   "Cake upstream" list only when the user develops cake or wants to file an
   issue.

### Quality scoring appendix (only for evaluation/scoring requests)

1. **Task Completion** - Completed / Partially / Failed, with evidence.
2. **Quality Assessment** - correctness, completeness, efficiency, code quality.
3. **Improvement Areas** (high/medium/low): system-prompt gaps; tool-selection
   and tool-description gaps; missing capabilities; AGENTS.md/skills gaps; error
   handling and recovery.

### Persistence

Default to returning the report in the response. Create a file only when the
user explicitly asks; prefer a named artifact such as `session-analysis.md`. Do
not invent persistent issue trackers.

## Essential commands

```bash
SESSION=~/.local/share/cake/sessions/{uuid}.jsonl

head -1 "$SESSION" | jq '.'                                 # validate header
jq -r '.type' "$SESSION" | sort | uniq -c                   # shape of the session
jq 'select(.type == "task_complete") | {task_id, subtype, is_error, duration_ms, turn_count, tool_call_count, result, error, usage, permission_denials}' "$SESSION"
tail -5 "$SESSION" | jq '.'                                 # how it ended
```

For the full jq cookbook (orphan detection, repeated-call signals, log/telemetry
correlation, conversation searches, hook-event queries) see
`reference/jq-recipes.md`.

## Checklist

- [ ] Located and read the session (header is `session_meta`, `format_version: 4`)
- [ ] Segmented by `task_start`/`task_complete`; identified the original tasks
- [ ] Traced tool calls and results, correlated by `call_id`
- [ ] Reviewed reasoning by `content`, not `summary`
- [ ] Reviewed `prompt_context` for AGENTS.md, skills, env, cwd, date
- [ ] Checked the final response for completion
- [ ] Tool selection, parameters, result interpretation; repeated calls
- [ ] Permission/sandbox issues; missing context or prompt gaps
- [ ] Reasoning flaws; performance/token/turn anomalies
- [ ] Uncommitted work that vanished while Git stayed clean
- [ ] Session integrity
- [ ] Findings carry evidence and implementation-ready recommendations, prioritized

## Worked example

Read evidence, extract a finding, write it up.

**Count record types:**

```bash
$ jq -r '.type' "$SESSION" | sort | uniq -c
   1 session_meta
   2 task_start
   2 task_complete
  18 message
  11 reasoning
  14 function_call
  14 function_call_output
   6 prompt_context
```

Balanced calls and outputs (14/14) - no orphans. Two tasks, both completed.

**Spot-check tool calls:**

```bash
$ jq 'select(.type == "function_call") | {name, args: (.arguments[0:120])}' "$SESSION"
{ "name": "bash", "args": "{\"cmd\":\"cargo test --all\"}" }
{ "name": "bash", "args": "{\"cmd\":\"cargo test --all\"}" }
{ "name": "bash", "args": "{\"cmd\":\"cargo test --all\"}" }
```

Three identical calls in a row stands out. If the outputs are nearly identical
and no edit happened between them, this is a stuck pattern.

**Write the finding:**

```markdown
**Severity**: Medium
**Category**: `repeated_tool_call`
**Evidence**: function_call records at lines 42, 51, 60 (call_ids fc_a1, fc_a2,
  fc_a3), all `bash` with identical `cargo test --all`, no intervening edit.
**Impact**: ~90 s wasted, +12k tokens of duplicated test output in context.
**Recommendation**: Add a line to AGENTS.md: do not re-run the full suite
  unless a file changed since the last run.
```

## File locations

| File | Purpose |
| --- | --- |
| `~/.local/share/cake/sessions/{uuid}.jsonl` | Session files (or `$CAKE_DATA_DIR/sessions/`) |
| `~/.cache/cake/session-telemetry/{uuid}.ndjson` | Per-session telemetry |
| `~/.cache/cake/cake.YYYY-MM-DD.log` | Daily logs (or `$CAKE_DATA_DIR/...`) |

Cake grants read-only access to these roots by default, so the Bash tool can read
them without extra grants. If a read is denied, see `debugging-cake-sandbox`.
