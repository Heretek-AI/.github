#!/usr/bin/env bash
# Ensure all Tier 1 (protected_ruleset=true) repositories (and .github) have
# active zero-bypass default-branch and release-tag rulesets, reconciling any
# drifted rulesets (e.g. non-empty bypass_actors, missing pull_request rule,
# or missing required_status_checks).
#
# The hygiene required check is only enforced where the repository actually
# invokes the shared reusable workflow, plus Heretek-AI/.github itself (the
# control plane that defines .github/workflows/hygiene.yml).
#
# Usage: scripts/sync-rulesets.sh [--dry-run] [--repo <name>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
branch_tpl="$root/templates/rulesets/tier1-main.json"
tag_tpl="$root/templates/rulesets/tier1-tags.json"
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
echo "=== $org Tier 1 Ruleset Sync (dry_run=$dry_run) ==="

declare -A hygiene_cache=()

# Determine whether a repository invokes the reusable hygiene workflow.
# Results are cached so each repository costs at most one directory listing.
repo_has_hygiene_workflow() {
  local full_repo="$1"

  if [ -n "${hygiene_cache[$full_repo]+set}" ]; then
    [ "${hygiene_cache[$full_repo]}" = "true" ]
    return
  fi

  # Heretek-AI/.github owns .github/workflows/hygiene.yml and therefore does
  # not reference itself by path.
  if [ "$full_repo" = "$org/.github" ]; then
    hygiene_cache[$full_repo]=true
    return 0
  fi

  local names
  if ! names="$(gh api "/repos/$full_repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null)"; then
    echo "::warning::$full_repo: could not list .github/workflows; treating hygiene workflow as absent." >&2
    hygiene_cache[$full_repo]=false
    return 1
  fi

  local name content text
  while IFS= read -r name; do
    case "$name" in
      *.yml | *.yaml) ;;
      *) continue ;;
    esac
    if ! content="$(gh api "/repos/$full_repo/contents/.github/workflows/$name" --jq '.content' 2>/dev/null)"; then
      echo "::warning::$full_repo: could not read workflow $name; treating it as not invoking hygiene." >&2
      continue
    fi
    text="$(printf '%s' "$content" | tr -d '\n' | base64 -d 2>/dev/null || true)"
    case "$text" in
      *"Heretek-AI/.github/.github/workflows/hygiene.yml"*)
        hygiene_cache[$full_repo]=true
        return 0
        ;;
    esac
  done <<<"$names"

  hygiene_cache[$full_repo]=false
  return 1
}

