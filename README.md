# Heretek-AI/.github

Organization-wide defaults, shared Agent Skills, polyglot Lefthook v2 configurations, and automated fleet PR synchronization for `Heretek-AI`.

## 1. Inherited Automatically Across Every Repository (Zero Copy)

GitHub automatically applies these files to any `Heretek-AI` repository that does not commit its own override at the same path:

- `SECURITY.md` and `CONTRIBUTING.md`
- `.github/ISSUE_TEMPLATE/` (`bug.yml`, `task.yml`, `epic.yml`, `audit.yml`, `security-contact.yml`, and `config.yml`)
- `.github/pull_request_template.md`

> **Important:** Do not copy `.github/ISSUE_TEMPLATE/*` into child repositories unless a repository needs to replace the entire default set of issue forms.

## 2. Automated Fleet PR Synchronization (`fleet-sync.yml`)

Every push to `main` that modifies `fleet-manifest.json`, `labels.json`, `skills/**`, `templates/**`, `.github/actionlint.yaml`, or reusable workflows triggers [`.github/workflows/fleet-sync.yml`](.github/workflows/fleet-sync.yml) (`scripts/sync-fleet.sh`), which:

1. Syncs `labels.json` across all 32 downstream repositories via `scripts/sync-labels.sh --update`.
2. Copies the repository's stack-matched Lefthook v2 config (`templates/lefthook/<profile>.yml` -> `lefthook.yml`).
3. Syncs the four canonical Agent Skills (`skills/*` -> `.agents/skills/*`) with cross-harness symlinks for OpenCode v2 (`.opencode/skills`), Claude Code (`.claude/skills`), and GitHub Copilot (`.github/skills`).
4. Rewrites `Heretek-AI/.github/.github/workflows/<name>.yml@<sha>` references in downstream `.github/workflows/*.yml` files to the new `Heretek-AI/.github` commit SHA.
5. Opens or updates a single idempotent, DCO-signed pull request (`chore/sync-org-standards`) per repository.

### Stack Profiles (`fleet-manifest.json`)

| Profile | Target Repositories | Pre-Commit & Pre-Push Gates |
| --- | --- | --- |
| `bun-biome` | `IUMBTEMS`, `claude-4-opencode`, `Agent-Builder`, `Token-Max`, `heretek-context-router`, `epistemic-factory`, `agency-control-plane`, `opencode-harness`, `opencode-v2-plugin-teser`, `opencode-rea`, `opencode-searxng-plugin` | Local-path check, `gitleaks`, `biome check --write`, `shellcheck`, `actionlint`, `zizmor`, `bun test` |
| `python-uv` | `scraper-swarm` | Local-path check, `gitleaks`, `ruff check --fix`, `ruff format`, `taplo`, `shellcheck`, `actionlint`, `zizmor`, `uv lock --check`, `ty check` |
| `node-zerodep` | `opencode-4-openclaude`, `GDevelop-Unlocked` | Local-path check, `gitleaks`, `node --check`, `jq`, `shellcheck`, `actionlint`, `zizmor`, `node --test` |
| `universal` | `awesome-opencode`, `heretek-skills`, and 16 other active repositories | Local-path check, `gitleaks`, `jq`, `shellcheck`, `actionlint`, `zizmor` |

## 3. Shared Agent Skills (`skills/`)

Conforms to the [Agent Skills Open Specification](https://agentskills.io/specification) and [OpenCode v2 Agent Skills](https://opencode.ai/docs/skills/):

| Skill | Trigger & Purpose |
| --- | --- |
| [`skills/evidence-pr/SKILL.md`](skills/evidence-pr/SKILL.md) | Runs `lefthook run pre-commit`, captures verbatim command evidence for PR descriptions, and watches status checks |
| [`skills/hygiene-and-workflow-audit/SKILL.md`](skills/hygiene-and-workflow-audit/SKILL.md) | Scans tracked files for machine-local paths and audits `.github/workflows/` with `actionlint` and `zizmor` |
| [`skills/cross-repo-contract-check/SKILL.md`](skills/cross-repo-contract-check/SKILL.md) | Enforces ADR 0001 protocol-only boundaries and golden fixture verification across `scraper-swarm` and `IUMBTEMS` |
| [`skills/adversarial-claim-check/SKILL.md`](skills/adversarial-claim-check/SKILL.md) | Runs pre-release artifact checks and invariant sabotage tests inside a disposable `git worktree` |

## 4. Standardized Organization Secrets & Variables

| Name | Kind | Visibility | Purpose |
| --- | --- | --- | --- |
| `ORG_SYNC_TOKEN` | Org Secret | `selected` (`.github`) | Fine-grained token or GitHub App installation token (`Contents: write`, `Pull requests: write`, `Issues: write`, `Workflows: write`) used by `fleet-sync.yml` |
| `OPENCODE_MODEL` | Org Variable | `all` | Default model for OpenCode live evals and AI review (`opencode/muse-spark-1.3-contributor`) |
| `OPENCODE_API_KEY` | Org Secret | `selected` | OpenCode API key for live evals and AI review (`IUMBTEMS`, `claude-4-opencode`, `awesome-opencode`, `Agent-Builder`) |
| `OCR_LLM_URL` | Org Variable | `all` | OpenCodeReview LLM endpoint (`https://token-plan-sgp.xiaomimimo.com/v1`) |
| `OCR_LLM_MODEL` | Org Variable | `all` | OpenCodeReview model (`mimo-v2.6-flash`) |
| `OCR_LLM_USE_ANTHROPIC` | Org Variable | `all` | OpenCodeReview protocol toggle (`false` for OpenAI-compatible) |
| `OCR_LLM_TOKEN` | Org Secret | `all` | OpenCodeReview API token |
