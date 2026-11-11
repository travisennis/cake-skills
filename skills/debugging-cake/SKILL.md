---
name: debugging-cake
description: Triage a recent cake CLI failure fast: `None`/empty/truncated output, a bare "Tool error:", a crash, hang, or mid-stream interrupt, or the user says their last run broke. Names what broke; not a full session review. Use `debugging-cake-sandbox` for sandbox denials, `analyzing-cake-sessions` for review.
---

# Debugging Failed Cake Runs

Fast, reactive triage of the user's most recent failed run. Cake reads two
contracts when it reports a result: exit codes and the persisted-session layout.
This skill restates only what triage needs.

Start with Step 0 to separate a broken run from a configuration mismatch. When
the run itself broke, use `cake debug session` if the build supports it: it
inspects the transcript, telemetry sidecar, and related log paths read-only and
reports state, liveness, tasks, retries, and slow operations. Use the raw-record
fallback only for older builds or for evidence the report deliberately omits.

## Step 0: Rule out current configuration

A failed-looking run is not always a broken session. If the symptom is a
settings error, a missing tool or skill, a permission denial, or a run that used
the wrong model or trust state, inspect the resolved configuration first. Keep
`cake debug session` primary when the run itself broke: a crash, hang, truncated
or empty result, mid-stream interrupt, or a bare `Tool error:` from the selected
session.

- Settings load failure (exit `3`), unknown key, or invalid profile or model ->
  `cake doctor`.
- A built-in, toolbox, or MCP tool is missing, filtered, or unknown ->
  `cake debug tools`.
- A skill did not fire, was omitted, or the catalog is over budget ->
  `cake debug skills`.
- A permission or sandbox denial (`Operation not permitted`, os error 1) ->
  `debugging-cake-sandbox`; start with `cake debug grants`.
- Wrong model, credential presence, project trust, or resolved limits ->
  `cake debug config`; route configuration changes to `configuring-cake`.

`cake debug grants` is authoritative for the effective filesystem grant value and
every source behind it. `cake doctor` reports the merged configured grants, and
`cake debug config` carries a grant summary plus the broader resolved
configuration. The full command-to-question map is in `configuring-cake`.

The `doctor`, `debug config`, `debug grants`, and `debug tools` reports are new
in 077. `debug skills` predates 077 but its report shape changed in 077i, so its
presence proves only that the command exists; older builds may print less than
the catalog inventory described in `configuring-cake`.

Probe the command list, not `--help` on the command itself: an unknown top-level
token is parsed as a prompt, so `cake doctor --help` can print top-level help and
exit `0` on a build without `doctor`.

```bash
has_top() { cake --help 2>/dev/null | grep -Eq "^[[:space:]]+$1([[:space:]]|$)"; }
has_debug() { cake debug --help 2>/dev/null | grep -Eq "^[[:space:]]+$1([[:space:]]|$)"; }

has_top doctor && cake doctor
has_debug config && cake debug config
has_debug grants && cake debug grants
has_debug tools && cake debug tools
has_debug skills && cake debug skills
```

If a probe fails, fall back to `cake debug models` where available (settings
parse and unknown keys), `cake --help` (flags), and manual settings and sandbox
inspection. The manual grant table in `debugging-cake-sandbox` remains the
fallback for a denial.

## Step 1: Choose the target session

The newest session may be the session running this investigation (a diagnostic
launched from inside cake). Inspect `first_prompt` before choosing a target; do
not let the probe select itself.

Set the state roots first:

```bash
if [ -n "${CAKE_DATA_DIR:-}" ]; then
  SESSION_DIR="$CAKE_DATA_DIR/sessions"
  CACHE_DIR="$CAKE_DATA_DIR"
else
  SESSION_DIR="$HOME/.local/share/cake/sessions"
  CACHE_DIR="$HOME/.cache/cake"
fi
TELEMETRY_DIR="$CACHE_DIR/session-telemetry"
LOG_DIR="$CACHE_DIR"
```

