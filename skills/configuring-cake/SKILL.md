---
name: configuring-cake
description: Configure cake itself for a specialized task by writing a system prompt, settings, profiles, skills, hooks, and toolbox tools. Use when asked to set up, specialize, or "configure yourself" for a task, when a project needs an agent harness in .cake/, or when you need to know which cake file controls a behavior and where it resolves from.
---

# Configuring Cake

Cake is configured by files on disk, not by an API. Everything below is
discovered at **startup** and resolves fresh each invocation. Use this skill to
turn "configure yourself for task X" into concrete files.

## The one rule that changes your plan

Configuration is read when cake starts, so **any change that lands on disk
mid-run applies to the NEXT invocation, not the current one.** You are
configuring your future self. Finish by telling the user the exact command to
re-run (often `cake --resume <UUID> "..."`), or ask them to start a new run.

Two more facts:

- Every knob below is a **preference, not a security boundary**, except the
  sandbox and Bash judge. `--tools`/`--skills` narrow what the model sees; they
  do not protect the host.
- Bottom of the file always wins on conflict; the resolution order per surface
  is listed below.

## Where things live

`<config>` means `$XDG_CONFIG_HOME` or `~/.config`. Project files are relative to
the invocation working directory.

| Surface         | Project                | Global                    |
| --------------- | ---------------------- | ------------------------- |
| System prompt   | `.cake/system.md`      | `<config>/cake/system.md` |
| Settings        | `.cake/settings.toml`  | `<config>/cake/settings.toml` |
| Hooks           | `.cake/hooks.json`, `.cake/hooks.local.json` | `<config>/cake/hooks.json` |
| Toolbox tools   | `.cake/tools/`         | `<config>/cake/tools/`    |
| Skills          | `.agents/skills/`      | `~/.agents/skills/`       |
| Agent context   | `./AGENTS.md`          | `~/.cake/AGENTS.md`, `<config>/AGENTS.md` |

Scaffold a project with `cake init` (writes a fully commented
`.cake/settings.toml`) and `cake init --hooks` (adds an inert
`.cake/hooks.json.example`). Inspect without a model: `cake --help`,
`cake doctor`, `cake debug config`, `cake debug grants`, `cake debug tools`,
`cake debug skills`, `cake debug models`, `cake sessions list`.

## Which diagnostic answers which question

All five reports are read-only. They inspect configuration without starting a
run: they call no model, start no provider, hook, gate, toolbox, or MCP server,
and create no missing directories. `--json` emits one diagnostic document;
warnings exit `0`, and a settings load failure exits `3`.

These reports are newer than older cake builds: `doctor`, `debug config`,
`debug grants`, and `debug tools` are new in 077, and `debug skills` changed its
report shape in 077i. Probe the command lists (`cake --help`, `cake debug
--help`) or fall back to `cake debug models`, `cake --help`, and manual settings
inspection.

| Question | Command |
| --- | --- |
| Are the settings valid, and what grants do they configure? | `cake doctor` |
| What model, profile, trust state, limits, prompt source, and selections will this invocation use? | `cake debug config` |
| What filesystem grants are effective, and which source produced each path? | `cake debug grants` |
| Why is a built-in, toolbox, or MCP tool missing or filtered? | `cake debug tools` |
| Which skills loaded, and is the catalog over budget? | `cake debug skills` |

`cake doctor` reports settings health and the merged configured grant settings
(`directories`, `[sandbox].writable`, `[sandbox].read_only`). It is not the
complete OS-level policy. `cake debug grants` is authoritative for the effective
filesystem grant value and every source behind it. `cake debug config` includes
a grant summary and the broader effective configuration; use it for model,
credential presence, trust, prompt source, limits, tools, skills, hooks, and
toolbox discovery. `cake debug models` remains the configured model list.

Where the command accepts them, pass the same `--sandbox`, `--add-dir`, and
skill/tool selection flags as the invocation you are diagnosing; they describe
a one-run view without changing defaults. Project trust changes the report:
`--trust-project` (or `CAKE_TRUST_PROJECT=1`) accepts the current `.cake/`
snapshot for that invocation, and `--no-project-config` (or
`CAKE_PROJECT_CONFIG=off`) omits it.

```bash
cake doctor
cake debug config --sandbox read-only --add-dir ../shared
cake debug grants --sandbox read-only --add-dir ../shared
cake debug tools --tools Read
cake debug skills --skills review
```

