# Agent Instructions

## Project

`cake-skills` holds user-facing skills for `cake`, the sandboxed AI coding
assistant CLI. Each skill is `skills/<name>/SKILL.md`: YAML frontmatter (`name`,
`description`) plus a markdown body cake loads when the description matches the
task. These skills ship outside the cake repository and must work in a user's
`~/.agents/skills/` with no access to cake's source tree.

Compatibility surface: the `SKILL.md` frontmatter contract (cake parses `name`
and `description`, ignores no other keys) and each skill's description text,
which is what cake renders into the system prompt for routing.

## Editing a skill

- Keep `name` equal to the directory name and the description under 400
  characters; cake renders descriptions into the system prompt and flags longer
  ones.
- Keep a skill self-contained. Bundle assets under the skill's `reference/` and
  link them with paths that resolve from the skill directory. No links into the
  cake repository.
- Write for cake **users**: settings, `--add-dir`, profiles, prompts,
  `AGENTS.md`, skills, hooks, toolbox tools. Do not send users to edit cake's
  source. When a behavior is a cake bug, say how to report it.
- Preserve the "Use when …" trigger phrasing and sibling-skill routing in
  descriptions; that text decides whether a skill fires.

These skills are a derived, adapted artifact of cake's contributor runbooks. If
cake changes a surface a skill reads (session JSONL, exit codes, `CAKE_DATA_DIR`,
sandbox settings), update the skill here rather than a second copy in cake.

## Verify

- `just validate` (`scripts/validate-skills.sh`): frontmatter, name/dir
  match, the 400-character description budget, and relative-link resolution.
- `just catalog` (needs `cake` on PATH): cake's own rendered-catalog size and
  warning report.
- `just link` then `cake debug skills`: confirm discovery from `~/.agents/skills`.

Run `just validate` before every commit.

## Repo facts

- Default branch is `master`; commit messages are Conventional Commits scoped to
  the skill (`docs(debugging-cake): ...`).
- `just validate` is the gate the CI workflow runs; keep it green.
