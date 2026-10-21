#!/usr/bin/env bash
# Propagate standardized Agent Skills, Lefthook configs, workflow SHA pins,
# and labels from Heretek-AI/.github to target repositories via idempotent PRs.
#
# Usage:
#   scripts/sync-fleet.sh [--dry-run] [--repo <repo-name>]
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
      echo "usage: $0 [--dry-run] [--repo <repo-name>]" >&2
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

if [ "$dry_run" = false ]; then
  gh auth setup-git
fi

echo "=== Heretek-AI Fleet Sync (@$short_sha, dry_run=$dry_run) ==="

while IFS=$'	' read -r repo_name profile actions_enabled; do
  if [ -n "$filter_repo" ] && [ "$repo_name" != "$filter_repo" ]; then
    continue
  fi

  full_repo="$org/$repo_name"
  echo "--- Processing $full_repo (profile=$profile, actions_enabled=$actions_enabled) ---"

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

  default_branch="$(git -C "$clone_dir" rev-parse --abbrev-ref HEAD)"
  git -C "$clone_dir" checkout -B "$sync_branch"

  # 3. Copy stack-specific lefthook.yml
  lefthook_tpl="$(jq -r --arg p "$profile" '.profiles[$p].lefthook_template' "$manifest")"
  cp "$root/$lefthook_tpl" "$clone_dir/lefthook.yml"

  # 4. Sync canonical Agent Skills into .agents/skills/ and harness symlinks
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

  # 5. For workflow-enabled repos, sync .github/actionlint.yaml and bump reusable workflow SHAs
  if [ "$actions_enabled" = "true" ]; then
    mkdir -p "$clone_dir/.github/workflows"
    cp "$root/.github/actionlint.yaml" "$clone_dir/.github/actionlint.yaml"

    # Rewrite Heretek-AI/.github/.github/workflows/<wf>.yml@<40-hex-or-main> to @$source_sha # main
    for wf in "$clone_dir"/.github/workflows/*.{yml,yaml}; do
      [ -f "$wf" ] || continue
      sed -i -E         "s|(Heretek-AI/\.github/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml)@[0-9a-f]{40}([[:space:]]*#.*)?|\1@${source_sha} # main|g"         "$wf"
    done
  fi

  # 6. Check if anything changed
  if [ -z "$(git -C "$clone_dir" status --porcelain)" ]; then
    echo "$full_repo: already up to date with @$short_sha"
    continue
  fi

  git -C "$clone_dir" status --short

  if [ "$dry_run" = true ]; then
    echo "[dry-run] Would commit and open/update PR on $full_repo ($sync_branch -> $default_branch)"
    continue
  fi

  # 7. Commit with DCO sign-off (web_commit_signoff_required: true) and open/update PR
  git -C "$clone_dir" config user.name "heretek-fleet-sync[bot]"
  git -C "$clone_dir" config user.email "heretek-fleet-sync[bot]@users.noreply.github.com"
  git -C "$clone_dir" add -A
  git -C "$clone_dir" commit --signoff -m "chore(org-sync): propagate Heretek-AI/.github@$short_sha standards"
  git -C "$clone_dir" push --force-with-lease origin "$sync_branch"

  pr_title="chore(org-sync): sync Heretek-AI/.github@$short_sha standards ($profile)"
  pr_body="$(cat <<EOF
## What and why

Automated organization standardization sync from \`Heretek-AI/.github@${source_sha}\` (profile: \`${profile}\`).

- Updates \`lefthook.yml\` to the \`${profile}\` Lefthook v2 job profile
- Syncs shared Agent Skills under \`.agents/skills/\` (with \`.opencode/skills\`, \`.claude/skills\`, and \`.github/skills\` discovery paths)
- Bumps reusable workflow pins (\`Heretek-AI/.github/.github/workflows/*\`) to \`${source_sha}\`

## Evidence

\`\`\`text
Source commit: Heretek-AI/.github@${source_sha}
Target profile: ${profile}
Validated by: Heretek-AI/.github CI (hygiene, actionlint, zizmor, validate-skills.sh, shellcheck)
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
done < <(jq -r '.repositories[] | [.name, .profile, (.actions_enabled | tostring)] | @tsv' "$manifest")