`CAKE_DATA_DIR` relocates sessions, cache, logs, and telemetry together; without
it, sessions use `~/.local/share/cake/sessions` while cache, logs, and telemetry
use `~/.cache/cake`.

Prefer cake's listing, which reports sessions for the current working directory,
newest first:

```bash
cake sessions list --json |
  jq -r '.data.sessions[] | [.session_id, .timestamp, .first_prompt] | @tsv' |
  head -3
```

If the failing run was in another directory, run the listing there, or use the
session path you already have. If `cake sessions list --json` is unavailable,
fall back to the filesystem view and inspect the first user message:

```bash
ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -3 |
while IFS= read -r candidate; do
  printf '\n%s\n' "$candidate"
  prompt="$(jq -r 'select(.type == "message" and .role == "user") | .content' \
    "$candidate" 2>/dev/null | head -1)"
  printf '%s\n' "${prompt:-"(no user message)"}"
done
```

Set `SESSION_ID` to the chosen UUID and derive the transcript path:

```bash
SESSION_ID="550e8400-e29b-41d4-a716-446655440000"
LATEST="$SESSION_DIR/$SESSION_ID.jsonl"
```

If you were given a transcript path instead of a UUID, use the filename stem
when it is the UUID; otherwise derive the UUID from the first record. `cake debug
session` requires the UUID, not the path:

```bash
LATEST="/absolute/path/to/session.jsonl"
SESSION_ID="$(basename "$LATEST" .jsonl)"
# If the filename is not the UUID:
SESSION_ID="$(awk 'NF { print; exit }' "$LATEST" | jq -r '.session_id')"
```

The command resolves `SESSION_ID` under `SESSION_DIR`. A transcript outside that
root, such as a copied snapshot, must be placed under `SESSION_DIR` or under a
temporary `CAKE_DATA_DIR/sessions/` before it can be diagnosed; otherwise use the
raw fallback.

## Step 2: Run the session diagnostic

`cake debug session` requires a cake build at or after commit `100aec5`.
Feature-probe first; an older build reports the `session` subcommand as
unrecognized:

```bash
if cake debug session --help >/dev/null 2>&1; then
  cake debug session "$SESSION_ID"
else
  echo "This cake build predates 'debug session'; use the raw fallback in Step 4." >&2
fi
```

The command is read-only. It never resumes or forks the session, takes a blocking
writer lock, repairs or truncates an artifact, runs hooks, gates, MCP servers,
toolbox tools, or providers, or uploads anything. It copies no prompt or
assistant text, tool arguments or output, hook command or output, gate evidence
payload, provider error text or URL, credential, or log body into the report.

The text report starts with the top-level state and liveness. JSON field names
use underscores; the text labels hyphenate or spell them out:

| Text state | JSON `summary.state` | Meaning |
| --- | --- | --- |
| `completed` | `completed` | The last task ended cleanly. If the user still saw bad output, the run mechanics are sound; inspect the result and the raw tail. |
| `interrupted` | `interrupted` | No terminal task and no writer. The run stopped mid-task; inspect the last raw record. |
| `live` | `live` | A cake process still holds the append lock. Wait for it to finish, then rerun; never classify from a partial snapshot. |
| `unknown-liveness` | `unknown_liveness` | The lock probe could not decide. Treat liveness as unknown; wait, or use the fallback liveness check in Step 4, but do not treat a snapshot as final. |
| `corrupt` | `corrupt` | The transcript is malformed or unsupported. Read `Diagnostics`; this exits `1`. |

Liveness is separate: text `not held` is JSON `not_live`, text `active writer` is
JSON `live`, and text `unknown` is JSON `unknown`. `diagnosis complete: yes`
(`diagnosis_complete: true`) means the report read complete artifacts.
`no`/`false` means a partial tail or a corrupt or unreadable artifact; never
present a partial-tail result as a completed diagnosis. A missing telemetry
sidecar is a warning, not an error.

