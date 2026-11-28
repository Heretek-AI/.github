#!/usr/bin/env bash
# Enforce organization-wide security, GitHub Actions, OIDC, fleet code security
# configuration, runner-scoping, and secret-scoping baselines for Heretek-AI.
#
# Usage: scripts/harden-org.sh [--dry-run] [--prune]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
allowlist="$root/org-actions-allowlist.json"
org="$(jq -r '.organization' "$manifest")"
dry_run=false
prune=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --prune)
      prune=true
      shift
      ;;
    *)
      echo "usage: $0 [--dry-run] [--prune]" >&2
      exit 2
      ;;
  esac
done

echo "=== $org Organization Security Hardening (dry_run=$dry_run, prune=$prune) ==="

# Helper: resolve numeric repo ID for a repo name
resolve_repo_id() {
  gh api "/repos/$org/$1" --jq '.id' 2>/dev/null || true
}

# 1. Organization general & security baseline (PATCH /orgs/$org). Split into a
#    core policy call and a new-repository defaults call so a plan restriction
#    on the latter cannot abort the whole run.
echo "--- 1. Organization general & security baseline ---"
core_payload="$(jq -nc '{
  default_repository_permission: "read",
  members_can_create_repositories: false,
  members_can_create_public_repositories: false,
  members_can_create_private_repositories: false,
  members_can_fork_private_repositories: false,
  web_commit_signoff_required: true,
  deploy_keys_enabled_for_repositories: false
}')"
new_repo_payload="$(jq -nc '{
  secret_scanning_enabled_for_new_repositories: true,
  secret_scanning_push_protection_enabled_for_new_repositories: true,
  dependabot_alerts_enabled_for_new_repositories: true,
  dependabot_security_updates_enabled_for_new_repositories: true,
  dependency_graph_enabled_for_new_repositories: true
}')"

if [ "$dry_run" = true ]; then
  echo "[dry-run] Would PATCH /orgs/$org core baseline: $(jq -c . <<<"$core_payload")"
  echo "[dry-run] Would PATCH /orgs/$org new-repository security defaults: $(jq -c . <<<"$new_repo_payload")"
else
  gh api -X PATCH "/orgs/$org" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$core_payload" >/dev/null
  echo "Updated /orgs/$org core baseline."

  new_repo_err=""
  if new_repo_err="$(gh api -X PATCH "/orgs/$org" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$new_repo_payload" 2>&1 >/dev/null)"; then
    echo "Updated /orgs/$org new-repository security defaults."
  else
    echo "::warning::Could not update new-repository security defaults on /orgs/$org (plan restriction); continuing. $new_repo_err"
  fi
fi

# 2. Enforce Actions permissions: allowed_actions=selected + sha_pinning_required=true
echo "--- 2. GitHub Actions permissions & allowlist ---"
allowlist_payload="$(jq -c '{github_owned_allowed, verified_allowed, patterns_allowed}' "$allowlist")"
if [ "$dry_run" = true ]; then
  echo "[dry-run] Would set enabled_repositories=all, allowed_actions=selected, sha_pinning_required=true"
  echo "[dry-run] Would apply $(jq '.patterns_allowed | length' "$allowlist") patterns from org-actions-allowlist.json"
else
  gh api -X PUT "/orgs/$org/actions/permissions" \
    -f enabled_repositories=all \
    -f allowed_actions=selected \
    -F sha_pinning_required=true
  gh api -X PUT "/orgs/$org/actions/permissions/selected-actions" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$allowlist_payload"
  echo "Enabled allowed_actions=selected, sha_pinning_required=true, and synced org-actions-allowlist.json."
fi

# 3. Enforce read-only GITHUB_TOKEN, no PR approval, all_external_contributors
#    fork approval, and approval for private-repo fork pull requests.
echo "--- 3. Workflow permissions & fork-PR approval ---"
fork_private_payload="$(jq -nc '{
  run_workflows_from_fork_pull_requests: false,
  send_write_tokens_to_workflows: false,
  send_secrets_and_variables: false,
  require_approval_for_fork_pr_workflows: true
}')"
if [ "$dry_run" = true ]; then
  echo "[dry-run] Would set default_workflow_permissions=read, can_approve_pull_request_reviews=false"
  echo "[dry-run] Would set fork-pr-contributor-approval policy=all_external_contributors"
  echo "[dry-run] Would PUT /orgs/$org/actions/permissions/fork-pr-workflows-private-repos (require_approval_for_fork_pr_workflows=true)"