For a permission denial, start with `cake debug grants` and follow
`debugging-cake-sandbox`; for a broken run, follow `debugging-cake`.

## Default filesystem access

These are the defaults of an unmodified cake install under the default
`workspace-write` policy:

- The working directory is writable. Under `--sandbox read-only` it is
  read-only.
- `<config>/cake` is readable by `Read` and Bash but **not writable** by
  `Edit` or `Write`. You can inspect global settings, `system.md`, hooks, MCP
  configuration, trust manifests, and `tools/`; you cannot change them.
- `~/.agents/skills` is readable and writable, even with `--no-skills`. A
  missing root is created on the first writable run. Under `--sandbox
  read-only` it is read-only.
- Cake's state roots (`~/.cache/cake`, `~/.local/share/cake/sessions`, or their
  `CAKE_DATA_DIR` equivalents) are read-only.
- `<config>/AGENTS.md` and `~/.cake/AGENTS.md` are loaded by cake at startup but
  are not granted to tools.

`danger-full-access` removes the Bash OS sandbox, so Bash can write global
files, but the in-process `Edit` and `Write` tools still reject them.

To change global configuration, pick one and tell the user exactly which:

1. **Ask the user to edit the file outside cake**, then re-run. This is the
   default and safest path for a one-off change.
2. **Ask the user to grant the global config directory writable.** Add to the
   global `<config>/cake/settings.toml`, outside cake:

   ```toml
   [sandbox]
   writable = ["<config>/cake"]
   ```

   This lets the model rewrite global settings, hooks, toolbox tools, and trust
   manifests. Recommend it only for repeated global edits and name the risk.
3. **Put the configuration in the project instead.** `.cake/` is writable and
   becomes active after `cake trust`; prefer it when the setting is
   project-specific.

`--add-dir` grants read-only access for one run; it cannot make a global path
writable. To create or edit `<config>/AGENTS.md` or `~/.cake/AGENTS.md`, the
user must do it outside cake, or grant the parent directory (`<config>` or
`~/.cake`) writable, which also exposes unrelated siblings.

A grant covers its configured root, not a symlink target outside it. If
`~/.agents/skills/<name>` is a symlink into a checkout elsewhere, install the
skill as a real directory (copy) or have the user add the target to
`[sandbox].writable`.

## Which file for which job

- **Behavior, tone, role** -> system prompt. It **replaces** the built-in, it is
  not appended.
- **Per-task mode** (model + tools + skills + limits + sandbox grants + prompt,
  bundled under a name) -> a `[profiles.<name>]` and run `cake --profile <name>`.
  This is the closest thing cake has to a named "agent".
- **A repeatable procedure or domain knowledge** -> a skill.
- **Gate, rewrite, or observe tool calls; inject context; report lifecycle** ->
  hooks.
- **A new capability the model can call** -> a toolbox tool.
- **Project facts / standing rules** -> `AGENTS.md` (appended as developer
  context every run).

## System prompt

Resolution order, first readable wins:

1. `--system-prompt <PATH>` (CLI)
2. `.cake/system.md`
3. settings `system_prompt` (project or selected profile)
4. `<config>/cake/system.md`
5. built-in prompt embedded in the binary

An override replaces the built-in entirely, so if you override it, you own the
whole prompt. Some behavior also returns as separate developer messages you do
not control: discovered `AGENTS.md` files, the skills catalog, and an
environment block (cwd, date, platform, shell, terminal). The selected system
prompt is stored at session creation and reused on resume.

## Settings and profiles

Precedence: CLI flags > project profile > global profile > project top-level >
global top-level. Unknown keys are warned on stderr and ignored.

```toml
default_model = "openrouter"
directories = ["../shared"]          # persistent read-write paths
system_prompt = "prompts/coding.md"  # relative to the invocation cwd

[[models]]
name = "openrouter"                  # lowercase letters, numbers, hyphens
model = "openai/gpt-5"               # raw provider model id
base_url = "https://openrouter.ai/api/v1/"
api_key_env = "OPENROUTER_API_KEY"
api_type = "chat_completions"        # or "responses"

[profiles.review]
default_model = "openrouter"
directories = ["../standards"]

[profiles.review.skills]
only = ["review"]

[profiles.review.tools]
enabled = ["Read"]

[profiles.review.limits]
max_turns = 10
```

Profiles may select a model and overlay behavior but may **not** define model
providers. Models are top-level only.

