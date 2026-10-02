# List recipes.
default:
    @just --list

# Validate every skill: frontmatter, name/dir match, 400-char budget, links.
validate:
    ./scripts/validate-skills.sh

# Report cake's rendered skill-catalog size and description warnings (needs `cake`).
catalog:
    @tmp="$(mktemp -d)"; \
    mkdir -p "$tmp/.agents/skills"; \
    for d in skills/*/; do ln -sfn "$PWD/$d" "$tmp/.agents/skills/$(basename "$d")"; done; \
    (cd "$tmp" && cake debug skills); \
    rm -rf "$tmp"

# Copy the skills into ~/.agents/skills (a snapshot; re-run to update).
install:
    mkdir -p "$HOME/.agents/skills"
    cp -R skills/. "$HOME/.agents/skills/"

# Symlink the skills into ~/.agents/skills; skips destinations that are real dirs.
link:
    @mkdir -p "$HOME/.agents/skills"
    @for d in skills/*/; do \
        name="$(basename "$d")"; \
        dest="$HOME/.agents/skills/$name"; \
        if [ -e "$dest" ] && [ ! -L "$dest" ]; then \
            echo "skip: $dest exists and is not a symlink" >&2; \
            continue; \
        fi; \
        ln -sfn "$PWD/$d" "$dest"; \
    done
    @echo "Linked skills into ~/.agents/skills."