else
  gh api -X PUT "/orgs/$org/actions/permissions/workflow" \
    -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=false
  gh api -X PUT "/orgs/$org/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors
  gh api -X PUT "/orgs/$org/actions/permissions/fork-pr-workflows-private-repos" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$fork_private_payload" >/dev/null
  fork_private_after="$(gh api "/orgs/$org/actions/permissions/fork-pr-workflows-private-repos" --jq '.require_approval_for_fork_pr_workflows' 2>/dev/null || echo unknown)"
  if [ "$fork_private_after" = "true" ]; then
    echo "Updated workflow permissions (read-only, no PR approval), fork-PR approval (all_external_contributors), and private-fork workflow approval."
  else
    echo "::warning::Private-fork workflow approval did not take effect via API (Free-plan/read-only); set it in Org Settings -> Actions -> General."
  fi
fi

# 4. Enforce Actions OIDC custom subject claim template
echo "--- 4. Actions OIDC custom subject claim ---"
oidc_payload='{"include_claim_keys":["repo","context","job_workflow_ref"]}'
if [ "$dry_run" = true ]; then
  echo "[dry-run] Would PUT /orgs/$org/actions/oidc/customization/sub with $oidc_payload"
else
  gh api -X PUT "/orgs/$org/actions/oidc/customization/sub" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$oidc_payload"
  echo "Configured OIDC custom sub claim template: repo, context, job_workflow_ref."
fi

# 5. Fleet code security configuration. Deliberately does not touch the legacy
#    organization configuration (ID 250992), which has CodeQL default setup
#    enabled and conflicts with repositories running advanced CodeQL.
echo "--- 5. Fleet code security configuration ---"
ensure_fleet_code_security_config() {
  local cfg_name="Heretek-AI fleet baseline"
  local cfg_description="Baseline for active Heretek-AI repositories (no CodeQL default setup)"
  local cfg_payload
  cfg_payload="$(jq -nc --arg name "$cfg_name" --arg description "$cfg_description" '{
    name: $name,
    description: $description,
    advanced_security: "enabled",
    dependency_graph: "enabled",
    dependabot_alerts: "enabled",
    dependabot_security_updates: "enabled",
    code_scanning_default_setup: "not_set",
    secret_scanning: "enabled",
    secret_scanning_push_protection: "enabled",
    secret_scanning_non_provider_patterns: "enabled",
    secret_scanning_validity_checks: "enabled",
    secret_scanning_extended_metadata: "enabled",
    private_vulnerability_reporting: "enabled",
    enforcement: "unenforced"
  }')"

  local configs cfg_id
  if ! configs="$(gh api "/orgs/$org/code-security/configurations" 2>/dev/null)"; then
    echo "::notice::Could not list code security configurations for $org (plan restriction); skipping fleet baseline."
    return 0
  fi
  cfg_id="$(jq -r --arg name "$cfg_name" \
    '[.[] | select(.target_type == "organization" and .name == $name)][0].id // empty' <<<"$configs")"

  # Attach active public managed repositories plus the .github control plane.
  local attach_ids=()
  local name meta rid private archived fork
  while IFS= read -r name; do
    meta="$(gh api "/repos/$org/$name" --jq '[.id, .private, .archived, .fork] | @tsv' 2>/dev/null || true)"
    if [ -z "$meta" ]; then
      echo "::warning::$org/$name: could not resolve repository metadata; skipping code security attachment."
      continue
    fi
    IFS=$'\t' read -r rid private archived fork <<<"$meta"
    if [ "$private" = "false" ] && [ "$archived" = "false" ] && [ "$fork" = "false" ]; then
      attach_ids+=("$rid")
    fi
  done < <(
    printf '%s\n' ".github"
    jq -r '.repositories[].name' "$manifest"
  )

  local attach_ids_json
  if [ "${#attach_ids[@]}" -gt 0 ]; then
    attach_ids_json="$(printf '%s\n' "${attach_ids[@]}" | jq -s 'unique')"
  else
    attach_ids_json='[]'
  fi

  if [ "$dry_run" = true ]; then
    if [ -n "$cfg_id" ]; then
      echo "[dry-run] Would PATCH code security configuration '$cfg_name' (ID $cfg_id)"
    else
      echo "[dry-run] Would create code security configuration '$cfg_name' (ID pending)"
    fi
    echo "[dry-run] Would attach it to ${#attach_ids[@]} public repositories: $attach_ids_json"
    return 0
  fi

  local err created
  if [ -n "$cfg_id" ]; then
    if ! err="$(gh api -X PATCH "/orgs/$org/code-security/configurations/$cfg_id" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"$cfg_payload" 2>&1 >/dev/null)"; then
      echo "::notice::Could not update code security configuration '$cfg_name' (ID $cfg_id): $err"
      return 0
    fi
    echo "Updated code security configuration '$cfg_name' (ID $cfg_id)."
  else
    if ! created="$(gh api -X POST "/orgs/$org/code-security/configurations" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"$cfg_payload" 2>/dev/null)"; then
      echo "::notice::Could not create code security configuration '$cfg_name' (plan restriction)."
      return 0
    fi
    cfg_id="$(jq -r '.id // empty' <<<"$created")"
    if [ -z "$cfg_id" ]; then
      echo "::notice::Created code security configuration '$cfg_name' but the response had no id; skipping attachment."
      return 0
    fi
    echo "Created code security configuration '$cfg_name' (ID $cfg_id)."
  fi

  if [ "${#attach_ids[@]}" -eq 0 ]; then
    echo "::notice::No public managed repositories resolved; skipping code security attachment."
    return 0
  fi

  if ! err="$(gh api -X POST "/orgs/$org/code-security/configurations/$cfg_id/attach" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"{\"scope\":\"selected\",\"selected_repository_ids\":${attach_ids_json}}" 2>&1 >/dev/null)"; then
    echo "::notice::Could not attach code security configuration $cfg_id: $err"
    return 0
  fi
  echo "Attached code security configuration $cfg_id to ${#attach_ids[@]} public repositories."
}

