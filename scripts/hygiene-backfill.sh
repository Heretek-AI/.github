#!/usr/bin/env bash
# Repository lifecycle and hygiene helper (dry-run by default).
#   - Reports or archives Tier 3 archive_candidates (disabling Actions first)
#   - Ensures reference forks keep GitHub Actions disabled
#
# Usage: scripts/hygiene-backfill.sh [--apply-archive] [--apply-forks]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
apply_archive=false
apply_forks=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply-archive)
      apply_archive=true
      shift
      ;;
    --apply-forks)
      apply_forks=true
      shift
      ;;
    *)
      echo "usage: $0 [--apply-archive] [--apply-forks]" >&2
      exit 2
      ;;
  esac
done

org="$(jq -r '.organization' "$manifest")"

echo "=== Reference Forks (actions_enabled=false policy) ==="
while IFS=$'\t' read -r name kind actions_enabled; do
  if [ "$actions_enabled" = "false" ]; then
    current="$(gh api "/repos/$org/$name/actions/permissions" --jq '.enabled' 2>/dev/null || echo "unknown")"
    if [ "$current" = "true" ]; then
      if [ "$apply_forks" = true ]; then
        gh api -X PUT "/repos/$org/$name/actions/permissions" -F enabled=false >/dev/null
        echo "$org/$name ($kind): disabled Actions"
      else
        echo "[dry-run] $org/$name ($kind): Actions currently enabled; would disable"
      fi
    else
      echo "$org/$name ($kind): OK (actions=$current)"
    fi
  fi
done < <(jq -r '.forks[] | [.name, .kind, (.actions_enabled | tostring)] | @tsv' "$manifest")

echo ""
echo "=== Tier 3 Archive Candidates ==="
while IFS=$'\t' read -r name reason; do
  archived="$(gh api "/repos/$org/$name" --jq '.archived' 2>/dev/null || echo "missing")"
  if [ "$archived" = "true" ]; then
    echo "$org/$name: already archived"
    continue
  fi
  if [ "$apply_archive" = true ]; then
    gh api -X PUT "/repos/$org/$name/actions/permissions" -F enabled=false >/dev/null || true
    gh repo archive "$org/$name" --yes
    echo "$org/$name: disabled Actions and archived ($reason)"
  else
    echo "[dry-run] $org/$name: would disable Actions and archive — reason: $reason"
  fi
done < <(jq -r '.archive_candidates[] | [.name, .reason] | @tsv' "$manifest")
