# Audit Report: Fleet Rebase Verification (feat/fleet-sync-standardization onto origin/main)

- **Auditor:** agency-drift-guard (independent, read-only; no code changed)
- **Date (UTC):** 2026-10-21
- **Worktree:** `/home/john/Projects/.github-fleet-sync`
- **Branch:** `feat/fleet-sync-standardization` (local-only, NOT pushed)
- **Tip audited:** `8d33643` (+`95dd23c`) on base `b3afb81` (Merge PR #3 v2)
- **Status at audit:** `## feat/fleet-sync-standardization...origin/feat/fleet-sync-standardization [ahead 6, behind 2]`; tracked-dirty = 0; only untracked `?? docs/evidence/` + `?? docs/reports/`
- **Inputs read in full from disk:** `/home/john/Projects/.github/README.md`, `/home/john/Projects/.github/docs/organization-governance.md`, `/home/john/Projects/.github/docs/agent-tooling-family.md`, `/home/john/Projects/.github/docs/adr/0001-separate-repos-no-shared-sdk.md`, `/home/john/Projects/.github/templates/AGENTS.md`, `docs/reports/fleet-rebase-implementation.md`, `docs/evidence/fleet-rebase/qa-run.log`, `docs/evidence/fleet-rebase/red-proofs.log`

## 1. RULE 2 - Stub / shortcut hunt (assume broken until proven)

- `git grep -nIE '\|\| true|set \+e|test\.skip|TODO|FIXME|NotImplemented|echo (pass|PASS|ok)'` over tracked files: **no hits** (the only TODO-class grep hits are `mktemp -d -t heretek-*` template flags in `scripts/sync-fleet.sh:35` and `skills/adversarial-claim-check/SKILL.md:27` - XXXXXX template suffix, not a stub marker).
- `grep -rn '|| :' scripts/` -> none. No empty `catch` (no `catch` keyword in `scripts/`). No hardcoded pass verdicts, no `test.skip`, no missing-test shims (repo has no test suite; gates are `ci.yml` lint/validate/shellcheck jobs, all real).
- File modes: only `100644`/`100755`; all three `scripts/*.sh` are `100755` in the index. No unreferenced-module evidence: every fleet file (`fleet-manifest.json`, `labels.json`, `skills/*`, `templates/lefthook/*`, `templates/configs/*`, `fleet-sync.yml`, `audit.yml`, `actionlint.yaml`) is referenced by `README.md`, `fleet-sync.yml`, `ci.yml`, `lefthook.yml`, or `sync-fleet.sh`.
- Programmer claim "Zero stubs" **confirmed**.

## 2. RULE 3 - Spec & architecture audit

### 2.1 Zero-copy vs PR-synced separation (README S1 vs S2) - PASS
- `scripts/sync-fleet.sh` copies only: stack-matched `lefthook.yml`, canonical skills into `.agents/skills/`, `.github/actionlint.yaml`, and SHA-rewrites of `Heretek-AI/.github/.github/workflows/*` refs. It never touches `SECURITY.md`, `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/*`, or `pull_request_template.md`. Labels go via `sync-labels.sh --update` as specified. Zero-copy defaults remain untouched - separation holds.

### 2.2 32-repo profile mapping - PASS
- `jq '.repositories | length'` = **32**. Profile split: `bun-biome` 11, `python-uv` 1, `node-zerodep` 2, `universal` 18 - matches `README.md` S2 table and `qa-run.log` manifest counts exactly. `sync_branch` = `chore/sync-org-standards`, `organization` = `Heretek-AI`, `schema_version` = 1.

### 2.3 4-harness skill symlinks - PASS
- `sync-fleet.sh` copies each `skills/*/` into `$clone/.agents/skills/<name>` and ensures `ln -s ../.agents/skills` under `.opencode`, `.claude`, `.github` (guarded by `[ ! -e ... ] && [ ! -L ... ]`, idempotent, never clobbers). Covers OpenCode v2 + Claude Code + Copilot + canonical `.agents` = 4 discovery paths.

### 2.4 SHA-bump - PASS (with Nit N2)
- Rewriter targets `Heretek-AI/.github/.github/workflows/<wf>.yml@<40-hex>` -> `@$source_sha # main`. `ci.yml`, `ocr.yml`, `hygiene.yml`, `fleet-sync.yml` remote `uses:` are full 40-char SHA-pinned (`actions/checkout@11d5960a...`, `setup-uv@20cfd1bf...`, `github-script@60a0d830...`, `open-code-review@8eb83340...`). Local reusable refs use valid `./.github/workflows/...` form (see S2.7).

### 2.5 --signoff / org-sync PRs - PASS (with Nit N5)
- `sync-fleet.sh:117-119` commits with `commit --signoff -m "chore(org-sync): propagate ..."` and pushes `chore/sync-org-standards`; PR title `chore(org-sync): sync ...`, body cites source SHA/profile/validation, `--label "org-sync"` on create, idempotent edit-if-exists via `gh pr list --head/--base`. Matches spec S2 step 5.

### 2.6 ORG_SYNC_TOKEN dry-run fallback - PASS
- `fleet-sync.yml` `check-token` step: empty `ORG_SYNC_TOKEN` -> `dry_run=true` + `::notice::`; propagate step uses `GH_TOKEN: ${{ secrets.ORG_SYNC_TOKEN || secrets.GITHUB_TOKEN }}` but can only reach push paths when `dry_run=false`, which requires the secret to be set. Safe fallback, no privilege escalation. `README.md:49` documents least-privilege scopes (`Contents/Pull requests/Issues/Workflows: write`, `selected` to `.github`).

### 2.7 The two deliberate deviations - APPROVED (both tighten safety)
1. **`push --force-with-lease` restoration (`scripts/sync-fleet.sh:120`).** Precise grep `push --force($|[^-])` -> rc=1 (absent); `force-with-lease` present at line 120. The `0c7a840` regression (`push --force`) is gone repo-wide. The kept `0c7a840` addition (`gh auth setup-git` guard, lines 38-40) is correct: `gh repo clone` + `gh pr` need auth, and `setup-git` configures the credential helper without printing secrets.
2. **`$/.github/...` -> `./.github/...` (`ci.yml:13`, `ocr.yml:40`).** `$` is not a legal Actions owner; both were invalid-`uses` typos from `71540de`. Repo-wide `uses: \$` grep -> rc=1 (zero occurrences). V2 security substance preserved: `audit_workflows: true`, `pull_request` trigger set, explicit `OCR_LLM_TOKEN` forwarding, `ocr-review.yml` byte-identical to main (absent from the 12-file diff - programmer claim confirmed). The `$`-syntax rationale in `71540de`'s message has no basis (local `./` refs are exempt from zizmor pinning rules); the fix is correct.

### 2.8 Oct 2026 standards cross-check - all PASS
- **Skills spec** (name<->dir, `^[a-z0-9]+(-[a-z0-9]+)*$` <=64ch, description <=1024ch, <500 lines): `scripts/validate-skills.sh` enforces all four; `Validated 4 skill(s)` green.
- **Lefthook jobs + `stage_fixed`:** `stage_fixed: true` on biome-check, ruff-lint/format, taplo, shell-format; `parallel: true`, `min_version: 1.10.0` everywhere.
- **Biome/Ruff/ty/shfmt/shellcheck/actionlint/zizmor/gitleaks:** biome (bun-biome), ruff+taplo+ty (python-uv, `ty check` guarded), node `--check`+`jq` (node-zerodep), shfmt+shellcheck+gitleaks+actionlint+zizmor (root `lefthook.yml`, `hygiene.yml` pins `zizmor@1.30.1`).
- **Hygiene job name:** `hygiene.yml` jobs `No machine-local paths` + `Workflow syntax and security`.
- **Issue forms type/render/audit P0-P3:** `bug/task/epic/audit` carry `type:`; `render: shell` on repro/verify textareas; `audit.yml` has P0-P3 dropdown with `required: true` validations.
- **`blank_issues: false` + SECURITY link:** `config.yml` has `blank_issues_enabled: false`, Security Vulnerability Report -> `SECURITY.md` (+ new `security-contact.yml` fallback form, checkbox `required: true`, no-details guard text).
- **Labels bug/task/org-sync:** all present in `labels.json` with valid 6-hex colors; `jq` schema checks green in `ci.yml` and locally.

### 2.9 Rebase fidelity - PASS
- `95dd23c`: exactly as described - 1-line `ci.yml` `$`->`./` fix + two mode-only `100644`->`100755` flips (byte-identical blobs; `git show 95dd23c --stat` confirms 3 files, 1 insertion). Signoff trailer preserved.
- `8d33643` (amended `e18ef06`): 12-file diff `b3afb81..HEAD`, +49/-8 - matches observed `git diff --stat`. Nothing from either side dropped: all fleet additions present, all v2 zizmor/CI properties intact.
- Push correctly NOT performed (tip still local-only, `ahead 6, behind 2`).

## 3. RULE 4 - Independent verification (re-ran + own sabotage)

Green re-run (all in worktree, independent of QA logs): `jq` labels **true/0**, `jq` manifest **true/0**, `shellcheck` **0**, `bash -n` **0** on all three scripts, `validate-skills` **4 skills/0**, hygiene patterns **both rc=1** (clean), `$`-uses **rc=1** (absent), tracked-dirty **0**. (No `make check` in repo - used the mandated `jq/shellcheck/validate-skills/hygiene` fallback.)
- QA `qa-run.log` (13 green checks) and `red-proofs.log` (R1-R10) reviewed line-by-line: every sabotage shows a RED (non-zero / found) followed by `CLEAN` revert and green restore; final `tracked-dirty: 0`, `tip=8d33643`. One cosmetic imprecision noted (Nit N1); substance valid.
- **Independent sabotage 1 (validate-skills fail-closed):** renamed `skills/evidence-pr/SKILL.md` frontmatter `name:` -> `WRONG` -> validator exited **1** with `does not match directory` error (RED proven); restored from backup -> exit **0**, `Validated 4 skill(s)`.
- **Independent sabotage 2 (hygiene fail-closed):** appended `# see file:///home/john/secret` to `scripts/sync-labels.sh` -> hygiene grep exited **0** (found/RED at `scripts/sync-labels.sh:35`); restored -> exit **1** (clean).
- Post-restore `git status`: tracked-dirty **0**, only `?? docs/evidence/` + `?? docs/reports/` - cleanly restored, matching QA's claimed end-state.

## 4. Scope / drift / privilege / supply-chain / reversibility

- **Scope:** 12 files, all within the fleet-standardization brief. No out-of-scope source changes, no test-skip additions, no CI weakening (both workflow edits fix invalid syntax; no gates removed).
- **Drift:** No drift from spec intent or ADR 0001 (protocol-only boundaries untouched; `cross-repo-contract-check` edit only sharpens reference format to `Heretek-AI/<repo>#<number>` + `Heretek-AI/<repo>@<full-sha>`). `evidence-pr` staged-blob scan closes a real bypass (working-tree-only scans miss staged content); its fail-closed logic (`[ scan_status -eq 1 ] || exit`) verified by reading. `adversarial-claim-check` trap reorder (set trap before `worktree add`, `|| :` guard) is strictly more correct under `set -e`.
- **Privilege:** Fleet sync runs as `ORG_SYNC_TOKEN` (selected, scoped) with dry-run fallback; per-clone bot identity confined to throwaway clones; `--force-with-lease` confined to per-repo `chore/sync-org-standards` branches (never default branches); `gh auth setup-git` only when not dry-run. No over-broad token use found.
- **Supply-chain:** All remote actions SHA-pinned; `zizmor` version-pinned (`1.30.1`); `setup-uv` pinned; reusable-workflow SHA-bump mechanism intact; `actionlint.yaml` allowlists org config-vars. No unpinned `uses:` introduced.
- **Reversibility:** Fully reversible - rebased history is local-only (no force-push yet); downstream effects are per-repo idempotent PRs on a chore branch; `git checkout --` restores demonstrated twice (QA R1-R10 + this audit's two sabotages).

## 5. Nits (non-blocking, for programmer/maintainer)

- **N1 (log precision):** `red-proofs.log` R4 records `bash-n exit=2 (want 1)` - `bash -n` returns 2 on syntax error, so "want 1" is imprecise; RED (non-zero) was still correctly demonstrated. Suggest `want non-zero`.
- **N2 (comment overclaim):** `sync-fleet.sh` sed comment says `<40-hex-or-main>` but the regex only rewrites 40-hex refs; a downstream `@main` ref would not be bumped. No such ref observed in scope; suggest fixing comment or extending pattern.
- **N3 (fail-open resilience, intentional):** `sync-fleet.sh:56` swallows label-sync failure to `::warning::` and clone failure to `continue` - right call for 32-repo fan-out, but a silent label drift is possible; consider surfacing a job-summary count of skipped repos.
- **N4 (dead-pattern guard):** `for wf in .../*.{yml,yaml}` relies on `[ -f ... ] || continue` for the no-match case (correct today); `shopt -s nullglob` would be more idiomatic.
- **N5 (signoff):** `8d33643` (author `coderabbitai[bot]`) carries no `Signed-off-by` trailer while repo convention is `--signoff`. CI does not enforce it; maintainer should add signoff on merge/squash.

VERDICT: PASS
