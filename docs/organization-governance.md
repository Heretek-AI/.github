# Organization Governance, Hardening & CI Standardization

This document records the organization-wide security baselines, CI secret/variable conventions, zero-bypass branch and tag rulesets, and tiered repository lifecycle state for [`Heretek-AI`](https://github.com/Heretek-AI).

## 1. Organization Security & Actions Hardening

Enforced via `scripts/harden-org.sh` against `/orgs/Heretek-AI`, `/orgs/Heretek-AI/actions/permissions`, and `/orgs/Heretek-AI/actions/permissions/workflow`:

| Setting | Value | Rationale |
| --- | --- | --- |
| `default_workflow_permissions` | `read` | Workflows receive read-only `GITHUB_TOKEN` permissions unless elevated per-job |
| `can_approve_pull_request_reviews` | `false` | Prevents GitHub Actions workflows from approving pull requests |
| `allowed_actions` | `selected` | Only allowlisted actions run; the list is applied from `org-actions-allowlist.json` |
| `sha_pinning_required` | `true` | Requires full-length commit SHA pins for all third-party GitHub Actions |
| `fork-pr-contributor-approval` | `all_external_contributors` | Every external fork PR needs maintainer approval before workflows run |
| `require_approval_for_fork_pr_workflows` | `true` (UI-only; API no-op on Free) | Private-repository fork PR workflows wait for approval, with no secrets/variables or write tokens sent |
| OIDC `sub` claim | `repo`, `context`, `job_workflow_ref` | Cloud trust policies can pin the repository and calling workflow |
| `default_repository_permission` | `read` | Organization members default to read access unless granted team/repo roles |
| `members_can_create_repositories` | `false` | Restricts new repository creation to organization owners |
| `members_can_fork_private_repositories` | `false` | Prevents private-repository forks outside the org |
| `web_commit_signoff_required` | `true` | Requires DCO sign-off on web-based commits |
| `deploy_keys_enabled_for_repositories` | `false` | Deploy keys cannot bypass rulesets or token scoping |
| `secret_scanning_enabled_for_new_repositories` | `true` | Automatically enables Secret Scanning on new repositories |
| `secret_scanning_push_protection_enabled_for_new_repositories` | `true` | Blocks pushes containing detected secrets on new repositories |
| `dependabot_alerts_enabled_for_new_repositories` | `true` | Enables vulnerability alerts without noisy auto-PRs |
| `dependabot_security_updates_enabled_for_new_repositories` | `true` | Enables automated security-fix PRs for new repositories |
| `dependency_graph_enabled_for_new_repositories` | `true` | Provides the dependency graph Dependabot and SBOM tooling require |
| Self-hosted runner policy | `selected` | Org runners are limited to the four `self_hosted_runner: true` opt-ins |
| Fleet code-security configuration | `Heretek-AI fleet baseline`, `enforcement: unenforced` | One baseline for active public repositories without CodeQL default setup |

### Code Security Baseline

`scripts/harden-org.sh` creates or updates the organization configuration `Heretek-AI fleet baseline` and attaches it to every active public managed repository plus `.github`:

- Secret scanning, push protection, and extended metadata: `enabled`
- Non-provider patterns and validity checks: configured `enabled`, but remain disabled on this plan because they require GitHub Secret Protection
- Private vulnerability reporting: `enabled`
- Dependency graph, Dependabot alerts, and Dependabot security updates: `enabled`
- `code_scanning_default_setup`: `not_set` (deliberate — avoids conflicting with repositories running advanced CodeQL workflows)
- `advanced_security`: `enabled` (the API requires this whenever a GHAS feature is enabled); `enforcement`: `unenforced`

The legacy organization configuration `250992` (CodeQL default setup enabled) is left untouched; the fleet baseline supersedes it for active public repositories.

## 2. Standardized Organization Secrets, Variables & Exceptions

All CI configuration is managed centrally at the organization level. Any per-repository secret or variable must be explicitly allowlisted in `fleet-manifest.json` (`secret_exceptions`) and is verified weekly by `scripts/audit_org.py`:

| Name | Type | Visibility | Notes |
| --- | --- | --- | --- |
| `ORG_SYNC_TOKEN` | Org Secret | `selected` (`.github` only) | Scoped exclusively to `Heretek-AI/.github` |
| `LLM_PROVIDER` | Org Variable | `all` | Canonical LLM provider (managed by `scripts/set-llm-profile.sh`) |
| `LLM_BASE_URL` | Org Variable | `all` | Canonical OpenAI/Anthropic-compatible base URL |
| `LLM_MODEL` | Org Variable | `all` | Canonical model ID (mirrored to `OCR_LLM_MODEL`) |
| `LLM_OPENCODE_MODEL` | Org Variable | `all` | Provider-prefixed OpenCode CLI model (mirrored to `OPENCODE_MODEL`) |
| `LLM_PROTOCOL` | Org Variable | `all` | `openai` or `anthropic` (mirrored to `OCR_LLM_USE_ANTHROPIC`) |
| `LLM_API_KEY` | Org Secret | `selected` (active managed repos + `.github`) | Canonical active LLM API key (mirrored to `OCR_LLM_TOKEN` / provider secret) |
| `OPENCODE_MODEL` | Org Variable | `all` | `opencode-go/muse-spark-1.3-contributor` |
| `OPENROUTER_API_KEY` | Org Secret | `selected` (active managed repos + `.github`) | OpenRouter key for the `openrouter-ernie-free` profile |
| `OPENCODE_GO_API_KEY` | Org Secret | `selected` (active managed repos + `.github`) | OpenCode Go inference token for the `opencode-muse-spark` profile |
| `OCR_LLM_URL` | Org Variable | `all` | `https://token-plan-sgp.xiaomimimo.com/v1` |
| `OCR_LLM_MODEL` | Org Variable | `all` | `mimo-v2.6-flash` |
| `OCR_LLM_USE_ANTHROPIC` | Org Variable | `all` | `false` |
| `OCR_LLM_TOKEN` | Org Secret | `selected` (active managed repos + `.github`) | API token for `alibaba/open-code-review` |
| `RUNNER_PROBE_TOKEN` | Org Secret | `selected` (active managed repos + `.github`) | Minimal read-only `Organization self-hosted runners: read` probe token for `resolve-runner.yml` |

`OPENCODE_API_KEY` is removed from the canonical set (stale; `scripts/harden-org.sh --prune` deletes it).

> **One-time UI switch:** the GitHub API cannot change an existing secret's visibility without re-uploading its value. Secrets currently at `all` must be switched once in **Org Settings -> Secrets and variables -> Actions -> `<secret>` -> Selected repositories**; until then `scripts/harden-org.sh` warns and only syncs `selected_repository_ids` for secrets already at `selected`.

### Approved Per-Repository Secret Exceptions

- `homebrew-tap`: `APP_PRIVATE_KEY`, `APP_ID`, `STX_HALO_ENABLED` (bottle publish & autobump automation)
- `ProxmoxVE`: `PAT_STANDALONE`, `PAT_WORKFLOW` (upstream helper-scripts sync automation)

## 3. Tiered Governance & Zero-Bypass Rulesets

All active repositories are classified in `fleet-manifest.json` (`schema_version: 2`):

- **Tier 1 — Flagship / Protected (7 managed repos + `.github`):** Enforces active zero-bypass (`bypass_actors: []`) default-branch rulesets (`keep summer safe`) and `v*` release-tag protection (`release-tags`) via `scripts/sync-rulesets.sh`, requiring a pull request with zero approvals, stale-review dismissal, review-thread resolution, and the `hygiene / No machine-local paths` check only where the repository invokes the shared hygiene workflow.
- **Tier 2 — Standard Active (5 repos):** Receives stack-matched Lefthook v2, `.editorconfig`, shared Agent Skills, and (where `actions_enabled: true`) `hygiene.yml` and non-blocking `ocr.yml`.
- **Tier 3 — Archive Candidates (0 repos):** `archive_candidates` is empty; `scripts/hygiene-backfill.sh` is the dry-run helper for any future review and archival.
- **Forks (3 repos):** Excluded from `fleet-sync` PRs to keep upstream history clean. `heretek-control-core` is a reference fork (`actions_enabled: false`); `OmniRoute` and `openrig` are active forks.
- **Self-hosted runner opt-ins (4):** `GDevelop-Unlocked`, `TAT-2`, `homebrew-tap`, and `game-engine` declare `self_hosted_runner: true`; every other repository must use `ubuntu-latest`.

## 4. Reusable `OpenCodeReview`, Opt-In Security/Quality Workflows & Third-Party Scanner Policy

- **`OpenCodeReview` (`.github/workflows/ocr-review.yml`):** Non-blocking (`continue-on-error: true` with warning annotation) and automatically skips `chore/sync-org-standards` bot PRs unless manually invoked via `/open-code-review` or `@open-code-review`.
- **Required security/hygiene gates:** `hygiene.yml` (machine-local paths + `zizmor`) and local Lefthook v2 (`no-local-paths`, `gitleaks`, stack linters, `actionlint`, `zizmor`, plus advisory `fallow` health checks on JS/TS profiles and guarded `tach` boundary checks on `python-uv` profiles when installed).
- **Opt-in reusable security & quality workflows (advisory by default):**
  - `security-scan.yml` (`templates/workflows/security-scan.yml`): Deterministic Trivy filesystem scan (`vuln,misconfig,secret`) with SARIF upload to GitHub Security.
  - `sast-semgrep.yml` (`templates/workflows/sast-semgrep.yml`): Deterministic Semgrep CE multi-language SAST with SARIF upload (supports custom packs such as `0xdea/semgrep-rules` for C/C++ repos).
  - `code-quality.yml` (`templates/workflows/code-quality.yml`): Deterministic `aislop` scan catching AI-agent anti-patterns with zero runtime LLM usage.
  - `secfoo-audit.yml` (`templates/workflows/secfoo-audit.yml`): Manual (`workflow_dispatch`) or scheduled BYOK AI security audit using canonical `LLM_*` org vars/secrets with SARIF upload (excludes fork PRs and `chore/sync-org-standards`).
- **Shared security review skill:** `skills/security-review/SKILL.md` provides a structured threat-model-first review workflow for coding agents and maintainers.
- **Third-party scanners (`CodeQL`, `SonarCloud`, `Sourcery`):** Kept non-blocking/advisory unless explicitly required in a Tier 1 repository's ruleset.

## 5. Automated Weekly Drift Detection

[`.github/workflows/org-drift-audit.yml`](../.github/workflows/org-drift-audit.yml) runs `scripts/audit_org.py` every Monday at 09:00 UTC (and on `workflow_dispatch`). Strict categories cover:

- **Organization hardening:** default permissions, repository creation, `deploy_keys_enabled_for_repositories`, sign-off, read-only workflow tokens, `allowed_actions=selected` against `org-actions-allowlist.json`, `sha_pinning_required`, fork-PR approval, private-fork workflow approval, OIDC `sub` claims, runner-group visibility, self-hosted runner policy, and unapproved per-repo secrets/variables.
- **Third-party apps:** installs with `administration: write`, or `workflows`/`repository_hooks: write` while installed on all repositories.
- **Secret hygiene:** org secrets at `all`, secrets scoped to archived or untracked repositories, and the stale `OPENCODE_API_KEY`.
- **Per-repository security:** private vulnerability reporting, secret scanning with push protection, immutable releases, and the fleet code-security configuration attachment. Non-provider patterns and validity checks are reported as advisory because they require Secret Protection.
- **Ruleset compliance:** zero-bypass PR-only default-branch rulesets, release-tag rulesets, and the hygiene check matching whether the repository runs the shared workflow.
- **Unpinned actions:** any `uses:` ref that is not a full 40-char commit SHA.
- **Custom properties:** `tier`, `stack_profile`, `security_critical`, and `managed_by` against `fleet-manifest.json`.
- **`unavailable` fail-closed surfaces:** unreadable APIs are reported as unknown posture and fail `--strict`, never as healthy.

Manifest drift, license/description gaps, and stalled sync PRs are reported as advisory categories.

## 6. Optional Self-Hosted CI Runner (`stx-halo`)

Heavy CI workloads can opt into the Proxmox VE self-hosted runner (`stx-halo`, `rocm`, `gfx1151`) via [`.github/workflows/resolve-runner.yml`](../.github/workflows/resolve-runner.yml), which enforces a fork-PR trust gate and automatically falls back to `ubuntu-latest` when `stx-halo` is offline. The org self-hosted runner policy is `selected`, limited by `fleet-manifest.json` (`self_hosted_runner: true`) to `GDevelop-Unlocked`, `TAT-2`, `homebrew-tap`, and `game-engine`. The Default runner group PATCH is plan-limited, so its visibility may remain `all`; the org policy is the effective control. See [`docs/self-hosted-runner-proxmox.md`](self-hosted-runner-proxmox.md) for host hardening and setup.

## 7. UI-Only Organization Hardening Checklist

These controls have no supported API in the current plan and must be reviewed in the GitHub UI:

- **2FA and passkeys:** Require 2FA for all members and encourage passkeys for owners.
- **GitHub Apps:** Scope `claude`, `coderabbitai`, and `sourcery-ai` to selected repositories, excluding `.github`; review `sonarqubecloud` and `codecov` for unnecessary repository or permission scope.
- **OAuth App Access Restrictions:** Restrict third-party OAuth apps to approved applications.
- **PAT policy:** Require fine-grained PAT approval, cap maximum lifetime at 90 days, restrict classic PATs, and migrate `ProxmoxVE`'s `PAT_STANDALONE` / `PAT_WORKFLOW` to approved fine-grained tokens.
- **Verified domain:** Verify the organization domain so profile badges and email restrictions can be enforced.
- **Actions policy review:** Re-check `allowed_actions=selected` and the allowlist whenever a workflow adds a new publisher.
- **Private-fork workflow approval:** The API PUT returns 204 but does not change the setting on Free; enable *Require approval for fork pull request workflows* in **Org Settings -> Actions -> General**.
- **Runner group visibility:** The Default runner group PATCH is plan-limited; the org self-hosted runner policy is `selected`. Set group-level repository access in **Org Settings -> Actions -> Runner groups** if required.
- **Secret Protection:** Non-provider patterns and validity checks require GitHub Secret Protection; upgrade if those signals are required.
- **Copilot and Codespaces least privilege:** Limit seat assignment and repository access to active maintainers.
- **Secret visibility switch:** Perform the one-time `all` -> `selected` re-scope described in §2 so `harden-org.sh` can sync the exact repository list.
