#!/usr/bin/env bash
# Validate the skills in this repo against cake's load-time contract and this
# repo's authoring rules. Exits non-zero on any failure. Run via `just validate`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_dir="$repo_root/skills"
description_budget="${DESCRIPTION_BUDGET:-400}"

failures=0
fail() {
    printf 'error: %s\n' "$*" >&2
    failures=$((failures + 1))
}

shopt -s nullglob
skill_files=("$skills_dir"/*/SKILL.md)
if [ "${#skill_files[@]}" -eq 0 ]; then
    fail "no skills found under $skills_dir"
fi

# Print the YAML frontmatter body (between the first two `---` lines).
frontmatter() {
    awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2) exit; next} n==1{print}' "$1"
}

# Print the value of a scalar frontmatter key.
field() {
    printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n1
}

# Fail on any relative markdown link whose target does not resolve.
check_links() {
    local file="$1" display dir target path
    display="${file#"$repo_root"/}"
    dir="$(dirname "$file")"
    while IFS= read -r target; do
        case "$target" in
            '' | \#* | http://* | https://* | mailto:* | ftp://*) continue ;;
        esac
        path="${target%%#*}"
        path="${path%% *}"
        [ -z "$path" ] && continue
        case "$path" in
            /*) [ -e "$path" ] || fail "$display: absolute link does not exist: $target" ;;
            *) [ -e "$dir/$path" ] || fail "$display: broken relative link: $target" ;;
        esac
    done < <(grep -oE '\]\([^)]*\)' "$file" 2>/dev/null | sed -e 's/^](//' -e 's/)$//')
}

for skill_md in "${skill_files[@]}"; do
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    rel="${skill_md#"$repo_root"/}"
    failures_before="$failures"

    if [ "$(grep -c '^---[[:space:]]*$' "$skill_md")" -lt 2 ]; then
        fail "$rel: frontmatter must be delimited by two '---' lines"
        continue
    fi

    fm="$(frontmatter "$skill_md")"
    name="$(field "$fm" name)"
    description="$(field "$fm" description)"
    [ -n "$name" ] || fail "$rel: frontmatter is missing 'name'"
    [ -n "$description" ] || fail "$rel: frontmatter is missing 'description'"

    if [ -n "$name" ] && [ "$name" != "$skill_name" ]; then
        fail "$rel: frontmatter name '$name' must match directory '$skill_name'"
    fi

    if [ -n "$description" ]; then
        len="${#description}"
        if [ "$len" -gt "$description_budget" ]; then
            fail "$rel: description is $len characters (budget $description_budget)"
        fi
    fi

    check_links "$skill_md"
    for ref in "$skill_dir"/reference/*.md; do
        check_links "$ref"
    done

    if [ "$failures" -eq "$failures_before" ]; then
        printf 'ok: %s\n' "$rel"
    fi
done

if [ "$failures" -gt 0 ]; then
    printf '\n%d problem(s) found.\n' "$failures" >&2
    exit 1
fi
printf '\nAll skills valid.\n'
