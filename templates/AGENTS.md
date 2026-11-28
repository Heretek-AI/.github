# AGENTS.md

<!--
Write only what an agent cannot find by looking: the unwritten convention, the
reason behind a choice, the gotcha no config confesses. Leave one-command
lookups (package scripts, directory listings) to the repository itself.
Delete these comments, and any section with nothing to say.
-->

## Evidence

Back every claim about behavior with something executed or read: test output,
command output, a file and line. State what was not run.

## Agent Skills & Local Hooks

- Shared organization skills live in `.agents/skills/` (symlinked to `.opencode/skills/`, `.claude/skills/`, and `.github/skills/`):
  - `evidence-pr`: pre-PR verification and evidence formatting
  - `hygiene-and-workflow-audit`: machine-local path scan, `actionlint`, `zizmor`, and `SKILL.md` validation
  - `cross-repo-contract-check`: protocol and fixture verification across repositories
  - `adversarial-claim-check`: disposable worktree verification and invariant sabotage testing
  - `security-review`: structured threat-model-first security review
- Run `lefthook install` after cloning and `lefthook run pre-commit` before committing.

## Organization Standards (`Heretek-AI/.github`)

- **Actions SHA pinning:** Org enforces `sha_pinning_required: true`. Pin all third-party actions to full 40-char commit SHAs.
- **LLM configuration:** Use org-level `LLM_PROVIDER`, `LLM_BASE_URL`, `LLM_MODEL`, `LLM_OPENCODE_MODEL`, `LLM_PROTOCOL`, and `LLM_API_KEY` (never hardcode endpoints/models or add per-repo LLM secrets).
- **Optional self-hosted CI (`stx-halo`):** Heavy builds may opt in via `Heretek-AI/.github/.github/workflows/resolve-runner.yml` (enforces fork-PR trust gate + automatic fallback to `ubuntu-latest`). Never target `self-hosted` directly without the trust gate.
- **OpenCodeReview:** Provided via `Heretek-AI/.github/.github/workflows/ocr-review.yml` (non-blocking; invoke manually with `/open-code-review` on a PR comment).

## Canonical surfaces

<!--
One line per source of truth. Name each generated file and the command that
regenerates it.
-->

## Commands

<!--
Only commands with a gotcha: the one to use in place of the obvious one, the
one that spends money, the one that needs a secret.
-->

## Invariants

<!-- Each row names the test, gate or file that enforces it. -->

| Invariant | Where |
| --- | --- |
| No machine-local paths in tracked files | `lefthook.yml` (`no-local-paths`), `.github/workflows/hygiene.yml` |
| Workflow security (`zizmor` clean, SHA-pinned) | `.github/workflows/hygiene.yml` (`audit_workflows: true`) |

## Workflow

- Work on a topic branch and open a pull request. A maintainer merges and cuts releases.
- Stage explicit paths and commit with `--signoff` (`git commit -s`).
- After a push, check every workflow run (`gh pr checks --watch`).
- Write repo-relative paths in tracked files, and `owner/name` for another repository.
