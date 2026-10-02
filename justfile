# Show available recipes.
default:
    @just --list

# Validate every skill: frontmatter, name/dir match, description budget, links.
validate:
    ./scripts/validate-skills.sh

# Print cake's own skill-catalog report for the skills in this repo.
# Requires `cake` on PATH. Shows the rendered catalog size and description-budget
# warnings exactly as cake computes them; `validate` is the fast structural check.
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

# Symlink the skills into ~/.agents/skills so edits apply on the next cake run.
# Skips any destination that already exists as a real directory (never nests a
# link inside a pre-existing install); re-run after removing it if you want links.
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
