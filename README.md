# cake-skills

User-facing [skills](https://github.com/travisennis/cake) for `cake`, the
sandboxed AI coding assistant CLI. Each skill is a `SKILL.md` bundle that cake
discovers at startup and loads when its description matches the task.

These are the skills a cake **user** installs. They are self-contained: each one
works when copied to `~/.agents/skills/`, with no access to cake's source tree or
its contributor runbooks. Cake resolves them fresh on every invocation.

## Skills

| Skill | Use it when |
| --- | --- |
| [`debugging-cake-sandbox`](skills/debugging-cake-sandbox/SKILL.md) | A command fails only inside cake's sandbox: `Operation not permitted (os error 1)`, `Permission denied`, or a sandbox-init error; mentions of Seatbelt, `sandbox-exec`, Landlock, `--sandbox`, or `CAKE_SANDBOX`. |
| [`debugging-cake`](skills/debugging-cake/SKILL.md) | A run just broke: empty or truncated output, a bare `Tool error:`, a crash, a hang, or a mid-stream interrupt. |
| [`analyzing-cake-sessions`](skills/analyzing-cake-sessions/SKILL.md) | Retrospective review of a persisted session, quality scoring, or setup-improvement recommendations. |
| [`configuring-cake`](skills/configuring-cake/SKILL.md) | Set up or specialize cake: system prompt, settings, profiles, skills, hooks, and toolbox tools. |

## Install

Copy the skills into your user-level skills directory:

```sh
git clone https://github.com/travisennis/cake-skills.git ~/Projects/cake-skills
mkdir -p ~/.agents/skills
cp -R ~/Projects/cake-skills/skills/. ~/.agents/skills/
```

Or link them so edits apply on the next cake run (cake follows symlinked skill
directories):

```sh
cd ~/Projects/cake-skills && just link
```

Both are wrapped as `just install` (copy) and `just link` (symlink). Verify with
`cake debug skills`, which lists the discovered skills and any diagnostics.

Project skills in a repo's `.agents/skills/` take precedence over these user
skills when names collide. Point cake at a skills root instead of installing by
setting `skills.paths` in `settings.toml`, or pass `--no-skills`/`--skills` to
narrow what a run sees.

## Compatibility

These skills read cake's user-facing surfaces — session JSONL records, exit
codes, `CAKE_DATA_DIR`, log and telemetry paths, sandbox settings. Cake versions
those surfaces deliberately; a skill that depends on a newer shape should say so
in its body. Install a snapshot from this repo that matches the cake release you
run, and re-install after upgrading cake when a skill reports a behavior you do
not see.

## Develop

Authoring rules and the validation gate live in [CONTRIBUTING.md](CONTRIBUTING.md).
Agents editing this repo should read [AGENTS.md](AGENTS.md). Run `just validate`
before committing.

## License

MIT — see [LICENSE](LICENSE).
