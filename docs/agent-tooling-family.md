# Agent-tooling family

Five Heretek-AI repositories build tooling around coding-agent harnesses. They are separate projects ([ADR 0001](adr/0001-separate-repos-no-shared-sdk.md)). This page records what connects them, because no single repository shows it.

## Repositories

| Repository | What it is | Toolchain | Ships as |
| --- | --- | --- | --- |
| [IUMBTEMS](https://github.com/Heretek-AI/IUMBTEMS) | Epistemic Swarm: a gated build-factory plugin for OpenCode v2, with a CLI | Bun workspaces, Biome, TypeScript | npm `@heretek-ai/epistemic-swarm`, `es-core`, `es-cli`, released in lockstep |
| [claude-4-opencode](https://github.com/Heretek-AI/claude-4-opencode) | Loads Claude Code plugins and marketplaces into OpenCode v2 | Bun, Prettier, TypeScript | npm `@heretek-ai/claude-4-opencode` |
| [scraper-swarm](https://github.com/Heretek-AI/scraper-swarm) | Self-hosted search and scrape cluster behind a versioned MCP gateway | Python 3.12 (uv workspace), pnpm, Docker | A deployed service, versioned by git tag |
| [opencode-4-openclaude](https://github.com/Heretek-AI/opencode-4-openclaude) | Loopback gateway that lets OpenClaude use OpenCode Go models | Node, no dependencies | An OpenClaude plugin |
| [GDevelop-Unlocked](https://github.com/Heretek-AI/GDevelop-Unlocked) | Patch stack and AI studio overlay for the GDevelop editor | Node, no dependencies, `node:test` | Installers on GitHub Releases |

Each repository's `AGENTS.md` is the authority on its own rules.

## Connections

- **IUMBTEMS consumes scraper-swarm over a protocol only.** The contract is `POST /mcp`, contract version 1. scraper-swarm publishes golden fixtures under `contract/v1/fixtures/`, and IUMBTEMS vendors them at a recorded commit and tests its client (`packages/core/src/research/backends/scraper-swarm.ts`) against them. A breaking change needs a new contract version and notice on the consumer; the rules are in scraper-swarm's `contract/README.md`.
- **IUMBTEMS and claude-4-opencode both build on `@opencode/plugin` v2.** Each pins its own version and runs its own job against newer OpenCode releases, so the pins move independently. `package.json` in each repository is the source of truth.
- **No source is shared.** GDevelop-Unlocked and opencode-4-openclaude have no code-level tie to the others.

## Shared here

| File | Use |
| --- | --- |
| `SECURITY.md`, `CONTRIBUTING.md`, issue forms, pull request template | Defaults for any repository without its own |
| `labels.json`, `scripts/sync-labels.sh` | Label set common to the family |
| `templates/AGENTS.md` | Starting point for a new repository's agent guide |
| `.github/workflows/hygiene.yml` | Reusable check that keeps machine-local paths out of tracked files |

## Candidates for sharing

Two artifacts have, or are close to having, a second consumer. Each stays in its home repository and is published from there when the consumer is ready.

- IUMBTEMS `packages/testkit`: a mock OpenCode host and stub model, useful to any OpenCode v2 plugin.
- The scraper-swarm contract: fixtures plus a typed `/mcp` client, in place of vendored copies.
