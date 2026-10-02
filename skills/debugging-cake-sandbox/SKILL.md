---
name: debugging-cake-sandbox
description: Diagnose sandbox denials in cake: `Operation not permitted (os error 1)`, `Permission denied`, or sandbox-init errors when a command works outside cake but fails in the Bash tool; cargo/flock/fcntl behaving differently under cake; or mentions of Seatbelt, sandbox-exec, Landlock, `--sandbox`, or `CAKE_SANDBOX`.
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
cake's profile to fix them.

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

## 5. Common failures

| Symptom | Interpretation |
| --- | --- |
| Write beneath `target/` denied | Confirm working directory and policy; the workspace is writable only under `workspace-write`. |
| Cargo cache or registry access fails | Find the effective `CARGO_HOME`; shared config grants the resolved Cargo/Rustup homes under `workspace-write`. |
| `/tmp` denied on macOS | Compare `/tmp` with canonical `/private/tmp`; both forms must be represented. |
| `flock`/`fcntl` fails on macOS | Trace for a denied `file-lock` or path operation; Seatbelt grants `file-lock` separately. |
| `flock`/`fcntl` fails on Linux | Trace the accessed file and ordinary filesystem op; Landlock has no lock permission. |
| Landlock partially/not enforced | Treat as sandbox unavailability; verify kernel support rather than widening paths. |

## 6. Verify and report

After changing grants: repeat the original command from the original working
directory with the original policy and grants, and show that an **unrelated**
path is still blocked. Record the platform, denied operation and path, the rule
or grant changed, and any check that could not run.
