# Organization Governance, Hardening & CI Standardization

This document records the organization-wide security baselines, CI secret/variable conventions, zero-bypass branch and tag rulesets, and tiered repository lifecycle state for [`Heretek-AI`](https://github.com/Heretek-AI).

## 1. Organization Security & Actions Hardening

Enforced via `scripts/harden-org.sh` against `/orgs/Heretek-AI`, `/orgs/Heretek-AI/actions/permissions`, and `/orgs/Heretek-AI/actions/permissions/workflow`:

| Setting | Value | Rationale |
| --- | --- | --- |
| `default_workflow_permissions` | `read` | Workflows receive read-only `GITHUB_TOKEN` permissions unless elevated per-job |
| `can_approve_pull_request_reviews` | `false` | Prevents GitHub Actions workflows from approving pull requests |
| `sha_pinning_required` | `true` | Requires full-length commit SHA pins for all third-party GitHub Actions |
| `default_repository_permission` | `read` | Organization members default to read access unless granted team/repo roles |
| `members_can_create_repositories` | `false` | Restricts new repository creation to organization owners |
| `web_commit_signoff_required` | `true` | Requires DCO sign-off on web-based commits |
| `secret_scanning_enabled_for_new_repositories` | `true` | Automatically enables Secret Scanning on new repositories |
| `secret_scanning_push_protection_enabled_for_new_repositories` | `true` | Blocks pushes containing detected secrets on new repositories |
| `dependabot_alerts_enabled_for_new_repositories` | `true` | Enables vulnerability alerts without noisy auto-PRs |
| `dependabot_security_updates_enabled_for_new_repositories` | `false` | Disables automated Dependabot PR noise by default |

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
| `LLM_API_KEY` | Org Secret | `all` | Canonical active LLM API key (mirrored to `OCR_LLM_TOKEN` / provider secret) |
| `OPENCODE_MODEL` | Org Variable | `all` | `opencode-go/muse-spark-1.3-contributor` |
| `OPENCODE_API_KEY` | Org Secret | `selected` | Scoped to live-eval repositories |
| `OPENCODE_GO_API_KEY` | Org Secret | `all` | OpenCode Go inference token |
| `OCR_LLM_URL` | Org Variable | `all` | `https://token-plan-sgp.xiaomimimo.com/v1` |
| `OCR_LLM_MODEL` | Org Variable | `all` | `mimo-v2.6-flash` |
| `OCR_LLM_USE_ANTHROPIC` | Org Variable | `all` | `false` |
| `OCR_LLM_TOKEN` | Org Secret | `all` | API token for `Heretek-AI/open-code-review` |

### Approved Per-Repository Secret Exceptions

- `homebrew-tap`: `APP_PRIVATE_KEY`, `APP_ID`, `STX_HALO_ENABLED` (bottle publish & autobump automation)
- `ProxmoxVE`: `PAT_STANDALONE`, `PAT_WORKFLOW` (upstream helper-scripts sync automation)

## 3. Tiered Governance & Zero-Bypass Rulesets

All active repositories are classified in `fleet-manifest.json` (`schema_version: 2`):

- **Tier 1 — Flagship / Protected (14 repos, including `.github`):** Enforces active zero-bypass (`bypass_actors: []`) default-branch rulesets (`keep summer safe`) and `v*` release-tag protection (`release-tags`) via `scripts/sync-rulesets.sh`, requiring `hygiene / No machine-local paths` plus stack CI checks.
- **Tier 2 — Standard Active (38 repos):** Receives stack-matched Lefthook v2, `.editorconfig`, shared Agent Skills, and (where `actions_enabled: true`) `hygiene.yml` and non-blocking `ocr.yml`.
- **Tier 3 — Archive Candidates (9 repos):** Tracked in `fleet-manifest.json` (`archive_candidates`) for review and archival via `scripts/hygiene-backfill.sh`.
- **Forks (10 repos):** Excluded from `fleet-sync` PRs to keep upstream history clean. Pure reference forks (`opencode`, `openclaude`, `rea`, `open-code-review`, `heretek-control-core`) keep `actions_enabled: false`.

## 4. Reusable `OpenCodeReview` & Third-Party Scanner Policy

- **`OpenCodeReview` (`.github/workflows/ocr-review.yml`):** Non-blocking (`continue-on-error: true` with warning annotation) and automatically skips `chore/sync-org-standards` bot PRs unless manually invoked via `/open-code-review` or `@open-code-review`.
- **Required security/hygiene gates:** `hygiene.yml` (machine-local paths + `zizmor`) and local Lefthook v2 (`no-local-paths`, `gitleaks`, stack linters, `actionlint`, `zizmor`).
- **Third-party scanners (`CodeQL`, `SonarCloud`, `Sourcery`):** Kept non-blocking/advisory unless explicitly required in a Tier 1 repository's ruleset.

## 5. Automated Weekly Drift Detection

[`.github/workflows/org-drift-audit.yml`](../.github/workflows/org-drift-audit.yml) runs `scripts/audit_org.py` every Monday at 09:00 UTC (and on `workflow_dispatch`), reporting P0 security drift, untracked active repositories, unapproved per-repo secrets, missing Tier 1 rulesets, license/description gaps, and stalled sync PRs.

## 6. Optional Self-Hosted CI Runner (`stx-halo`)

Heavy CI workloads can opt into the Proxmox VE self-hosted runner (`stx-halo`, `rocm`, `gfx1151`) via [`.github/workflows/resolve-runner.yml`](../.github/workflows/resolve-runner.yml), which enforces a fork-PR trust gate and automatically falls back to `ubuntu-latest` when `stx-halo` is offline. See [`docs/self-hosted-runner-proxmox.md`](self-hosted-runner-proxmox.md) for host hardening and setup.
