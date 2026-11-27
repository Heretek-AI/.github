#!/usr/bin/env bash
# Ensure all Tier 1 (protected_ruleset=true) repositories have active zero-bypass
# default-branch and release-tag rulesets.
#
# Usage: scripts/sync-rulesets.sh [--dry-run] [--repo <name>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
dry_run=false
filter_repo=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --repo)
      filter_repo="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--dry-run] [--repo <name>]" >&2
      exit 2
      ;;
  esac
done

org="$(jq -r '.organization' "$manifest")"
echo "=== Heretek-AI Tier 1 Ruleset Sync (dry_run=$dry_run) ==="

while IFS= read -r repo_name; do
  if [ -n "$filter_repo" ] && [ "$repo_name" != "$filter_repo" ]; then
    continue
  fi

  full_repo="$org/$repo_name"
  rulesets="$(gh api "/repos/$full_repo/rulesets" 2>/dev/null || echo '[]')"

  has_branch="$(jq '[.[] | select(.target == "branch" and .enforcement == "active")] | length' <<<"$rulesets")"
  has_tag="$(jq '[.[] | select(.target == "tag" and .enforcement == "active")] | length' <<<"$rulesets")"

  if [ "$has_branch" -eq 0 ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] $full_repo: would create default-branch ruleset from templates/rulesets/tier1-main.json"
    else
      gh api -X POST "/repos/$full_repo/rulesets" --input "$root/templates/rulesets/tier1-main.json" >/dev/null
      echo "$full_repo: created default-branch ruleset 'keep summer safe'"
    fi
  else
    echo "$full_repo: active default-branch ruleset already present ($has_branch)"
  fi

  if [ "$has_tag" -eq 0 ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] $full_repo: would create release-tags ruleset from templates/rulesets/tier1-tags.json"
    else
      gh api -X POST "/repos/$full_repo/rulesets" --input "$root/templates/rulesets/tier1-tags.json" >/dev/null
      echo "$full_repo: created tag ruleset 'release-tags'"
    fi
  else
    echo "$full_repo: active tag ruleset already present ($has_tag)"
  fi
done < <(jq -r '.repositories[] | select(.protected_ruleset == true) | .name' "$manifest")
