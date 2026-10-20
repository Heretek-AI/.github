#!/usr/bin/env bash
# Validate SKILL.md files against the Agent Skills Open Specification (agentskills.io)
# and OpenCode v2 skill constraints.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_dir="${1:-$root/skills}"

if [ ! -d "$skills_dir" ]; then
  echo "No skills directory at $skills_dir; skipping."
  exit 0
fi

status=0
found=0

for skill_md in "$skills_dir"/*/SKILL.md; do
  [ -e "$skill_md" ] || continue
  found=$((found + 1))
  dir_name="$(basename "$(dirname "$skill_md")")"

  # 1. Line budget (< 500 lines)
  lines="$(wc -l <"$skill_md" | tr -d '[:space:]')"
  if [ "$lines" -ge 500 ]; then
    echo "::error file=$skill_md::SKILL.md has $lines lines (must be < 500 lines)"
    status=1
  fi

  # 2. Extract YAML frontmatter between first two '---' lines
  if [ "$(head -n 1 "$skill_md")" != "---" ]; then
    echo "::error file=$skill_md::Missing opening YAML frontmatter delimiter (---)"
    status=1
    continue
  fi

  frontmatter="$(awk 'NR==1 && $0=="---" {in_fm=1; next} in_fm && $0=="---" {exit} in_fm {print}' "$skill_md")"
  name_val="$(printf '%s
' "$frontmatter" | sed -n 's/^name:[[:space:]]*//p' | tr -d '"' | tr -d "'")"
  desc_val="$(printf '%s
' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p')"

  # 3. Validate name matches directory and spec regex ^[a-z0-9]+(-[a-z0-9]+)*$ (1-64 chars)
  if [ -z "$name_val" ]; then
    echo "::error file=$skill_md::Missing required 'name' field in frontmatter"
    status=1
  elif [ "$name_val" != "$dir_name" ]; then
    echo "::error file=$skill_md::Frontmatter name '$name_val' does not match directory '$dir_name'"
    status=1
  elif ! printf '%s' "$name_val" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || [ "${#name_val}" -gt 64 ]; then
    echo "::error file=$skill_md::Invalid skill name '$name_val' (must be 1-64 lowercase alphanumeric/hyphen chars)"
    status=1
  fi

  # 4. Validate description (1-1024 chars)
  if [ -z "$desc_val" ]; then
    echo "::error file=$skill_md::Missing required 'description' field in frontmatter"
    status=1
  elif [ "${#desc_val}" -gt 1024 ]; then
    echo "::error file=$skill_md::Description exceeds 1024 characters (${#desc_val})"
    status=1
  fi
done

echo "Validated $found skill(s) in $skills_dir."
exit "$status"
