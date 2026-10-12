# Separate repositories, no shared plugin SDK

The five agent-tooling repositories (IUMBTEMS, claude-4-opencode, scraper-swarm, opencode-4-openclaude, GDevelop-Unlocked) stay separate projects inside the Heretek-AI organization, and no shared SDK package is extracted from them. An October 2026 proposal recommended a new organization with a shared core and SDK monorepo. An audit of all five repositories found that every module the proposal would share has exactly one consumer, so the move would relocate code without removing any duplication.

**Considered options.**
- *New organization with a shared SDK monorepo and split repositories.* Rejected. The sandbox, keystore and LSP supervisor exist only in IUMBTEMS, Responses-API translation exists only in opencode-4-openclaude, and GDevelop-Unlocked contains none of the proposed core. IUMBTEMS already chose one repository (its ADR 0001) and gates its core's runtime dependencies to an allowlist, which an external core package would break. The toolchains (Bun, Python with pnpm, and two zero-dependency Node repositories, one of them byte-pinned) do not fit one workspace.
- *New organization, repositories transferred unchanged.* Rejected. It buys a cleaner namespace and costs rebinding npm trusted publishing and reinstalling every GitHub App.
- *Stay and standardize.* Chosen. Shared conventions live in this repository; code stays where it is.

**Consequences.**
- Conventions are shared as files here: default health files, a label set, an `AGENTS.md` template and one reusable workflow. Each repository keeps its own CI.
- Repositories integrate over a versioned protocol, as IUMBTEMS and scraper-swarm do, and never import each other's source.
- A helper needed by two repositories is copied until a trigger below is met. Two small copies cost less than a package with its own release cadence.
- New work that needs a different toolchain from its host starts as a new repository. Work that fits the host's toolchain stays in it.

**Revisit when**
- a module gains a second real consumer in another repository, and both are ready to depend on a published package;
- three repositories need the same fix for the same OpenCode plugin API change;
- a component gains an outside community that needs its own tracker or permissions.