Exit behavior:

- `0` for a clean report or warnings, including missing telemetry and a partial
  tail.
- `1` for a corrupt or unreadable transcript or telemetry, or an export
  create/write/flush failure.
- `3` for an invalid UUID, a missing session, or an invalid export destination.

Use `--slow-ms <MS>` to change the slow-operation threshold (default `2000`).
The report shows at most 20 slow rows while the summary keeps the full count.
The `Tasks` and `Invocations` sections carry task boundaries, terminal state,
durations, turns, tool counts, usage, retries, slow-operation counts, and the
observed task-to-invocation correlation (`task_id`, `start_time`, or unmatched).
Correlation is explicit: do not assume an unmatched invocation belongs to a
task. The `Artifacts` section lists the log directory and related daily log
paths; the command does not read log bodies. The compact current-configuration
section describes the invocation running the diagnostic, not the selected
session; a project-trust warning does not block the read-only report.

For a machine-readable view:

```bash
cake debug session "$SESSION_ID" --json |
  jq '{state:.summary.state, liveness:.summary.liveness,
       diagnosis_complete:.summary.diagnosis_complete,
       tasks:[.data.tasks[] | {state, termination, retries, slow_operations}],
       checks:[.checks[] | {id, status, message}]}'
```

The document has `command`, `schema_version`, `status`, `summary`, `data`, and
`checks`. Besides the summary fields above, `data.tasks`, `data.invocations`,
`data.retries`, `data.slow_operations`, `data.artifacts`, `data.current_config`,
and `data.export` carry the detailed rows.

## Step 3: Share a redacted report

`--export` writes the same redacted document as `--json` to a new local file:

```bash
cake debug session "$SESSION_ID" --export ./session-diagnostic.json
```

The export is byte-identical to the `--json` stdout document. It is created only
when the target does not exist, is not a symlink, is not a source transcript or
telemetry path, and has an existing parent; the file mode is `0600` on Unix. A
relative path is accepted. The command refuses to overwrite an existing report;
choose a new path.

The target is reported in `data.export.path`; with `--export` alone, stdout
remains the text report, which also prints the export path. To confirm what was
written:

```bash
jq '{summary, export:.data.export}' ./session-diagnostic.json
```

The export is redacted, not anonymous. It omits prompts, message content, tool
arguments and output, hook command/stdout/stderr, provider URLs and error text,
gate evidence, log bodies, session-summary errors, and credential values. It
still contains the session id, task and invocation ids, model identity, artifact
paths, the working directory, timing, and operational counts. Review paths and
the working directory before sharing, and never treat the export as uploadable
or anonymous.

Older cake builds have no equivalent redacted export. Update cake or summarize
the problem without sharing the raw session, telemetry, or log files.

## Step 4: Raw evidence pass

The diagnostic report summarizes rather than copying record bodies. Run this
pass only when the report is unavailable or when it does not carry the exact raw
payload you need. Raw records can contain prompts, assistant text, tool output,
hook text, and provider errors; keep them local and never paste them into an
issue.

### 4a. Fallback liveness and snapshot

Skip this if `cake debug session` already reported `not held`/`not_live` or
`completed`/`interrupted`. Use it when the command is unavailable, when liveness
is `unknown`, or when you need an older-cake workflow. Do not diagnose a live
session from a partial snapshot.

```bash
if command -v lsof >/dev/null 2>&1; then
  lsof_status=0
  PIDS="$(lsof -t "$LATEST" 2>/dev/null)" || lsof_status=$?
  [ "$lsof_status" -gt 1 ] && { echo 'lsof failed; liveness unknown.' >&2; exit 1; }
elif command -v fuser >/dev/null 2>&1; then
  fuser_status=0
  PIDS="$(fuser "$LATEST" 2>/dev/null)" || fuser_status=$?
  [ "$fuser_status" -gt 1 ] && { echo 'fuser failed; liveness unknown.' >&2; exit 1; }
else
  echo 'Cannot verify that cake stopped: install lsof or fuser, then retry.' >&2
  exit 1
fi

if [ -n "$PIDS" ]; then
  printf 'Cake is still using %s (processes: %s). Wait, then retry.\n' "$LATEST" "$PIDS" >&2
  exit 1
fi
```

