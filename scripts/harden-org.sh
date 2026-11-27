#!/usr/bin/env bash
# Enforce organization-wide security and GitHub Actions baselines for Heretek-AI.
# Usage: scripts/harden-org.sh [--dry-run]
set -euo pipefail

org="Heretek-AI"
dry_run=false

if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

echo "=== Heretek-AI Organization Security Hardening (dry_run=$dry_run) ==="

# 1. Resolve Heretek-AI/.github repository ID for ORG_SYNC_TOKEN scoping
dot_github_id="$(gh api "/repos/$org/.github" --jq '.id')"
echo "Resolved $org/.github repo ID: $dot_github_id"

# 2. Check / enforce ORG_SYNC_TOKEN visibility (must be 'selected' -> .github only)
current_vis="$(gh api "/orgs/$org/actions/secrets/ORG_SYNC_TOKEN" --jq '.visibility' 2>/dev/null || echo "missing")"
echo "ORG_SYNC_TOKEN current visibility: $current_vis"
if [ "$current_vis" = "selected" ]; then
  if [ "$dry_run" = true ]; then
    echo "[dry-run] Would ensure ORG_SYNC_TOKEN selected_repository_ids=[$dot_github_id]"
  else
    gh api -X PUT "/orgs/$org/actions/secrets/ORG_SYNC_TOKEN/repositories" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"{\"selected_repository_ids\":[${dot_github_id}]}"
    echo "Scoped ORG_SYNC_TOKEN selected repositories to $org/.github ($dot_github_id)."
  fi
elif [ "$current_vis" = "all" ]; then
  echo "::warning::ORG_SYNC_TOKEN has visibility='all'. GitHub API requires re-uploading the secret value to switch visibility to 'selected'."
  echo "  Action required: Open https://github.com/organizations/$org/settings/secrets/actions/ORG_SYNC_TOKEN"
  echo "  and change Repository access to 'Selected repositories' -> '$org/.github' only."
fi

# 3. Enforce default_workflow_permissions=read & can_approve_pull_request_reviews=false
if [ "$dry_run" = true ]; then
  echo "[dry-run] Would set default_workflow_permissions=read, can_approve_pull_request_reviews=false"
else
  gh api -X PUT "/orgs/$org/actions/permissions/workflow" \
    -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=false
  echo "Updated workflow permissions: read-only GITHUB_TOKEN, PR approval disabled."
fi

# 4. Require full-length commit SHA pinning for GitHub Actions
if [ "$dry_run" = true ]; then
  echo "[dry-run] Would set sha_pinning_required=true on /orgs/$org/actions/permissions"
else
  gh api -X PUT "/orgs/$org/actions/permissions" \
    -f enabled_repositories=all \
    -f allowed_actions=all \
    -F sha_pinning_required=true
  echo "Enabled sha_pinning_required=true."
fi

# 5. Verify resulting org baseline
echo "--- Verification ---"
gh api "/orgs/$org/actions/permissions" --jq '{enabled_repositories, allowed_actions, sha_pinning_required}'
gh api "/orgs/$org/actions/permissions/workflow" --jq '{default_workflow_permissions, can_approve_pull_request_reviews}'
gh api "/orgs/$org/actions/secrets/ORG_SYNC_TOKEN" --jq '{name, visibility}' 2>/dev/null || true
