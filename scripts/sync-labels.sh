#!/usr/bin/env bash
# Create or update each label in labels.json across one or more repositories.
# Usage: scripts/sync-labels.sh [--update] owner/repo [owner/repo...]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
force_flag=()

if [ "${1:-}" = "--update" ]; then
  force_flag=(--force)
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "usage: $0 [--update] owner/repo [owner/repo...]" >&2
  exit 2
fi

for repo in "$@"; do
  existing="$(gh label list --repo "$repo" --limit 500 --json name --jq '.[].name')"
  while IFS=$'	' read -r name color description; do
    if grep -Fxq -- "$name" <<<"$existing"; then
      if [ "${#force_flag[@]}" -gt 0 ]; then
        gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force >/dev/null
        echo "$repo: $name updated"
      else
        echo "$repo: $name exists"
      fi
    else
      gh label create "$name" --repo "$repo" --color "$color" --description "$description" >/dev/null
      echo "$repo: $name created"
    fi
  done < <(jq -r '.[] | [.name, .color, .description] | @tsv' "$root/labels.json")
done