## Skills

A skill is a directory with a `SKILL.md` whose YAML frontmatter has `name` and
`description`. Cake lists the metadata and the model reads the body on demand,
so the `description` is what triggers loading -- make it specific.

Roots: project `.agents/skills/`, configured `skills.path` roots, then user
`~/.agents/skills/`. On a name collision: project wins, then configured roots in
path order, then user.

```toml
[skills]
disabled = false
only = ["review"]
path = "~/my-skills:/shared/team-skills"
```

`--skills a,b` and `--no-skills` override for one run. A run needs `Read` or
`Bash` to load a skill body; a run with neither (e.g. `--no-tools`) gets no
catalog.

## Tool selection

```toml
[tools]
enabled = ["Read", "Edit"]   # absent = all tools; [] = no tools
```

Names are case-sensitive registered names: `Bash`, `BashSession`, `Read`,
`Edit`, `Write`, or a toolbox name `tb__<name>`. Selecting `Bash` also exposes
`BashSession`. The list replaces lower-precedence values (no union). `--tools`
and `--no-tools` override for one run. Unknown names are warned and dropped.

## Bash safety judge and custom rubric

The Bash judge is a default-on, fail-closed gate that evaluates every Bash
command before it runs, above the OS sandbox. Configure it in
`[tools.bash.judge]` in settings; it is not a separate discovery file.

```toml
[tools.bash.judge]
model = "zen"            # optional [[models]] name the judge uses
rubric_file = ".cake/judge-rubric.md"  # optional extra judge guidance
enabled = true           # false, or CAKE_JUDGE=off, disables the judge
allowlist = ["git status"]  # exact raw commands whose block is overridden
# timeout_secs = 30      # bounded judge call; below 1 is raised to 1
# retry_budget_secs = 15 # extra seconds one recovery attempt may use
```

- `rubric_file` points at a user rubric whose text is **appended** to the
  embedded default rubric under a `# User-added rubric guidance` heading. The
  result is the judge's system prompt. Relative paths resolve from the
  invocation working directory, so `.cake/judge-rubric.md` is the project-level
  name; there is no implicit default location.
- Your rubric text is **advisory**: it can add always-block classes or describe
  relaxations, but the judge still answers in the fixed verdict vocabulary, and a
  relaxation is guidance rather than a hard override. `allowlist` is the only
  hard override of a `block`; `enabled = false` and `CAKE_JUDGE=off` are the only
  full bypasses.
- The verdict codes are a closed set -- `git-history-rewrite`,
  `git-worktree-discard`, `git-untracked-delete`, `git-force-push`,
  `git-branch-force-delete`, `git-stash-destructive`, `destructive-rm`,
  `git-commit-backticks`, `rg-replace-footgun`, `credential-disclosure`,
  `data-egress`, `unknown-destructive` -- and only `rg-replace-footgun` is a
  warn-class code. Never write a rubric expecting a new code.
- A good rubric names the project's paths and semantics, separates mutation from
  destruction, scopes any relaxation to explicit, guard-bearing commands, and
  restates the default protections it does not mean to remove. The judge is
  stateless and sees no conversation history, so a relaxation must hold from the
  command text alone.
- Preview a verdict without running anything: `cake bash check -- <command>`.
  Add `--diagnostic` to print the effective prompts, including your appended
  rubric, and confirm the guidance is loaded before relying on it.

## Hooks

Trusted commands. Files append in load order:
`<config>/cake/hooks.json`, `.cake/hooks.json`, `.cake/hooks.local.json`. Each
must declare `"version": 1`.

