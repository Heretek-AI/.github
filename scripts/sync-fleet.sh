#!/usr/bin/env bash
# Propagate standardized Agent Skills, Lefthook v2 configs, .editorconfig,
# starter hygiene/OCR workflows, workflow/action SHA pins, and labels from
# Heretek-AI/.github to target repositories via idempotent DCO-signed PRs.
#
# Usage:
#   scripts/sync-fleet.sh [--dry-run] [--repo <repo-name>] [--tier <1|2>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
dry_run=false
filter_repo=""
filter_tier=""

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
    --tier)
      filter_tier="${2:-}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--dry-run] [--repo <repo-name>] [--tier <1|2>]" >&2
      exit 2
      ;;
  esac
done

org="$(jq -r '.organization' "$manifest")"
sync_branch="$(jq -r '.sync_branch' "$manifest")"
source_sha="$(git -C "$root" rev-parse HEAD)"
short_sha="$(git -C "$root" rev-parse --short HEAD)"
work_tmp="$(mktemp -d -t heretek-fleet-sync-XXXXXX)"
trap 'rm -rf "$work_tmp"' EXIT

# Pin third-party `uses:` refs to full-length commit SHAs (org policy:
# sha_pinning_required). Rewrites every workflow file in the clone and prints
# the number of refs pinned to stdout; unresolved refs warn on stderr.
pin_workflow_actions() {
  local clone_dir="$1"
  local wf line re prefix owner_repo path ref suffix quote key sha out tmp pinned
  local -A resolved=()
  local -A warned=()

  re="^([[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"']?)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/[^@[:space:]\"']+)?@([^[:space:]\"'#]+)([\"']?[[:space:]]*(#.*)?)\$"

  pinned=0
  for wf in "$clone_dir"/.github/workflows/*.yml "$clone_dir"/.github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    tmp="$(mktemp "${TMPDIR:-/tmp}/pin-workflow-actions-XXXXXX")"
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ ! "$line" =~ $re ]]; then
        printf '%s\n' "$line" >>"$tmp"
        continue
      fi

      prefix="${BASH_REMATCH[1]}"
      owner_repo="${BASH_REMATCH[3]}"
      path="${BASH_REMATCH[4]}"
      ref="${BASH_REMATCH[5]}"
      suffix="${BASH_REMATCH[6]}"
      quote=""
      case "$suffix" in
        \"* | \'*) quote="${suffix:0:1}" ;;
      esac

      # Skip existing full-SHA pins, local/composite/container targets, and
      # reusable workflows owned by this repository (rewritten above).
      if [[ "$ref" =~ ^[0-9a-f]{40}$ ]] ||
        [[ "$owner_repo" == ./* ]] ||
        [[ "$owner_repo" == \$/* ]] ||
        [[ "$owner_repo" == docker://* ]] ||
        [[ "$owner_repo" == "Heretek-AI/.github" ]]; then
        printf '%s\n' "$line" >>"$tmp"
        continue
      fi

      key="$owner_repo@$ref"
      if [ -z "${resolved[$key]:-}" ] && [ -z "${warned[$key]:-}" ]; then
        sha=""
        if out="$(timeout 30 git ls-remote "https://github.com/$owner_repo" \
          "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref" 2>/dev/null)"; then
          # Prefer the peeled tag commit, then the tag, then the branch.
          sha="$(printf '%s\n' "$out" | awk -v want="refs/tags/$ref^{}" '$2 == want { print $1; exit }')"
          if [ -z "$sha" ]; then
            sha="$(printf '%s\n' "$out" | awk -v want="refs/tags/$ref" '$2 == want { print $1; exit }')"
          fi
          if [ -z "$sha" ]; then
            sha="$(printf '%s\n' "$out" | awk -v want="refs/heads/$ref" '$2 == want { print $1; exit }')"
          fi
        fi
        if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
          resolved["$key"]="$sha"
        else
          warned["$key"]=1
          echo "::warning::Could not resolve $owner_repo@$ref; leaving unpinned" >&2
        fi
      fi

      sha="${resolved[$key]:-}"
      if [ -z "$sha" ]; then
        printf '%s\n' "$line" >>"$tmp"
        continue
      fi
      printf '%s\n' "${prefix}${owner_repo}${path}@${sha}${quote} # ${ref}" >>"$tmp"
      pinned=$((pinned + 1))
    done <"$wf"

    if ! cmp -s "$tmp" "$wf"; then
      cat "$tmp" >"$wf"
    fi
    rm -f "$tmp"
  done

  echo "$pinned"
}

if [ "$dry_run" = false ]; then
  gh auth setup-git
fi

echo "=== Heretek-AI Fleet Sync v2 (@$short_sha, dry_run=$dry_run, tier=${filter_tier:-all}) ==="

while IFS=$'\t' read -r repo_name tier profile actions_enabled; do
  if [ -n "$filter_repo" ] && [ "$repo_name" != "$filter_repo" ]; then
    continue
  fi
  if [ -n "$filter_tier" ] && [ "$tier" != "$filter_tier" ]; then
    continue
  fi

  full_repo="$org/$repo_name"
  echo "--- Processing $full_repo (tier=$tier, profile=$profile, actions_enabled=$actions_enabled) ---"

  # Skip archived repositories defensively
  is_archived="$(gh api "/repos/$full_repo" --jq '.archived' 2>/dev/null || echo "true")"
  if [ "$is_archived" = "true" ]; then
    echo "::notice::$full_repo is archived or inaccessible; skipping."
    continue
  fi

  # 1. Sync organization labels
  if [ "$dry_run" = false ]; then
    "$root/scripts/sync-labels.sh" --update "$full_repo" || echo "::warning::Label sync skipped for $full_repo"
  else
    echo "[dry-run] Would sync labels.json to $full_repo"
  fi

  # 2. Clone target repository default branch
  clone_dir="$work_tmp/$repo_name"
  if ! gh repo clone "$full_repo" "$clone_dir" -- --depth=1 2>/dev/null; then
    echo "::warning::Could not clone $full_repo; skipping."
    continue
  fi

  # Skip empty repositories with no commits
  if ! git -C "$clone_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "::notice::$full_repo has no commits on default branch; skipping."
    continue
  fi

  default_branch="$(git -C "$clone_dir" rev-parse --abbrev-ref HEAD)"
  git -C "$clone_dir" checkout -B "$sync_branch"

  # 3. Copy stack-specific lefthook.yml
  lefthook_tpl="$(jq -r --arg p "$profile" '.profiles[$p].lefthook_template' "$manifest")"
  cp "$root/$lefthook_tpl" "$clone_dir/lefthook.yml"

  # 4. Seed .editorconfig if missing
  sync_editorconfig="$(jq -r --arg p "$profile" '.profiles[$p].sync_editorconfig // false' "$manifest")"
  if [ "$sync_editorconfig" = "true" ] && [ ! -f "$clone_dir/.editorconfig" ]; then
    cp "$root/templates/configs/.editorconfig" "$clone_dir/.editorconfig"
  fi

  # 5. Sync canonical Agent Skills into .agents/skills/ and harness symlinks
  mkdir -p "$clone_dir/.agents/skills"
  for skill_dir in "$root"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    rm -rf "$clone_dir/.agents/skills/$skill_name"
    cp -R "$skill_dir" "$clone_dir/.agents/skills/$skill_name"
  done

  # Ensure cross-agent discovery symlinks (.opencode/skills, .claude/skills, .github/skills)
  for harness_dir in .opencode .claude .github; do
    mkdir -p "$clone_dir/$harness_dir"
    if [ ! -e "$clone_dir/$harness_dir/skills" ] && [ ! -L "$clone_dir/$harness_dir/skills" ]; then
      ln -s ../.agents/skills "$clone_dir/$harness_dir/skills"
    fi
  done

  # Repositories commonly ignore .agents/ (local agent state). Fleet skills are
  # tracked source, so add a later negation when the ignore rule is present.
  if [ -f "$clone_dir/.gitignore" ] && grep -qxF '.agents/' "$clone_dir/.gitignore"; then
    printf '\n# Fleet-managed Agent Skills are tracked\n!.agents/\n' >>"$clone_dir/.gitignore"
  fi

  # 6. For workflow-enabled repos, sync .github/actionlint.yaml, bootstrap hygiene/ocr if missing, and bump SHAs
  if [ "$actions_enabled" = "true" ]; then
    mkdir -p "$clone_dir/.github/workflows"
    cp "$root/.github/actionlint.yaml" "$clone_dir/.github/actionlint.yaml"

    # Bootstrap hygiene.yml only if no workflow already calls Heretek-AI/.github/.github/workflows/hygiene.yml
    if ! grep -Rqs "Heretek-AI/\.github/\.github/workflows/hygiene\.yml" "$clone_dir/.github/workflows/" 2>/dev/null; then
      cp "$root/templates/workflows/hygiene.yml" "$clone_dir/.github/workflows/hygiene.yml"
    fi

    # Bootstrap ocr.yml only if no workflow already calls Heretek-AI/.github/.github/workflows/ocr-review.yml
    if ! grep -Rqs "Heretek-AI/\.github/\.github/workflows/ocr-review\.yml" "$clone_dir/.github/workflows/" 2>/dev/null; then
      cp "$root/templates/workflows/ocr.yml" "$clone_dir/.github/workflows/ocr.yml"
    fi

    # Rewrite Heretek-AI/.github/.github/workflows/<wf>.yml@<40-hex> to @$source_sha # main
    for wf in "$clone_dir"/.github/workflows/*.{yml,yaml}; do
      [ -f "$wf" ] || continue
      sed -i -E \
        "s|(Heretek-AI/\.github/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml)@[0-9a-f]{40}([[:space:]]*#.*)?|\1@${source_sha} # main|g" \
        "$wf"
    done

    # Pin third-party action/workflow refs to full commit SHAs (the org
    # enforces sha_pinning_required: true; tag refs fail workflow startup).
    pinned_count="$(pin_workflow_actions "$clone_dir")"
    if [ "$pinned_count" -gt 0 ]; then
      echo "$repo_name: pinned $pinned_count action ref(s)"
    fi
  fi

  # 7. Check if anything changed
  if [ -z "$(git -C "$clone_dir" status --porcelain)" ]; then
    echo "$full_repo: already up to date with @$short_sha"
    continue
  fi

  git -C "$clone_dir" status --short

  if [ "$dry_run" = true ]; then
    echo "[dry-run] Would commit and open/update PR on $full_repo ($sync_branch -> $default_branch)"
    continue
  fi

  # 8. Commit with DCO sign-off (web_commit_signoff_required: true) and open/update PR
  git -C "$clone_dir" config user.name "heretek-fleet-sync[bot]"
  git -C "$clone_dir" config user.email "heretek-fleet-sync[bot]@users.noreply.github.com"
  git -C "$clone_dir" add -A
  # .agents/ is often ignored; force-add the synced skills and harness links so
  # the PR actually carries them.
  git -C "$clone_dir" add -f .agents .opencode/skills .claude/skills .github/skills 2>/dev/null || true
  git -C "$clone_dir" commit --signoff -m "chore(org-sync): propagate Heretek-AI/.github@$short_sha standards"
  remote_sha="$(git -C "$clone_dir" ls-remote --heads origin "$sync_branch" | awk '{print $1}')"
  if [ -n "$remote_sha" ]; then
    push_cmd=(git -C "$clone_dir" push --force-with-lease="$sync_branch:$remote_sha" origin "$sync_branch")
  else
    push_cmd=(git -C "$clone_dir" push origin "$sync_branch")
  fi
  if ! "${push_cmd[@]}"; then
    echo "::warning::Failed to push $sync_branch to $full_repo; continuing with remaining repositories."
    continue
  fi

  pr_title="chore(org-sync): sync Heretek-AI/.github@$short_sha standards (tier-$tier / $profile)"
  pr_body="$(
    cat <<EOF
## What and why

Automated organization standardization sync from \`Heretek-AI/.github@${source_sha}\` (tier: \`${tier}\`, profile: \`${profile}\`).

- Updates \`lefthook.yml\` to the \`${profile}\` Lefthook v2 job profile
- Seeds \`.editorconfig\` if absent
- Syncs shared Agent Skills under \`.agents/skills/\` (with \`.opencode/skills\`, \`.claude/skills\`, and \`.github/skills\` discovery symlinks)
- Ensures baseline \`hygiene.yml\` / \`ocr.yml\` callers and bumps reusable workflow pins (\`Heretek-AI/.github/.github/workflows/*\`) to \`${source_sha}\`
- Pins third-party action and reusable-workflow \`uses:\` refs to full-length commit SHAs (org \`sha_pinning_required\`)

## Evidence

\`\`\`text
Source commit: Heretek-AI/.github@${source_sha}
Target tier: ${tier}
Target profile: ${profile}
Validated by: Heretek-AI/.github CI (hygiene, zizmor, validate-skills.sh, shellcheck)
\`\`\`

## Linked issues

Tracked by \`Heretek-AI/.github\` organization standardization.
EOF
  )"

  existing_pr="$(gh pr list --repo "$full_repo" --head "$sync_branch" --base "$default_branch" --json number --jq '.[0].number // empty')"
  if [ -n "$existing_pr" ]; then
    gh pr edit "$existing_pr" --repo "$full_repo" --title "$pr_title" --body "$pr_body" >/dev/null
    echo "$full_repo: updated PR #$existing_pr"
  else
    pr_url="$(gh pr create --repo "$full_repo" --head "$sync_branch" --base "$default_branch" --title "$pr_title" --body "$pr_body" --label "org-sync")"
    echo "$full_repo: created $pr_url"
  fi
done < <(jq -r '.repositories[] | [.name, (.tier | tostring), .profile, (.actions_enabled | tostring)] | @tsv' "$manifest")