reconcile_branch_ruleset() {
  local full_repo="$1"
  local rs_id="$2"
  local current
  current="$(gh api "/repos/$full_repo/rulesets/$rs_id")"

  local want_hygiene=false
  if repo_has_hygiene_workflow "$full_repo"; then
    want_hygiene=true
  fi

  local bypass_count has_pr has_hygiene pr_ok has_empty_checks rs_name
  bypass_count="$(jq '.bypass_actors | length' <<<"$current")"
  has_pr="$(jq '[.rules[] | select(.type == "pull_request")] | length' <<<"$current")"
  has_hygiene="$(jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | select(.context == "hygiene / No machine-local paths")] | length' <<<"$current")"
  pr_ok="$(jq '[.rules[] | select(.type == "pull_request") | select(.parameters.required_approving_review_count == 0 and .parameters.dismiss_stale_reviews_on_push == true and .parameters.required_review_thread_resolution == true)] | length' <<<"$current")"
  has_empty_checks="$(jq '[.rules[] | select(.type == "required_status_checks") | ((.parameters.required_status_checks // []) | length == 0)] | any' <<<"$current")"
  rs_name="$(jq -r '.name' <<<"$current")"

  local hygiene_ok=true
  if [ "$want_hygiene" = true ] && [ "$has_hygiene" -eq 0 ]; then
    hygiene_ok=false
  elif [ "$want_hygiene" = false ] && [ "$has_hygiene" -gt 0 ]; then
    hygiene_ok=false
  fi

  if [ "$bypass_count" -eq 0 ] && [ "$has_pr" -gt 0 ] && [ "$pr_ok" -gt 0 ] && [ "$hygiene_ok" = true ] && [ "$has_empty_checks" = false ]; then
    echo "$full_repo: default-branch ruleset #$rs_id ($rs_name) is compliant"
    return 0
  fi

  if [ "$want_hygiene" = false ] && [ "$has_hygiene" -gt 0 ]; then
    echo "::warning::$full_repo: removing required check 'hygiene / No machine-local paths' because the repository does not invoke Heretek-AI/.github/.github/workflows/hygiene.yml."
  fi

  # Preserve repo-specific required checks, pull_request parameters, and the
  # existing strict_required_status_checks_policy. Drop the required status
  # checks rule entirely when no checks remain (an empty list is invalid).
  local updated
  updated="$(jq --arg want_hygiene "$want_hygiene" --slurpfile tpl "$branch_tpl" '
    ($want_hygiene == "true") as $want
    | ($tpl[0].rules[] | select(.type == "pull_request")) as $tpl_pr
    | ([.rules[] | select(.type == "required_status_checks")][0]) as $rsc
    | ([.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?]) as $existing
    | (if $want
        then ($existing + [{context: "hygiene / No machine-local paths"}])
        else ($existing | map(select(.context != "hygiene / No machine-local paths")))
      end) as $checks
    | ($checks | unique_by(.context)) as $merged_checks
    | ((.rules[] | select(.type == "pull_request")) // $tpl_pr) as $current_pr
    | ($current_pr
        | .parameters = ((.parameters // {}) + {
            required_approving_review_count: 0,
            dismiss_stale_reviews_on_push: true,
            required_review_thread_resolution: true
          })) as $pr_rule
    | ([.rules[] | select(.type != "deletion" and .type != "non_fast_forward" and .type != "pull_request" and .type != "required_status_checks")]) as $other_rules
    | {
        name: .name,
        target: .target,
        enforcement: "active",
        bypass_actors: [],
        conditions: .conditions,
        rules: (
          [
            {type: "deletion"},
            {type: "non_fast_forward"},
            $pr_rule
          ]
          + (if ($merged_checks | length) > 0 then
              [{
                type: "required_status_checks",
                parameters: (
                  {
                    strict_required_status_checks_policy: (($rsc.parameters.strict_required_status_checks_policy) // false),
                    required_status_checks: $merged_checks
                  }
                  + (if $rsc.parameters.do_not_enforce_on_create == null
                      then {}
                      else {do_not_enforce_on_create: $rsc.parameters.do_not_enforce_on_create}
                    end)
                )
              }]
            else [] end)
          + $other_rules
        )
      }
  ' <<<"$current")"

  if [ "$dry_run" = true ]; then
    echo "[dry-run] $full_repo: would reconcile branch ruleset #$rs_id ($rs_name)"
    if [ "$bypass_count" -gt 0 ]; then
      echo "[dry-run] $full_repo:   - remove $bypass_count bypass actor(s)"
    fi
    if [ "$has_pr" -eq 0 ]; then
      echo "[dry-run] $full_repo:   - add pull_request rule from templates/rulesets/tier1-main.json"
    elif [ "$pr_ok" -eq 0 ]; then
      echo "[dry-run] $full_repo:   - normalize pull_request parameters (0 approvals, dismiss stale, thread resolution)"
    fi
    if [ "$want_hygiene" = true ] && [ "$has_hygiene" -eq 0 ]; then
      echo "[dry-run] $full_repo:   - add required check 'hygiene / No machine-local paths'"
    elif [ "$want_hygiene" = false ] && [ "$has_hygiene" -gt 0 ]; then
      echo "[dry-run] $full_repo:   - remove required check 'hygiene / No machine-local paths'"
    fi
    if [ "$has_empty_checks" = true ]; then
      echo "[dry-run] $full_repo:   - replace empty required_status_checks rule"
    fi
  else
    gh api -X PUT "/repos/$full_repo/rulesets/$rs_id" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"$updated" >/dev/null
    echo "$full_repo: reconciled default-branch ruleset #$rs_id (zero-bypass, PR-only, hygiene=$want_hygiene)"
  fi
}

reconcile_tag_ruleset() {
  local full_repo="$1"
  local rs_id="$2"
  local current
  current="$(gh api "/repos/$full_repo/rulesets/$rs_id")"

  local bypass_count
  bypass_count="$(jq '.bypass_actors | length' <<<"$current")"
  if [ "$bypass_count" -eq 0 ]; then
    echo "$full_repo: tag ruleset #$rs_id is compliant (zero-bypass)"
    return 0
  fi

  local updated
  updated="$(jq '{
    name: .name,
    target: .target,
    enforcement: "active",
    bypass_actors: [],
    conditions: .conditions,
    rules: .rules
  }' <<<"$current")"

  if [ "$dry_run" = true ]; then
    echo "[dry-run] $full_repo: would remove $bypass_count bypass_actor(s) from tag ruleset #$rs_id"
  else
    gh api -X PUT "/repos/$full_repo/rulesets/$rs_id" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"$updated" >/dev/null
    echo "$full_repo: enforced zero-bypass on tag ruleset #$rs_id"
  fi
}

process_repo() {
  local repo_name="$1"
  local require_tags="$2"

  if [ -n "$filter_repo" ] && [ "$repo_name" != "$filter_repo" ]; then
    return 0
  fi

  local full_repo="$org/$repo_name"
  local rulesets
  rulesets="$(gh api "/repos/$full_repo/rulesets" 2>/dev/null || echo '[]')"

  local branch_id tag_id
  branch_id="$(jq -r '
    [.[] | select(.target == "branch" and .enforcement == "active")] as $active
    | (($active | map(select(.name == "keep summer safe")) | .[0].id) // ($active[0].id) // empty)
  ' <<<"$rulesets")"
  tag_id="$(jq -r '[.[] | select(.target == "tag" and .enforcement == "active")][0].id // empty' <<<"$rulesets")"

  if [ -z "$branch_id" ]; then
    if [ "$dry_run" = true ]; then
      echo "[dry-run] $full_repo: would create default-branch ruleset from templates/rulesets/tier1-main.json"
    else
      gh api -X POST "/repos/$full_repo/rulesets" --input "$branch_tpl" >/dev/null
      echo "$full_repo: created default-branch ruleset 'keep summer safe'"
    fi
  else
    reconcile_branch_ruleset "$full_repo" "$branch_id"
  fi

  if [ "$require_tags" = "true" ]; then
    if [ -z "$tag_id" ]; then
      if [ "$dry_run" = true ]; then
        echo "[dry-run] $full_repo: would create release-tags ruleset from templates/rulesets/tier1-tags.json"
      else
        gh api -X POST "/repos/$full_repo/rulesets" --input "$tag_tpl" >/dev/null
        echo "$full_repo: created tag ruleset 'release-tags'"
      fi
    else
      reconcile_tag_ruleset "$full_repo" "$tag_id"
    fi
  fi
}

process_repo ".github" "false"

while IFS= read -r repo_name; do
  process_repo "$repo_name" "true"
done < <(jq -r '.repositories[] | select(.protected_ruleset == true) | .name' "$manifest")
