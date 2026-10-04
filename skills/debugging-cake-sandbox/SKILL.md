---
name: debugging-cake-sandbox
description: Diagnose sandbox denials in cake: `Operation not permitted (os error 1)`, `Permission denied`, or sandbox-init errors when a command works outside cake but fails in the Bash tool; cargo/flock/fcntl behaving differently under cake; a nested `cake` process (`cake` launching `cake`) failing at startup; or mentions of Seatbelt, sandbox-exec, Landlock, `--sandbox`, or `CAKE_SANDBOX`.
---

# Debugging Cake Sandbox Denials

Use this when a command works outside cake but fails inside the Bash tool with
`Operation not permitted`, `Permission denied`, `os error 1`, or an explicit
sandbox-initialization error. Cake uses macOS Seatbelt and Linux Landlock
differently, so identify the platform before tracing or changing anything.

This procedure diagnoses **filesystem enforcement**. Cake's sandbox does not
restrict network access, and command-policy rejections happen before the
operating-system sandbox. Sandboxing is default-on and fails closed.

## 1. Establish the failure

Record: the OS, the cake invocation, the working directory, the selected
`--sandbox` policy, any `--add-dir` arguments, configured `directories`, the
failing command, the complete stderr, and the exit status.

Check whether an explicit CLI policy or `CAKE_SANDBOX` changed enforcement:

```bash
printf 'CAKE_SANDBOX=%s\n' "${CAKE_SANDBOX-<unset>}"
```

An explicit `--sandbox` value wins. Without one, `CAKE_SANDBOX=off`, `0`,
`false`, or `no` selects `danger-full-access`; any other value leaves sandboxing
enabled.

Re-run the same command from the same working directory with the same policy and
grants. Set `RUST_LOG=cake=debug` on the cake process when logs are needed; cake
writes them under `~/.cache/cake/` (or `$CAKE_DATA_DIR`).

Classify the result:

- A command that also fails outside cake is **not** a cake sandbox denial.
- A cake message saying the sandbox is unavailable is an **initialization**
  failure, not a missing path grant.
- A command that succeeds with `--sandbox danger-full-access` but fails with the
  original policy is consistent with sandbox enforcement. Use this only as a
  diagnostic comparison, and only with the user's approval when the command
  would gain material authority. It is **not** the repair.

## 2. Branch by platform

### macOS: Seatbelt

Cake generates a deny-default Seatbelt profile, writes it to a temporary `.sb`
file, and runs `/usr/bin/sandbox-exec -f <profile>`. If stderr contains
`sandbox-exec: sandbox_apply`, the command never ran; missing `sandbox-exec`,
malformed profiles, and spawn errors fail closed.

The **nested-Seatbelt fallback** is different: when cake's startup probe reports
`sandbox_apply: Operation not permitted` (cake running inside another Seatbelt
sandbox), cake warns, skips its own child profile, and relies on the inherited
parent sandbox. Diagnose denials against that parent policy; do not weaken
cake's profile to fix them. A **nested `cake` process** hits this fallback too;
§5 covers the separate startup failures it then causes.

To trace a denied operation:

1. Reproduce with `RUST_LOG=cake=debug` and find the log entry beginning
   `Generated sandbox profile:`. Extract the complete profile text that follows
   and write it to `/tmp/cake-debug.sb`. The separately logged temporary path
   usually disappears when the command finishes, so copy it only while the
   command is still running.
2. Add a trace destination while keeping the deny-default first line:

   ```scheme
   (deny default)
   (trace "/tmp/cake-sandbox-trace.log")
   ```

3. Replay the exact failing command:

   ```bash
   /usr/bin/sandbox-exec -f /tmp/cake-debug.sb /bin/bash -c 'your-command-here'
   ```

4. Inspect `/tmp/cake-sandbox-trace.log` for the denied operation and canonical
   path. Watch symlink pairs such as `/tmp` and `/private/tmp`.

Do not turn the debug profile into allow-default or treat a temporary edit as the
fix.

### Linux: Landlock

Cake generates no profile file on Linux. In the child process immediately before
`exec`, it builds a Landlock ABI v5 ruleset, adds path-beneath rules, calls
`restrict_self`, and requires `FullyEnforced`. There is no cake-managed Landlock
denial log comparable to a Seatbelt trace.

Messages beginning `Linux sandbox unavailable` or `Failed to configure`, `create`,
`add`, or `restrict` identify setup/enforcement failures. Cake fails closed when
the kernel does not fully enforce the requested ruleset; confirm kernel and
Landlock support rather than widening paths.

A command that starts and then gets `Permission denied` needs pathname
diagnosis:

1. Reduce the failing command to the smallest read, write, create, rename,
   remove, or execute operation that still fails under the same policy.
2. Inspect the command's own verbose output first; package managers usually name
   the cache, lock, registry, or config path they could not access.
3. If still unclear, run the failing command through `strace -f -e trace=%file`
   **as the cake Bash command** under the same policy. A trace of an
   outside-cake reproduction has no cake rules and cannot reveal their denial.
   Do not look for an `.sb` file or a Landlock profile trace; neither exists.
4. Landlock does not grant a separate file-lock class. An `flock`/`fcntl` error
   is not evidence for a Seatbelt-style `file-lock` rule on Linux; find the path
   and the underlying filesystem operation first.

## 3. Find the denied path, then grant it

Compare the denied path against what the policy already grants:

| Path class | Under `workspace-write` | Under `read-only` |
| --- | --- | --- |
| Working directory | read+write | read |
| `directories` entries | read+write | read |
| `--add-dir` paths | read+execute | read+execute |
| Skill directories | read+execute | read+execute |
| Cake state dirs (data/cache, sessions) | read+execute | read+execute |
| Toolchain caches (Cargo home, Rustup home) | read+write | read |
| Cake temp dirs | read+write | read+write |
| Platform system/config paths | read+execute | read+execute |