ensure_fleet_code_security_config

# 6. Secret scoping (ORG_SYNC_TOKEN -> .github only; fleet LLM/runner secrets -> managed repos + .github)
echo "--- 6. Organization secret scoping ---"
dot_github_id="$(resolve_repo_id ".github")"
if [ -n "$dot_github_id" ]; then
  echo "Resolved $org/.github repo ID: $dot_github_id"
else
  echo "::warning::Could not resolve $org/.github repo ID."
fi

sync_vis="$(gh api "/orgs/$org/actions/secrets/ORG_SYNC_TOKEN" --jq '.visibility' 2>/dev/null || echo "missing")"
echo "ORG_SYNC_TOKEN visibility: $sync_vis"
if [ "$sync_vis" = "selected" ]; then
  if [ -z "$dot_github_id" ]; then
    echo "::notice::ORG_SYNC_TOKEN is scoped to selected repositories but $org/.github has no resolved ID; skipping."
  elif [ "$dry_run" = true ]; then
    echo "[dry-run] Would ensure ORG_SYNC_TOKEN selected_repository_ids=[$dot_github_id]"
  else
    gh api -X PUT "/orgs/$org/actions/secrets/ORG_SYNC_TOKEN/repositories" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"{\"selected_repository_ids\":[${dot_github_id}]}"
    echo "Scoped ORG_SYNC_TOKEN to $org/.github ($dot_github_id)."
  fi
elif [ "$sync_vis" = "all" ]; then
  echo "::warning::ORG_SYNC_TOKEN has visibility='all'. Change it to 'Selected repositories' -> '$org/.github' in Org Settings."
fi

# Build list of active managed repo IDs (+ .github) for fleet-scoped secrets
fleet_ids=()
if [ -n "$dot_github_id" ]; then
  fleet_ids+=("$dot_github_id")
fi
while IFS= read -r rname; do
  rid="$(resolve_repo_id "$rname")"
  if [ -n "$rid" ]; then
    fleet_ids+=("$rid")
  fi
done < <(jq -r '.repositories[] | select(.actions_enabled == true) | .name' "$manifest")

if [ "${#fleet_ids[@]}" -gt 0 ]; then
  fleet_ids_json="$(printf '%s\n' "${fleet_ids[@]}" | jq -s '.')"
else
  fleet_ids_json='[]'
fi

for sec_name in LLM_API_KEY OCR_LLM_TOKEN OPENROUTER_API_KEY OPENCODE_GO_API_KEY RUNNER_PROBE_TOKEN; do
  vis="$(gh api "/orgs/$org/actions/secrets/$sec_name" --jq '.visibility' 2>/dev/null || echo "missing")"
  if [ "$vis" = "selected" ]; then
    if [ "${#fleet_ids[@]}" -eq 0 ]; then
      echo "::notice::$sec_name is scoped to selected repositories but no fleet repository IDs resolved; skipping."
    elif [ "$dry_run" = true ]; then
      echo "[dry-run] Would sync $sec_name selected_repository_ids to ${#fleet_ids[@]} active managed repos"
    else
      gh api -X PUT "/orgs/$org/actions/secrets/$sec_name/repositories" \
        -H "Accept: application/vnd.github+json" \
        --input - <<<"{\"selected_repository_ids\":${fleet_ids_json}}"
      echo "Scoped $sec_name to ${#fleet_ids[@]} active managed repos (+ .github)."
    fi
  elif [ "$vis" = "all" ]; then
    echo "::warning::$sec_name has visibility='all' (accessible to forks/archived repos). Switch to 'Selected repositories' in https://github.com/organizations/$org/settings/secrets/actions/$sec_name and re-run harden-org.sh."
  fi
