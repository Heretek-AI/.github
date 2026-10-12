#!/usr/bin/env bash
# Create each label in labels.json that a repository lacks.
# Existing labels keep their color and description; nothing is deleted.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 owner/repo [owner/repo...]" >&2
  exit 2
fi

for repo in "$@"; do
  existing="$(gh label list --repo "$repo" --limit 500 --json name --jq '.[].name')"
  while IFS=$'\t' read -r name color description; do
    if grep -Fxq -- "$name" <<<"$existing"; then
      echo "$repo: $name exists"
    else
      gh label create "$name" --repo "$repo" --color "$color" --description "$description" >/dev/null
      echo "$repo: $name created"
    fi
  done < <(jq -r '.[] | [.name, .color, .description] | @tsv' "$root/labels.json")
done
