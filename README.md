# Heretek-AI/.github

Organization-wide defaults, and the shared conventions of the agent-tooling repositories.

## Applies to every repository in the organization

GitHub uses these files for any Heretek-AI repository that lacks its own copy:

- `SECURITY.md` and `CONTRIBUTING.md`
- `.github/ISSUE_TEMPLATE/` (bug, task, epic)
- `.github/pull_request_template.md`

A repository opts out of one by committing its own file at the same path. Any file in a repository's own `.github/ISSUE_TEMPLATE/` replaces the whole default set of issue forms.

## Used by the agent-tooling repositories

| Path | Purpose |
| --- | --- |
| [`docs/agent-tooling-family.md`](docs/agent-tooling-family.md) | The five repositories and what connects them |
| [`docs/organization-governance.md`](docs/organization-governance.md) | Organization hardening, rulesets, secrets/variables, and repository inventory |
| [`docs/adr/`](docs/adr/) | Decisions that span repositories |
| [`templates/AGENTS.md`](templates/AGENTS.md) | Starting point for a new repository's agent guide |
| `labels.json`, `scripts/sync-labels.sh` | Shared label set |
| `.github/workflows/hygiene.yml` | Reusable check for machine-local paths |
| `.github/workflows/ocr-review.yml` | Reusable OpenCodeReview PR review workflow |

### Hygiene check

Fails when a tracked file contains a `file://` URI or an absolute path into a home directory.

```yaml
jobs:
  hygiene:
    uses: Heretek-AI/.github/.github/workflows/hygiene.yml@<commit sha> # main
    with:
      exclude: |
        path/to/recorded-evidence
```

Pin the workflow to a commit of this repository; code scanning flags a branch reference. `exclude` is optional: one repo-relative path per line, for files that must stay byte-identical, such as recorded evidence.

### OpenCodeReview (`ocr-review.yml`)

Runs [`Heretek-AI/open-code-review`](https://github.com/Heretek-AI/open-code-review) on pull requests (`pull_request`) and `@ocr` maintainer comments (`issue_comment`) across all 29 active workflow-enabled repositories using organization-level variables (`OCR_LLM_URL`, `OCR_LLM_MODEL`, `OCR_LLM_USE_ANTHROPIC`) and the `OCR_LLM_TOKEN` organization secret:

```yaml
jobs:
  ocr:
    uses: Heretek-AI/.github/.github/workflows/ocr-review.yml@main
    with:
      llm_url: ${{ vars.OCR_LLM_URL || 'https://token-plan-sgp.xiaomimimo.com/v1' }}
      llm_model: ${{ vars.OCR_LLM_MODEL || 'mimo-v2.6-flash' }}
      use_anthropic: ${{ vars.OCR_LLM_USE_ANTHROPIC == 'true' }}
    secrets:
      OCR_LLM_TOKEN: ${{ secrets.OCR_LLM_TOKEN }}
```

### Standardized Organization Secrets & Variables

| Name | Kind | Visibility | Purpose |
| --- | --- | --- | --- |
| `OPENCODE_MODEL` | Org Variable | `all` | Default model for OpenCode live evals and AI review (`opencode/muse-spark-1.3-contributor`) |
| `OPENCODE_API_KEY` | Org Secret | `selected` | OpenCode API key for live evals and AI review (`IUMBTEMS`, `claude-4-opencode`, `awesome-opencode`, `Agent-Builder`) |
| `OCR_LLM_URL` | Org Variable | `all` | OpenCodeReview LLM endpoint (`https://token-plan-sgp.xiaomimimo.com/v1`) |
| `OCR_LLM_MODEL` | Org Variable | `all` | OpenCodeReview model (`mimo-v2.6-flash`) |
| `OCR_LLM_USE_ANTHROPIC` | Org Variable | `all` | OpenCodeReview protocol toggle (`false` for OpenAI-compatible) |
| `OCR_LLM_TOKEN` | Org Secret | `all` | OpenCodeReview API token |

### Labels

```sh
scripts/sync-labels.sh Heretek-AI/<repo> [Heretek-AI/<repo>...]
```

Creates each label in `labels.json` that the repository lacks. Existing labels keep their color and description, and nothing is deleted.