done

if gh api "/orgs/$org/actions/secrets/OPENCODE_API_KEY" >/dev/null 2>&1; then
  if [ "$prune" = true ] && [ "$dry_run" = false ]; then
    gh api -X DELETE "/orgs/$org/actions/secrets/OPENCODE_API_KEY" >/dev/null
    echo "Deleted stale organization secret OPENCODE_API_KEY."
  elif [ "$prune" = true ] && [ "$dry_run" = true ]; then
    echo "[dry-run] Would DELETE /orgs/$org/actions/secrets/OPENCODE_API_KEY"
  else
    echo "::warning::Stale secret OPENCODE_API_KEY still exists (previously scoped to archived repos). Delete via: gh api -X DELETE \"/orgs/$org/actions/secrets/OPENCODE_API_KEY\" (or re-run with --prune)"
  fi
else
  echo "OPENCODE_API_KEY: absent."
fi

# 7. Self-hosted runner scoping (org policy + Default runner group -> repos with self_hosted_runner=true)
echo "--- 7. Self-hosted runner scoping ---"
runner_ids=()
while IFS= read -r rname; do
  rid="$(resolve_repo_id "$rname")"
  if [ -n "$rid" ]; then
    runner_ids+=("$rid")
  fi
done < <(jq -r '.repositories[] | select(.self_hosted_runner == true) | .name' "$manifest")

if [ "${#runner_ids[@]}" -gt 0 ]; then
  runner_ids_json="$(printf '%s\n' "${runner_ids[@]}" | jq -s '.')"
else
  runner_ids_json='[]'
fi

if [ "${#runner_ids[@]}" -gt 0 ]; then
  if [ "$dry_run" = true ]; then
    echo "[dry-run] Would PUT /orgs/$org/actions/permissions/self-hosted-runners {\"enabled_repositories\":\"selected\"}"
    echo "[dry-run] Would PUT /orgs/$org/actions/permissions/self-hosted-runners/repositories with ${#runner_ids[@]} repo IDs: $runner_ids_json"
    echo "[dry-run] Would scope Default runner group (ID 1) to ${#runner_ids[@]} opt-in repos: $runner_ids_json"
  else
    if gh api -X PUT "/orgs/$org/actions/permissions/self-hosted-runners" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<'{"enabled_repositories":"selected"}' >/dev/null 2>&1; then
      echo "Set org self-hosted runner policy to selected repositories."
    else
      echo "::notice::Could not set org self-hosted runner policy via API (plan restriction); continuing."
    fi

    if gh api -X PUT "/orgs/$org/actions/permissions/self-hosted-runners/repositories" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"{\"selected_repository_ids\":${runner_ids_json}}" >/dev/null 2>&1; then
      echo "Scoped org self-hosted runners to ${#runner_ids[@]} repositories."
    else
      echo "::notice::Could not restrict org self-hosted runner repositories via API (GitHub Free plan limitation); continuing."
    fi

    if gh api -X PATCH "/orgs/$org/actions/runner-groups/1" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"{\"visibility\":\"selected\",\"selected_repository_ids\":${runner_ids_json},\"allows_public_repositories\":true}" >/dev/null 2>&1; then
      echo "Scoped Default runner group to ${#runner_ids[@]} self_hosted_runner repos."
    else
      echo "::notice::Could not restrict Default runner group visibility via API (GitHub Free plan limitation; rely on resolve-runner.yml trust gate + all_external_contributors)."
    fi
  fi
fi

# 8. Verification snapshot
echo "--- Verification ---"
gh api "/orgs/$org/actions/permissions" --jq '{enabled_repositories, allowed_actions, sha_pinning_required}'
gh api "/orgs/$org/actions/permissions/workflow" --jq '{default_workflow_permissions, can_approve_pull_request_reviews}'
gh api "/orgs/$org/actions/permissions/fork-pr-contributor-approval" --jq '{approval_policy}'
gh api "/orgs/$org/actions/permissions/fork-pr-workflows-private-repos" --jq '{run_workflows_from_fork_pull_requests, require_approval_for_fork_pr_workflows}' 2>/dev/null || true
gh api "/orgs/$org/actions/permissions/self-hosted-runners" --jq '{enabled_repositories}' 2>/dev/null || true
gh api "/orgs/$org/code-security/configurations" --jq '[.[] | select(.target_type == "organization") | {id, name, enforcement}]' 2>/dev/null || true
gh api "/orgs/$org/actions/oidc/customization/sub" 2>/dev/null || echo '{"oidc_sub": "not_set"}'
gh api "/orgs/$org/actions/secrets/ORG_SYNC_TOKEN" --jq '{name, visibility}' 2>/dev/null || true
