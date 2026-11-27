# AGENTS.md

Canonical agent instructions for `Heretek-AI/.github` (the organization control plane for `Heretek-AI`).

## Canonical Surfaces

| Surface | Source of Truth | Validation / Sync Command |
| --- | --- | --- |
| Active fleet inventory & tiers | `fleet-manifest.json` (`schema_version: 2`) | `jq empty fleet-manifest.json && python3 scripts/audit_org.py` |
| Organization labels | `labels.json` | `bash scripts/sync-labels.sh --update <owner/repo>` |
| Unified LLM provider profiles | `llm-profiles.json` | `bash scripts/set-llm-profile.sh <profile>` |
| Reusable workflows | `.github/workflows/{hygiene,ocr-review,resolve-runner,security-scan,code-quality,secfoo-audit}.yml` | `uvx "zizmor@1.30.1" --format=plain .` |
| Shared Agent Skills | `skills/*/SKILL.md` | `bash scripts/validate-skills.sh` |
| Lefthook v2 stack profiles | `templates/lefthook/*.yml` | Synced to fleet via `scripts/sync-fleet.sh` |
| Tier 1 branch & tag rulesets | `templates/rulesets/tier1-{main,tags}.json` | `bash scripts/sync-rulesets.sh [--dry-run]` |
| Org security baseline | `scripts/harden-org.sh` | `bash scripts/harden-org.sh [--dry-run]` |
| Proxmox self-hosted runner | `docs/self-hosted-runner-proxmox.md` | Optional caller: `.github/workflows/resolve-runner.yml` |

## Commands & Gotchas

- **Self-repository workflow calls:** Use GitHub's `$/...` syntax (`uses: $/.github/workflows/hygiene.yml`), NOT `./...` — `zizmor@1.30.1` enforces `$/...` in CI.
- **Action SHA pinning:** `sha_pinning_required: true` is enforced at the org level. Always pin third-party actions to full 40-char commit SHAs (Dependabot bumps them weekly with a 7-day cooldown).
- **Shallow-clone fleet sync:** `scripts/sync-fleet.sh` uses `--force-with-lease="$sync_branch:$remote_sha"` via `git ls-remote`; never revert to bare `--force-with-lease` on `--depth=1` clones.
- **Switching org LLM provider/model:** Run `bash scripts/set-llm-profile.sh <profile>` (or trigger `.github/workflows/set-llm-profile.yml`). It updates canonical `LLM_*` org vars and mirrors legacy `OCR_LLM_*` / `OPENCODE_MODEL` vars atomically. Never hardcode LLM endpoints or model IDs in workflows.
- **Never commit secrets or local state:** `.opencode/`, `__pycache__/`, and `drift-report.md` are gitignored; always stage explicit paths.

## Invariants

| Invariant | Enforced By |
| --- | --- |
| No machine-local paths in tracked files | `lefthook.yml`, `.github/workflows/hygiene.yml` |
| Zero `zizmor` findings across all workflows & Dependabot | `.github/workflows/hygiene.yml` (`audit_workflows: true`) |
| Valid `fleet-manifest.json` v2, `labels.json`, `llm-profiles.json`, `SKILL.md`, and `scripts/*.sh` | `.github/workflows/ci.yml` (`Labels and scripts`) |
| Zero-bypass `main` branch protection on `.github` | Ruleset `keep summer safe` (`bypass_actors: []`) |
| Non-blocking `OpenCodeReview` (skips `chore/sync-org-standards` PRs) | `.github/workflows/ocr-review.yml` (`continue-on-error: true`) |
| Fork PRs never execute on self-hosted `stx-halo` runner | `.github/workflows/resolve-runner.yml` trust gate + org `all_external_contributors` approval |
| Weekly governance drift visibility | `.github/workflows/org-drift-audit.yml` (`scripts/audit_org.py`) |

## Workflow

- Always work on a topic branch and open a pull request — `main` enforces zero-bypass required checks (`hygiene / No machine-local paths` and `Labels and scripts`).
- Commit with DCO sign-off (`git commit --signoff`).
- Run `uvx "zizmor@1.30.1" --format=plain .`, `shellcheck scripts/*.sh`, `python3 -m py_compile scripts/*.py`, and `bash scripts/validate-skills.sh` before pushing.
- Include verbatim command evidence in every PR description and watch checks (`gh pr checks --watch`) before merging.
