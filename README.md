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
| [`docs/adr/`](docs/adr/) | Decisions that span repositories |
| [`templates/AGENTS.md`](templates/AGENTS.md) | Starting point for a new repository's agent guide |
| `labels.json`, `scripts/sync-labels.sh` | Shared label set |
| `.github/workflows/hygiene.yml` | Reusable check for machine-local paths |

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

### Labels

```sh
scripts/sync-labels.sh Heretek-AI/<repo> [Heretek-AI/<repo>...]
```

Creates each label in `labels.json` that the repository lacks. Existing labels keep their color and description, and nothing is deleted.
