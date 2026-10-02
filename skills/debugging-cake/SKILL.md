---
name: debugging-cake
description: Triage a recent cake CLI failure fast: `None`/empty/truncated output, a bare "Tool error:", a crash, hang, or mid-stream interrupt, or the user says their last run broke. Names what broke; not a full session review. Use `debugging-cake-sandbox` for sandbox denials, `analyzing-cake-sessions` for review.
---

# Debugging Failed Cake Runs

Fast, reactive triage of the user's most recent failed run. Cake reads two
contracts when it reports a result: exit codes and the persisted-session layout.
This skill restates only what triage needs.

## Step 1: Find the failing session

The newest file may be the session running this investigation (a probe launched
from inside cake). Inspect the first user message in the newest few files before
choosing a target; do not let the probe select itself.

`CAKE_DATA_DIR` relocates cache, logs, telemetry, and sessions together; without
it, sessions and cache use separate default locations.

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

ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -3 |
while IFS= read -r candidate; do
  printf '\n%s\n' "$candidate"
  prompt="$(jq -r 'select(.type == "message" and .role == "user") | .content' \
    "$candidate" 2>/dev/null | head -1)"
  printf '%s\n' "${prompt:-"(no user message)"}"
done
```

Set `LATEST` to the matching file. Before classifying it, confirm no cake process
still holds it open:

```bash
LATEST="/absolute/path/to/the-selected-session.jsonl"

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
A live session must not be diagnosed from a partial snapshot. Once no writer
remains, snapshot securely before further analysis:

```bash
umask 077
TARGET_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/cake-session-target.XXXXXX")"
trap 'rm -f "$TARGET_SNAPSHOT"' EXIT
cp "$LATEST" "$TARGET_SNAPSHOT"
LATEST="$TARGET_SNAPSHOT"
echo "$LATEST"
```

Analyze the snapshot through the rest of this skill.

## Step 2: How did the session end?

A complete invocation ends with `task_complete`; anything else means the task did
not finish cleanly.

```bash
tail -1 "$LATEST" | jq '{type, is_error, subtype, error}'
```

| Last record type | Meaning |
| --- | --- |
| `task_complete` (no error) | Task finished normally - the problem is in the result, not the run |
| `task_complete` (`is_error`) | Ended with a recorded error - read `.error` |
| `reasoning` / `function_call` / `function_call_output` / `message` | Interrupted mid-stream (timeout, crash, signal) |
| `task_start` | Task never produced output |

An interrupt (Ctrl-C) does end with `task_complete`: cake writes an interrupted
outcome and exits `130`.

## Step 3: Last few records

```bash
tail -5 "$LATEST" | jq '.'
```

Usually reveals the last tool invoked, the last output seen, or where reasoning
trailed off.

## Step 4: Today's log

```bash
tail -100 "$LOG_DIR"/cake.$(date +%Y-%m-%d).log | grep -iE "error|warn|truncat"
```

Common patterns: `output truncated` (a tool output hit its cap), API errors or
timeouts, a dropped stream, or a panic (cake itself crashed).

## Step 5: Telemetry for retries and timing

```bash
SESSION_ID="$(awk 'NF { print; exit }' "$LATEST" | jq -r '.session_id')"
TELEMETRY="$TELEMETRY_DIR/$SESSION_ID.ndjson"

if [ -f "$TELEMETRY" ]; then
  jq 'select(.type == "retry_scheduled") | {attempt, reason, delay_ms, detail}' "$TELEMETRY"
  jq 'select(.type == "tool_call") | {turn_index, name, duration_ms, output_bytes, was_error}' "$TELEMETRY"
  jq 'select(.type == "session_summary")' "$TELEMETRY"
else
  echo "Telemetry sidecar not found: $TELEMETRY" >&2
fi
```

Telemetry is a separate performance sidecar, not resumable conversation history.

## Step 6: Correlate session and log

```bash
SESSION_ID="$(awk 'NF { print; exit }' "$LATEST" | jq -r '.session_id')"
grep "$SESSION_ID" "$LOG_DIR"/cake.*.log
```

## Why `None` happens

`None` or empty output almost always means **no completed assistant result was
produced** before the session ended. Typical causes: the model hit a token limit
mid-response; the response or stream timed out; the process was interrupted
(signal, panic, crash); or a tool call hung and never returned. The session file
then ends without `task_complete`, or `task_complete` carries `is_error: true`.

## Resuming a session

```bash
cake sessions list
cake --resume {uuid} "Try again"
```

`--resume` takes a UUID, not a file path. Use `--fork [uuid]` to branch from a
session without appending to it.

## Worked example: diagnosing a `None` output

User reports: "I ran cake and it just printed `None`."

```bash
$ SESSION_DIR="${CAKE_DATA_DIR:-$HOME/.local/share/cake}/sessions"
$ LATEST="$(ls -t "$SESSION_DIR"/*.jsonl | head -1)"
$ tail -1 "$LATEST" | jq '{type, is_error, subtype, error}'
{ "type": "reasoning", "is_error": null, "subtype": null, "error": null }
```

Last record is `reasoning`, not `task_complete`, and no writer holds the file:
the task was interrupted mid-stream.

```bash
$ grep -iE "error|timeout|truncat" "$LOG_DIR"/cake.$(date +%Y-%m-%d).log | tail -5
2026-05-21T14:32:18Z ERROR cake::clients::responses: stream error: connection reset by peer
2026-05-21T14:32:18Z WARN  cake::session: task ended without task_complete; session may be incomplete
```

**Diagnosis**: streaming connection dropped during the model's response.
**Next step**: `cake sessions list`, then `cake --resume {uuid} "Continue where
you left off"`.

## File locations

| File | Purpose |
| --- | --- |
| `$SESSION_DIR/{uuid}.jsonl` | Session files (format version 4, append-only JSONL) |
| `$TELEMETRY_DIR/{uuid}.ndjson` | Per-session telemetry (timings, retries, tool durations) |
| `$LOG_DIR/cake.YYYY-MM-DD.log` | Daily logs |

## When to switch procedures

- Full session review, quality scoring, or setup/cake improvement
  recommendations -> `analyzing-cake-sessions`.
- `Operation not permitted (os error 1)` or other sandbox denials ->
  `debugging-cake-sandbox`.