Then grant the narrowest authority that unblocks the command:

- **`[sandbox]` in `settings.toml`** — `read_only = ["~/some/dir"]` grants read +
  execute; `writable = ["~/.cache/thing"]` grants read + write + execute. Both
  accept absolute, relative, and `~` paths and merge across global, project, and
  the selected profile. Under `--sandbox read-only`, `writable` entries are
  demoted to read-only.
- **`directories` in `settings.toml`** — persistent read-write access under
  `workspace-write`, shared with the filesystem tools. Demoted under
  `read-only`.
- **`--add-dir <PATH>`** — read-only for one invocation; repeatable.
- **`--sandbox read-only | workspace-write | danger-full-access`** — a policy
  change, not a grant. `danger-full-access` applies no profile at all; it is not
  the repair for a denied standard path.

Two caveats that cause most repeat failures:

- Entries that **do not exist** when the sandbox builds its rules are skipped
  with a warning. On Linux, a rule for a missing path is never applied, so grant
  an existing ancestor rather than a not-yet-created leaf.
- `[sandbox]` and `directories` changes take effect on the **next** cake
  invocation, not the current one.

## 4. If a standard path should already be allowed

If a standard toolchain, cache, or system path is denied under the default
policy, that is a cake gap, not a user error. Do not weaken your sandbox or
patch cake's source to work around it: add the narrowest path from §3 so you can
continue, then report the gap.

Report: the platform, the denied operation and canonical path, the selected
`--sandbox` policy, the configured `directories` and `--add-dir` values, and the
failing command with its full stderr. File it at
<https://github.com/travisennis/cake/issues>. Keep the §3 grant in place until a
cake release fixes the gap, then remove it.

## 5. Running cake inside cake

When a cake run launches another `cake` process through the Bash tool — or any
harness runs cake inside a sandbox that already constrains it — the inner
invocation is governed by the **outer** sandbox, and two independent failures
follow. Check both before assuming the inner prompt or flags are wrong.

**The inner profile is skipped, not stacked (macOS).** Seatbelt cannot apply a
second profile to an already-sandboxed process. The inner cake's startup probe
reports `sandbox_apply: Operation not permitted`, so it warns, runs its own Bash
commands with no inner profile, and relies on the outer one. An inner
`cake --sandbox read-only` therefore narrows nothing; the outer policy is the
real boundary. Do not rely on the inner `--sandbox` value for isolation. On
Linux, Landlock rulesets stack, so the inner ruleset still applies.

**The inner cake cannot initialize its state.** Cake keeps its settings, data,
and sessions under the home directory. The outer `workspace-write` profile
grants read-only access to Cake's data/cache and sessions roots, but nothing to
`~/.config/cake`. That still leaves the inner cake unable to start: it must
write its logs, telemetry, and session file, and read its settings.

| Path | Holds | Inner cake needs | Outer grants |
| --- | --- | --- | --- |
| `~/.config/cake` | settings, hooks, `tools/` | read | none |
| `~/.cache/cake` | data dir: cache, logs, telemetry | read + write | read + execute |
| `~/.local/share/cake/sessions` | session JSONL | read + write | read + execute |

The symptom is a startup failure before any model call. On macOS it surfaces as
a misleading `Error: File exists (os error 17)` where the real cause is a denied
write; do not chase an EEXIST bug. `cake --version` still works because it
touches none of these paths.

Unblock it by giving the inner invocation its own writable state. One
environment variable redirects both the data/log root and the sessions root:

```bash
CAKE_DATA_DIR="$PWD/.cake-data" \
  cake --sandbox workspace-write --output-format json '<prompt>'
```

Or grant the home paths to the outer sandbox in `settings.toml` so the inner run
can use its defaults:

```toml
[sandbox]
read_only = ["~/.config/cake"]
writable = ["~/.cache/cake", "~/.local/share/cake"]
```

These use the `read_only` and `writable` keys from §3. The default profile
already covers the reads of the data and session roots; this snippet adds the
writes the inner run needs plus read access to the config directory. The outer
run needs them because the inner process inherits the outer profile; neither fix
changes the outer policy.

## 6. Common failures

| Symptom | Interpretation |
| --- | --- |
| Write beneath `target/` denied | Confirm working directory and policy; the workspace is writable only under `workspace-write`. |
| Cargo cache or registry access fails | Find the effective `CARGO_HOME`; shared config grants the resolved Cargo/Rustup homes under `workspace-write`. |
| `/tmp` denied on macOS | Compare `/tmp` with canonical `/private/tmp`; both forms must be represented. |
| `flock`/`fcntl` fails on macOS | Trace for a denied `file-lock` or path operation; Seatbelt grants `file-lock` separately. |
| `flock`/`fcntl` fails on Linux | Trace the accessed file and ordinary filesystem op; Landlock has no lock permission. |
| Landlock partially/not enforced | Treat as sandbox unavailability; verify kernel support rather than widening paths. |
| Nested `cake` aborts with `Error: File exists (os error 17)` before any output | The outer sandbox denies the writes the inner run needs to `~/.cache/cake` / `~/.local/share/cake`; set `CAKE_DATA_DIR` or grant them (§5). |
| Inner `--sandbox read-only` has no effect | macOS Seatbelt cannot nest; the inner profile is skipped and the outer policy governs (§5). |

## 7. Verify and report

After changing grants: repeat the original command from the original working
directory with the original policy and grants, and show that an **unrelated**
path is still blocked. Record the platform, denied operation and path, the rule
or grant changed, and any check that could not run.

For a nested invocation, also record the outer policy and whether
`CAKE_DATA_DIR` was overridden.
