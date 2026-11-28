# Heretek-AI/.github

Organization-wide defaults, public org profile (`profile/README.md`), shared Agent Skills, polyglot Lefthook v2 configurations, reusable CI/security workflows, drift auditing, and automated fleet PR synchronization for `Heretek-AI`.

## 1. Inherited Automatically Across Every Repository (Zero Copy)

GitHub automatically applies these files to any `Heretek-AI` repository that does not commit its own override at the same path:

- `profile/README.md` (organization landing page)
- `SECURITY.md` and `CONTRIBUTING.md`
- `.github/ISSUE_TEMPLATE/` (`bug.yml`, `task.yml`, `epic.yml`, `audit.yml`, `security-contact.yml`, and `config.yml`)
- `.github/pull_request_template.md`

> **Important:** Do not copy `.github/ISSUE_TEMPLATE/*` into child repositories unless a repository needs to replace the entire default set of issue forms.

## 2. Automated Fleet PR Synchronization (`fleet-sync.yml`)

Every push to `main` that modifies `fleet-manifest.json`, `labels.json`, `skills/**`, `templates/**`, `.github/actionlint.yaml`, or reusable workflows triggers [`.github/workflows/fleet-sync.yml`](.github/workflows/fleet-sync.yml) (`scripts/sync-fleet.sh`), which:

1. Syncs `labels.json` across all managed Tier 1 and Tier 2 repositories via `scripts/sync-labels.sh --update`.
2. Copies the repository's stack-matched Lefthook v2 config (`templates/lefthook/<profile>.yml` -> `lefthook.yml`) and seeds `.editorconfig` if absent.
3. Syncs the five canonical Agent Skills (`skills/*` -> `.agents/skills/*`) with cross-harness symlinks for OpenCode v2 (`.opencode/skills`), Claude Code (`.claude/skills`), and GitHub Copilot (`.github/skills`).
4. For workflow-enabled repos, syncs `.github/actionlint.yaml`, bootstraps `hygiene.yml` / `ocr.yml` callers if absent, rewrites `Heretek-AI/.github/.github/workflows/<name>.yml@<sha>` references to the new `Heretek-AI/.github` commit SHA, and pins third-party `uses:` tags to full 40-char commit SHAs (the org enforces `sha_pinning_required`).
5. Opens or updates a single idempotent, DCO-signed pull request (`chore/sync-org-standards`) per repository.

### Stack Profiles (`fleet-manifest.json` v2)

| Profile | Pre-Commit & Pre-Push Gates |
| --- | --- |
| `bun-biome` | Local-path check, `gitleaks`, `biome check --write`, `shellcheck`, `actionlint`, `zizmor`, `bun test` |
| `python-uv` | Local-path check, `gitleaks`, `ruff check --fix`, `ruff format`, `taplo`, `shellcheck`, `actionlint`, `zizmor`, `uv lock --check`, `ty check` |
| `node-zerodep` | Local-path check, `gitleaks`, `node --check`, `jq`, `shellcheck`, `actionlint`, `zizmor`, `node --test` |
| `rust-cargo` | Local-path check, `gitleaks`, `cargo fmt --check`, `shellcheck`, `actionlint`, `zizmor`, `cargo clippy`, `cargo test` |
| `cpp-cmake` | Local-path check, `gitleaks`, `clang-format --dry-run --Werror`, `shellcheck`, `actionlint`, `zizmor` |
| `godot-gdscript` | Local-path check, `gitleaks`, `gdlint`, `gdformat --check`, `shellcheck`, `actionlint`, `zizmor` |
| `universal` | Local-path check, `gitleaks`, `jq`, `shellcheck`, `actionlint`, `zizmor` |

## 3. Governance Automation Scripts

| Script | Purpose |
| --- | --- |
| `scripts/harden-org.sh` | Enforces the org security/Actions baseline, the Actions selected allowlist (`org-actions-allowlist.json`), the OIDC `sub` claim, the fleet code-security configuration, self-hosted runner scoping, and secret scoping |
| `scripts/audit_org.py` | Weekly/on-demand governance drift auditor (`.github/workflows/org-drift-audit.yml`) |
| `scripts/sync-fleet.sh` | Propagates labels, Lefthook v2, `.editorconfig`, Agent Skills, and reusable workflow pins, and pins third-party actions to full 40-char SHAs (`--dry-run`, `--repo`, `--tier`) |
| `scripts/sync-rulesets.sh` | Reconciles existing Tier 1 default-branch and release-tag rulesets to zero-bypass, PR-only settings, adding the hygiene check only where the reusable workflow is invoked |
| `scripts/sync-custom-properties.sh` | Defines and applies the `tier`, `stack_profile`, `security_critical`, and `managed_by` org custom properties from `fleet-manifest.json` |
| `scripts/sync-repo-settings.sh` | Applies merge/sign-off defaults, Dependabot security updates and PVR on public repos, and immutable releases on Tier 1 repos plus `.github` |
| `scripts/hygiene-backfill.sh` | Dry-run helper for reference fork Actions-off enforcement and Tier 3 archiving |
| `scripts/set-llm-profile.sh` | 1-command switcher for org-wide `LLM_*` variables + legacy `OCR_LLM_*`/`OPENCODE_MODEL` mirrors from `llm-profiles.json` |

