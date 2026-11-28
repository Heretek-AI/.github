#!/usr/bin/env bash
# Enforce per-repository security and hygiene settings across active managed
# repositories in Heretek-AI:
#   - Private Vulnerability Reporting (public repos)
#   - Dependabot security updates (public repos)
#   - Immutable Releases (Tier 1 repos + .github)
#   - Clean merge & sign-off defaults (delete_branch_on_merge, allow_update_branch, web_commit_signoff_required)
#
# Secret scanning and CodeQL defaults are owned by the organization code
# security configuration created by scripts/harden-org.sh, not by this script.
#
# Usage: scripts/sync-repo-settings.sh [--dry-run] [--repo <name>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
org="$(jq -r '.organization' "$manifest")"
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

echo "=== $org Repository Security & Hygiene Sync (dry_run=$dry_run) ==="

sync_repo() {
  local repo_name="$1"
  local is_tier1="$2"
  local full_repo="$org/$repo_name"

  if [ -n "$filter_repo" ] && [ "$repo_name" != "$filter_repo" ]; then
    return 0
  fi

  local meta
  meta="$(gh api "/repos/$full_repo" 2>/dev/null || true)"
  if [ -z "$meta" ]; then
    echo "::warning::$full_repo inaccessible; skipping."
    return 0
  fi

  local archived is_private
  archived="$(jq -r '.archived' <<<"$meta")"
  is_private="$(jq -r '.private' <<<"$meta")"
  if [ "$archived" = "true" ]; then
    echo "$full_repo: archived; skipping."
    return 0
  fi

  # 1. Core merge & sign-off defaults
  local patch_payload
  # web_commit_signoff_required is enforced at the organization level; sending
  # it here returns 422 because the repository value is read-only.
  patch_payload="$(jq -nc '{
    delete_branch_on_merge: true,
    allow_update_branch: true
  }')"

  if [ "$dry_run" = true ]; then
    echo "[dry-run] $full_repo (private=$is_private, tier1=$is_tier1): would PATCH hygiene defaults"
  else
    gh api -X PATCH "/repos/$full_repo" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"$patch_payload" >/dev/null
    echo "$full_repo: updated hygiene defaults"
  fi

  # 2. Dependabot security updates (public repos only; not writable via PATCH /repos)
  if [ "$is_private" = "false" ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] $full_repo: would enable Dependabot security updates"
    else
      if gh api -X PUT "/repos/$full_repo/automated-security-fixes" \
        -H "Accept: application/vnd.github+json" >/dev/null 2>&1; then
        echo "$full_repo: enabled Dependabot security updates"
      else
        echo "::notice::$full_repo: could not enable Dependabot security updates via API"
      fi
    fi
  fi

  # 3. Private Vulnerability Reporting (public repos only)
  if [ "$is_private" = "false" ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] $full_repo: would enable private vulnerability reporting"
    else
      gh api -X PUT "/repos/$full_repo/private-vulnerability-reporting" \
        -H "Accept: application/vnd.github+json" >/dev/null
      echo "$full_repo: enabled private vulnerability reporting"
    fi
  fi

  # 4. Immutable Releases (Tier 1 repos + .github)
  if [ "$is_tier1" = "true" ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] $full_repo: would enable immutable releases"
    else
      if gh api -X PUT "/repos/$full_repo/immutable-releases" \
        -H "Accept: application/vnd.github+json" >/dev/null 2>&1; then
        echo "$full_repo: enabled immutable releases"
      else
        echo "::notice::$full_repo: immutable releases endpoint not enabled via API"
      fi
    fi
  fi
}

sync_repo ".github" "true"

while IFS=$'\t' read -r name tier; do
  is_t1="false"
  [ "$tier" = "1" ] && is_t1="true"
  sync_repo "$name" "$is_t1"
done < <(jq -r '.repositories[] | [.name, (.tier | tostring)] | @tsv' "$manifest")
