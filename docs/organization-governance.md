# Organization Governance, Hardening & CI Standardization

This document records the organization-wide security baselines, CI secret/variable conventions, zero-bypass branch rulesets, and repository lifecycle state for [`Heretek-AI`](https://github.com/Heretek-AI).

## 1. Organization Security & Actions Hardening

Enforced via `/orgs/Heretek-AI` and `/orgs/Heretek-AI/actions/permissions/workflow`:

| Setting | Value | Rationale |
| --- | --- | --- |
| `default_workflow_permissions` | `read` | Workflows receive read-only `GITHUB_TOKEN` permissions unless elevated per-job |
| `can_approve_pull_request_reviews` | `false` | Prevents GitHub Actions workflows from approving pull requests |
| `default_repository_permission` | `read` | Organization members default to read access unless granted team/repo roles |
| `members_can_create_repositories` | `false` | Restricts new repository creation to organization owners |
| `web_commit_signoff_required` | `true` | Requires DCO sign-off on web-based commits |
| `secret_scanning_enabled_for_new_repositories` | `true` | Automatically enables Secret Scanning on new repositories |
| `secret_scanning_push_protection_enabled_for_new_repositories` | `true` | Blocks pushes containing detected secrets on new repositories |
| `dependabot_alerts_enabled_for_new_repositories` | `true` | Enables vulnerability alerts without noisy auto-PRs |
| `dependabot_security_updates_enabled_for_new_repositories` | `false` | Disables automated Dependabot PR noise by default |

Organization Security Configuration `Heretek-AI-org-config-1` (`250992`) has `code_scanning_default_setup: "disabled"`, `dependabot_security_updates: "disabled"`, and `dependency_graph_autosubmit_action: "disabled"` so GitHub does not force-inject unrequested `CodeQL` or `Dependabot` workflows across repositories.

---

## 2. Standardized Organization Secrets & Variables

Per-repository secrets and per-repository variables are prohibited (`0` repositories have per-repo secrets or variables). All CI configuration is managed centrally at the organization level:

| Name | Type | Visibility | Value / Scope |
| --- | --- | --- | --- |
| `OPENCODE_MODEL` | Org Variable | `all` | `opencode/muse-spark-1.3-contributor` |
| `OPENCODE_API_KEY` | Org Secret | `selected` | Scoped to `IUMBTEMS`, `claude-4-opencode`, `awesome-opencode`, `Agent-Builder` |
| `OCR_LLM_URL` | Org Variable | `all` | `https://token-plan-sgp.xiaomimimo.com/v1` |
| `OCR_LLM_MODEL` | Org Variable | `all` | `mimo-v2.6-flash` |
| `OCR_LLM_USE_ANTHROPIC` | Org Variable | `all` | `false` |
| `OCR_LLM_TOKEN` | Org Secret | `all` | API token for `Heretek-AI/open-code-review` |

---

## 3. Zero-Bypass Default Branch Rulesets

The 7 protected repositories enforce active default-branch rulesets with **`bypass_actors: []`** (zero bypass, including organization owners), preventing branch deletion, force-pushes (`non_fast_forward`), and merges without passing required status checks:

| Repository | Ruleset ID | Ruleset Name | Required Status Checks (`github-actions`) |
| --- | --- | --- | --- |
| `.github` | `24901162` | `keep summer safe` | `hygiene / No machine-local paths`, `Labels and scripts` |
| `IUMBTEMS` | `24825429` | `keep summer safe` | `check`, `pack`, `hygiene / No machine-local paths` |
| `claude-4-opencode` | `24901159` | `keep summer safe` | `unit`, `opencode 2.0.26`, `hygiene / No machine-local paths` |
| `scraper-swarm` | `24901161` | `keep summer safe` | `Python Suite & Security Checks`, `Frontend Build & Plugin Tests`, `hygiene / No machine-local paths` |
| `opencode-4-openclaude` | `24901160` | `keep summer safe` | `test`, `hygiene / No machine-local paths` |
| `GDevelop-Unlocked` | `24861428` | `keep summer safe` | `tier1-smoke`, `byok-mock`, `hygiene / No machine-local paths` |
| `awesome-opencode` | `25310603` | `main: every commit passes validate` | `validate` |

---

## 4. Reusable `OpenCodeReview` Rollout

All **29 active workflow-enabled repositories** include `.github/workflows/ocr.yml`, which calls `.github/workflows/ocr-review.yml` in `Heretek-AI/.github` (SHA-pinned to `Heretek-AI/open-code-review@8eb83340a487b1150af00701b94f01af97e4b4d6` and `actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5`):
- Triggers automatically on `pull_request` (`opened`, `synchronize`, `reopened`) and on `@ocr` comments (`issue_comment`) by `OWNER`, `MEMBER`, or `COLLABORATOR` actors.

---

## 5. Repository & Package Lifecycle Summary

- **33 Active First-Party Repositories**:
  - **29 with GitHub Actions Enabled (`ocr.yml` active)**: `.github`, `IUMBTEMS`, `claude-4-opencode`, `scraper-swarm`, `opencode-4-openclaude`, `GDevelop-Unlocked`, `awesome-opencode`, `Agent-Builder`, `awesome-harness`, `Token-Max`, `heretek-rigs`, `Heretek-Crew`, `heretek-context-router`, `epistemic-factory`, `agency-control-plane`, `The-Agency`, `SwarmOS`, `heretek-devcontainers`, `oh-mine-pi`, `arcane-repo`, `Game-Studio`, `opencode-harness`, `opencode-v2-plugin-teser`, `opencode-rea`, `opencode-searxng-plugin`, `godot-opencode`, `unity.gamedev.kit`, `homebrew-tap`, `ompweb-docker`
  - **4 Workflow-less Repositories (`actions_enabled: false`)**: `heretek-skills`, `virt-box`, `optimized-prompts`, `free-git`
- **6 Unarchived Reference Forks (`actions_enabled: false`)**:
  `opencode`, `openclaude`, `rea`, `open-code-review`, `openrig`, `heretek-control-core`
- **66 Archived Legacy Repositories (`isArchived: true`, `actions_enabled: false`)**:
  All superseded forks, pre-September 20 prototypes, and retired builders have Actions disabled and per-repo secrets purged.
- **Package Registries**:
  - **Active GHCR Containers (3)**: `ompweb-docker`, `heretek-crew`, `oh-mine-pi` (32 legacy containers deleted).
  - **Active npm Packages**: `@heretek-ai/epistemic-swarm`, `es-core`, `es-cli`, `@heretek-ai/claude-4-opencode`, `@heretek-ai/opencode-rea`, `@heretek-ai/opencode-searxng-plugin`, `@heretek-ai/token-max` (17 legacy npm packages marked `deprecated` on `registry.npmjs.org`).
