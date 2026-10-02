# Contributing

This repo holds the user-facing skills for cake. Each skill is a directory under
`skills/` containing a `SKILL.md`:

```text
skills/<name>/
├── SKILL.md                 # YAML frontmatter + markdown body
└── reference/...            # optional bundled assets, linked from SKILL.md
```

## Authoring rules

- **Frontmatter must have `name` and `description`.** `name` must equal the
  directory name; cake keys skills by that name and users filter on it.
- **Keep the description under 400 characters.** It is what cake renders into the
  system prompt for skill routing; cake reports a per-description advisory of 400
  and a catalog advisory of 4000 rendered characters (`just catalog`).
- **Write the description as a trigger.** "Use when …" clauses, symptom phrases,
  and sibling-skill routing (`Use <other-skill> for …`) are what make a skill fire
  on the right task.
- **Stay self-contained.** No links outside the skill directory — no
  `../../../docs/...`. Bundle anything a skill needs under its `reference/`, and
  link to it with a path that resolves from the skill directory.
- **Write for users, not cake contributors.** Recommend settings, `--add-dir`,
  profiles, prompts, `AGENTS.md`, and skills. Do not tell users to edit cake's
  source; if a behavior is a cake bug, say how to report it.
- **One skill, one job.** Split rather than growing a description until it
  matches everything.

These skills are a derived, adapted artifact of cake's contributor runbooks. When
cake changes a surface a skill reads, update the skill here — do not author a
second copy inside the cake repository.

## Validate

```sh
just validate     # frontmatter, name/dir match, 400-char budget, link resolution
just catalog      # cake's own rendered-catalog report (needs `cake` on PATH)
```

`just validate` is the gate. The GitHub workflow runs it on every push and pull
request; keep it green.

## Test install

```sh
just link         # symlink skills/ into ~/.agents/skills
cake debug skills # confirm discovery and check for diagnostics
```

## Commits

Conventional Commits, scoped to the skill when one is involved, for example
`docs(debugging-cake): ...` or `feat(configuring-cake): ...`. Keep a change to one
skill in one commit where you can.