- Events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PostToolUseFailure`, `Stop`, `ErrorOccurred`, `SessionEnd`.
- Matchers apply only to `SessionStart`, `PreToolUse`, `PostToolUse`,
  `PostToolUseFailure`; `"*"` or omitted matches all, `|` separates exact
  matches.

Each hook gets one JSON object on stdin (`session_id`, `task_id`,
`transcript_path`, `cwd`, `hook_event_name`, `model`, `timestamp`; tool events
add tool identity and input, post-tool adds the result, `SessionEnd` adds
`reason`). Behavior from exit status and stdout:

- `0`, empty stdout -> continue.
- `0`, stdout is a JSON decision -> act on it.
- `2` -> block.
- Any other failure -> logged and ignored unless `fail_closed` applies.

Decision JSON:

```json
{
  "continue": true,
  "permission": "allow",
  "reason": "why",
  "updated_input": {},
  "additional_context": "extra model context"
}
```

`continue: false` stops. `permission` overrides `decision`; `deny`, `block`,
and `ask` all block (cake has no interactive ask flow). `PreToolUse` may rewrite
the tool input once via `updated_input`; cake revalidates it. Any event may add
`additional_context`. Hooks run **outside** the model tool sandbox with your
full host authority, with the project root as cwd.

## Toolbox tools

An executable becomes a model tool by answering `TOOLBOX_ACTION`.

- `TOOLBOX_ACTION=describe` -> print JSON (`args` map, or a draft 2020-12
  `inputSchema`) or text (`name:`, `description:`, `path: string? ...`,
  `replay: safe|never`). Registered as `tb__<name>`; names use letters, numbers,
  `_`, `-`.
- `TOOLBOX_ACTION=execute` -> JSON tools get the raw argument object on stdin;
  text tools get `key=value` lines. Stdout becomes the model-visible result;
  non-zero status is an error.

The process runs in the session working directory with `AGENT=cake` and the
session id in `CAKE_THREAD_ID` / `AGENT_THREAD_ID`. Execute time, stdout, and
stderr are bounded; timeout kills the process group. Discovery order:
`CAKE_TOOLBOX`, repeated `--toolbox`, project `.cake/tools`, then global
`<config>/cake/tools`.

Toolbox executables are **trusted and unsandboxed** and run with your host
authority. Under `--sandbox read-only`, toolbox discovery is skipped entirely.
Cake validates the advertised schema is well-formed but only requires a
top-level object at execute time, so validate your own arguments.

## Sandbox, limits, output

- `--sandbox read-only | workspace-write | danger-full-access` (CLI). Default is
  sandboxing on and fail-closed.
- `[sandbox] read_only = [...]`, `writable = [...]` grant extra paths on top
  of the built-in toolchain, Cake's state directories, the global config
  directory, the user skill root, `--add-dir`, and `directories`. `~` expands.
  These are the manual escape hatch when a default grant is too narrow; see
  "Default filesystem access".
- `[limits]`: `max_turns`, `max_tool_calls` (off by default), plus output
  budgets (`read_default_end_line`, `read_max_output_bytes`,
  `bash_output_max_bytes`, `hook_output_limit`, ...). A value is a positive
  integer or `"unlimited"`.
- `--output-schema` constrains the final answer; `--output-format json` and
  `stream-json` give machine output. Exit codes: `0` success, `1` agent/tool
  error, `2` auth/rate-limit/network, `3` invalid input/config.

## Worked workflow for "configure yourself for task X"

1. **Classify X**: behavior/prompt vs. a bundled mode vs. a capability vs. a
   policy. Most cases are "profile + system prompt".
2. **Read the current state** so you extend instead of clobber: existing
   `.cake/settings.toml`, `.cake/system.md`, `.cake/hooks.json`,
   `.cake/tools/`, `.agents/skills/`, `AGENTS.md`, plus the global
   `<config>/cake/` files and `~/.agents/skills/`. Run `cake init` first if
   there is no `.cake/`.
3. **Write the smallest set of files** that gets X. Project files are
   writable; global files need the user's manual edit or an explicit writable
   grant (see "Default filesystem access"). Prefer a file reference
   (`system_prompt = "..."`) over an unmanaged prompt, and a toolbox tool over
   a hook when the model should *call* the behavior.
4. **Validate cheaply**: `cake doctor` (settings health and configured grants),
   `cake debug config` (effective model, profile, trust, limits, and selections),
   `cake debug tools` and `cake debug skills` (what the model will see), and
   `cake --help` (flags). Unknown keys warn. For a permission denial, compare
   `cake debug grants` with the failing invocation before changing a grant.
5. **Hand off explicitly**: state which files you wrote and the exact re-run
   command. The configuration takes effect on the next invocation, not this one.

## Stop rules

- Do not write config the task does not need. Every hook and toolbox executable
  is trusted code the user must audit; prefer the least powerful artifact.
- Do not put secrets in TOML; use `api_key_env` and environment variables.
- Do not claim a mid-run behavior change. If the current run must behave
  differently, you cannot reconfigure your way there -- say so.
- Do not claim you wrote a global file when the default grants make it
  read-only. State the manual edit or grant the user must apply, and do not
  silently widen the sandbox yourself.