If the check errors, or the mtime changes while you wait, do not classify it yet.
Once no writer remains, snapshot securely before further analysis:

```bash
umask 077
TARGET_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/cake-session-target.XXXXXX")"
trap 'rm -f "$TARGET_SNAPSHOT"' EXIT
cp "$LATEST" "$TARGET_SNAPSHOT"
LATEST="$TARGET_SNAPSHOT"
echo "$LATEST"
```

Analyze the snapshot through the rest of this fallback.

### 4b. Last records

A complete invocation ends with `task_complete`; anything else means the task did
not finish cleanly.

```bash
tail -1 "$LATEST" | jq '{type, is_error, subtype, error}'
tail -5 "$LATEST" | jq '.'
```

| Last record type | Meaning |
| --- | --- |
| `task_complete` (no error) | Task finished normally - the problem is in the result, not the run |
| `task_complete` (`is_error`) | Ended with a recorded error - read `.error` |
| `reasoning` / `function_call` / `function_call_output` / `message` | Interrupted mid-stream (timeout, crash, signal) |
| `task_start` | Task never produced output |

An interrupt (Ctrl-C) does end with `task_complete`: cake writes an interrupted
outcome and exits `130`.

### 4c. Exact telemetry records

The diagnostic report already covers invocation grouping, retries, failed
attempts, tool-call errors, and slow operations. Use the sidecar `jq` only for
the exact payload the report omits:

```bash
TELEMETRY="$TELEMETRY_DIR/$SESSION_ID.ndjson"

if [ -f "$TELEMETRY" ]; then
  jq 'select(.type == "retry_scheduled")' "$TELEMETRY"
  jq 'select(.type == "tool_call" and .was_error == true)' "$TELEMETRY"
  jq 'select(.type == "session_summary")' "$TELEMETRY"
else
  echo "Telemetry sidecar not found: $TELEMETRY" >&2
fi
```

`retry_scheduled.detail` and `session_summary` can contain provider error text;
the report omits those fields, so do not paste them. Telemetry is a performance
sidecar, not resumable conversation history.

### 4d. Logs and session-id correlation

The diagnostic report lists related daily log paths. Use them when it is
available:

```bash
cake debug session "$SESSION_ID" --json |
  jq -r '.data.artifacts.logs[].path' |
  while IFS= read -r log; do
    grep -Hn -iE 'error|timeout|panic|truncat' "$log"
  done
```

For older builds, or when the report has no related logs, search the daily logs
directly:

```bash
grep -Hn -iE 'error|timeout|panic|truncat' "$LOG_DIR"/cake.*.log | tail -50
```

Common patterns: `output truncated` (a tool output hit its cap), API errors or
timeouts, a dropped stream, or a panic (cake itself crashed). To isolate the
session:

```bash
grep -Hn "$SESSION_ID" "$LOG_DIR"/cake.*.log
```

## Step 5: Why `None` happens

`None` or empty output almost always means **no completed assistant result was
produced** before the session ended. Typical causes: the model hit a token limit
mid-response; the response or stream timed out; the process was interrupted
(signal, panic, crash); or a tool call hung and never returned. The session file
then ends without `task_complete`, or `task_complete` carries `is_error: true`.

`cake debug session` distinguishes the cases: `interrupted` with
`diagnosis_complete: true` means the artifacts are complete and the task simply
has no terminal completion; `live` means a writer is still there; `corrupt` or a
`diagnosis_complete: false` result means the evidence is incomplete and you must
not present it as a finished diagnosis.

## Step 6: Resuming a session