## 4. Shared Agent Skills (`skills/`)

Conforms to the [Agent Skills Open Specification](https://agentskills.io/specification) and [OpenCode v2 Agent Skills](https://opencode.ai/docs/skills/):

| Skill | Trigger & Purpose |
| --- | --- |
| [`skills/evidence-pr/SKILL.md`](skills/evidence-pr/SKILL.md) | Runs `lefthook run pre-commit`, captures verbatim command evidence for PR descriptions, and watches status checks |
| [`skills/hygiene-and-workflow-audit/SKILL.md`](skills/hygiene-and-workflow-audit/SKILL.md) | Scans tracked files for machine-local paths and audits `.github/workflows/` with `actionlint` and `zizmor` |
| [`skills/cross-repo-contract-check/SKILL.md`](skills/cross-repo-contract-check/SKILL.md) | Enforces ADR 0001 protocol-only boundaries and golden fixture verification across `scraper-swarm` and `IUMBTEMS` |
| [`skills/adversarial-claim-check/SKILL.md`](skills/adversarial-claim-check/SKILL.md) | Runs pre-release artifact checks and invariant sabotage tests inside a disposable `git worktree` |
| [`skills/security-review/SKILL.md`](skills/security-review/SKILL.md) | Runs a structured threat-model-first security review (attack-surface mapping, sink/source tracing, verified findings, minimal safe patch) |

## 5. Organization Hardening Controls

- **Actions allowlist:** `allowed_actions=selected` with `sha_pinning_required=true`; `org-actions-allowlist.json` allows GitHub-owned and verified-creator actions plus an explicit pattern list, applied by `scripts/harden-org.sh` and drift-checked by `scripts/audit_org.py`.
- **PR-only rulesets:** Tier 1 repositories and `.github` carry zero-bypass (`bypass_actors: []`), PR-required `main` rulesets plus protected release tags; `scripts/sync-rulesets.sh` reconciles drift in existing rulesets.
- **Fork-PR approval:** `all_external_contributors`, with private-repo fork workflow runs requiring approval and no secrets/variables or write tokens sent to fork PRs.
- **Secret scanning and PVR:** Push protection, non-provider patterns, validity checks, and private vulnerability reporting are enabled on active public repositories through the fleet code-security configuration.
- **Immutable releases:** Enabled on Tier 1 repositories and `.github` by `scripts/sync-repo-settings.sh`.
- **Custom properties:** `tier`, `stack_profile`, `security_critical`, and `managed_by` are defined from `fleet-manifest.json` by `scripts/sync-custom-properties.sh`.
- **Runner scoping:** The org self-hosted runner policy and the Default runner group are limited to the `self_hosted_runner: true` opt-ins (`GDevelop-Unlocked`, `TAT-2`, `homebrew-tap`, `game-engine`); `resolve-runner.yml` remains the only supported entry point.
- **Fleet code-security baseline:** `Heretek-AI fleet baseline` attaches secret scanning, PVR, and Dependabot to active public repos plus `.github`; CodeQL default setup is deliberately `not_set` so advanced CodeQL workflows are not overridden.

## 6. Standardized Organization Secrets & Variables

Canonical target state; the full variable list is documented in [`docs/organization-governance.md`](docs/organization-governance.md).

| Name | Kind | Visibility | Purpose |
| --- | --- | --- | --- |
| `ORG_SYNC_TOKEN` | Org Secret | `selected` (`.github` only) | Token used by `fleet-sync.yml` and `org-drift-audit.yml` |
| `LLM_API_KEY` | Org Secret | `selected` (active managed repos + `.github`) | Canonical active LLM API key (mirrored to `OCR_LLM_TOKEN`) |
| `OCR_LLM_TOKEN` | Org Secret | `selected` (active managed repos + `.github`) | OpenCodeReview API token |
| `OPENROUTER_API_KEY` | Org Secret | `selected` (active managed repos + `.github`) | OpenRouter key for the `openrouter-ernie-free` profile |
| `OPENCODE_GO_API_KEY` | Org Secret | `selected` (active managed repos + `.github`) | OpenCode Go inference token for the `opencode-muse-spark` profile |
| `RUNNER_PROBE_TOKEN` | Org Secret | `selected` (active managed repos + `.github`) | Minimal read-only token (`Organization self-hosted runners: read`) for optional `resolve-runner.yml` fallback |
| `LLM_*` org variables | Org Variable | `all` | Canonical provider/base URL/model/protocol set written by `scripts/set-llm-profile.sh` |

> **Removed:** `OPENCODE_API_KEY` is stale and must be deleted (`scripts/harden-org.sh --prune`). Secret visibility moved from `all` to `selected`, so the exact repository list can only be synced after a one-time UI re-scope.
