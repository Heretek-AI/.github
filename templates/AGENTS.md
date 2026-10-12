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

## Workflow

- Work on a topic branch and open a pull request. A maintainer merges and cuts releases.
- Stage explicit paths.
- After a push, check every workflow run.
- Write repo-relative paths in tracked files, and `owner/name` for another repository.