```bash
cake sessions list
cake --resume {uuid} "Try again"
```

`--resume` takes a UUID, not a file path. Use `--fork [uuid]` to branch from a
session without appending to it. `cake debug session` never resumes.

Session files are readable by default but the state roots are **read-only**. If
you run this from inside a cake run, the inner cake cannot write its logs,
telemetry, or the resumed session. Either run the resume outside cake, or add
the missing writes to the outer settings and restart the outer run:

```toml
[sandbox]
writable = ["~/.cache/cake", "~/.local/share/cake"]
```

A fresh `CAKE_DATA_DIR` makes the inner run writable, but it will not contain
the session you want to resume unless you copy it there. See
`debugging-cake-sandbox` §5.

## Worked example: diagnosing a `None` output

User reports: "I ran cake and it just printed `None`."

```bash
$ cake sessions list --json | jq -r '.data.sessions[] | [.session_id, .timestamp, .first_prompt] | @tsv' | head -1
550e8400-e29b-41d4-a716-446655440000  2026-05-21T14:31:58Z  Fix the failing test

$ cake debug session 550e8400-e29b-41d4-a716-446655440000
Session diagnostics
Session: 550e8400-e29b-41d4-a716-446655440000
State: interrupted (diagnosis complete: yes)
Liveness: not held
Last activity: 2026-05-21T14:32:01+00:00 (transcript)

Transcript
  /.../550e8400-e29b-41d4-a716-446655440000.jsonl (ok, 471 B)
    Records: 2  Tasks: 1  Partial tail: no

Telemetry
  /.../550e8400-e29b-41d4-a716-446655440000.ndjson (missing)

Tasks
  550e8400-e29b-41d4-a716-446655440001  interrupted (unknown)
    Start: 2026-05-21T14:32:01+00:00  End: -
    Records: 1  Hook events: 0  Retries: 0  Slow operations: 0
    Invocation: none

Diagnostics
  warning: no telemetry sidecar exists at .../550e8400-e29b-41d4-a716-446655440000.ndjson
  warning: task 550e8400-e29b-41d4-a716-446655440001 has no terminal completion record (state interrupted)
```

**Diagnosis**: the task started and produced no terminal record, and no writer
holds the transcript. The session was interrupted mid-task; the missing
telemetry sidecar is a warning, not the cause. Inspect the last raw record:

```bash
$ tail -1 "$LATEST" | jq '{type, is_error, subtype, error}'
{ "type": "task_start", "is_error": null, "subtype": null, "error": null }
```

**Next step**: `cake sessions list`, then `cake --resume {uuid} "Continue where
you left off"`. If you need to share the evidence, use `--export` instead of the
raw transcript:

```bash
$ cake debug session 550e8400-e29b-41d4-a716-446655440000 --export ./session-diagnostic.json
$ cake debug session 550e8400-e29b-41d4-a716-446655440000 --json |
    jq '.summary | {state, liveness, diagnosis_complete}'
{ "state": "interrupted", "liveness": "not_live", "diagnosis_complete": true }
```

## File locations

| File | Purpose |
| --- | --- |
| `$SESSION_DIR/{uuid}.jsonl` | Session files (format version 4, append-only JSONL) |
| `$TELEMETRY_DIR/{uuid}.ndjson` | Per-session telemetry (timings, retries, tool durations) |
| `$LOG_DIR/cake.YYYY-MM-DD.log` | Daily logs |

Cake grants read-only access to these roots by default, so the Bash tool can read
them without extra grants. The global config directory (`<config>/cake`) and the
user skill root (`~/.agents/skills`) are readable too; `<config>/AGENTS.md` and
`~/.cake/AGENTS.md` are not granted to tools.

## When to switch procedures

- Full session review, quality scoring, or setup/cake improvement
  recommendations -> `analyzing-cake-sessions`.
- `Operation not permitted (os error 1)` or other sandbox denials ->
  `debugging-cake-sandbox`.
