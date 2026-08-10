# Agent Instructions

> **Scope:** these are instructions for **development agents** working *on* this
> repository (e.g. Claude Code) — how to build, lint, and validate it. They are
> not instructions for the coding agent running inside the `sbxclaude` sandbox.

## Repository Map

- `sbxclaude/spec.yaml` — the Docker Sandbox Kit spec: agent, resources,
  network policy, and setup commands baked into the sandbox.
- `sbxclaude/files/` — files copied into the sandbox at kit-build time.
- `scripts/sbxclaude` — wrapper CLI around `sbx` that creates, rebuilds, and
  re-attaches the per-project sandbox. Run `./scripts/sbxclaude -h` for the
  current command list rather than relying on this doc, which won't track it.

## Commands

```bash
make lint           # markdownlint, jq, yamllint, shellcheck, bash -n, cspell
make test           # run all tests
make test-unit      # test wrapper dispatch with a fake sbx CLI
make test-toolchain # test helper tools inside the live sandbox
make validate       # validate against the current Docker Sandbox Kit schema
```

`make lint` is the single source of truth for linting — CI runs the same
target. Add a new check there, not as a separate command, so it can't drift.
Unknown-but-correct words go in `.cspell.json`.

## Critical Requirement

Before finishing any task that touches `sbxclaude/spec.yaml` or
`sbxclaude/files/`, run `make validate` — it's a static schema check with
no Docker, no `sbx login`, and no network, so there's no reason to skip it.
Before finishing any task that touches `scripts/sbxclaude` or any other shell
script, run `make lint` — it runs `shellcheck` and `bash -n` over every
tracked script.

## Changelog

- Maintain `CHANGELOG.md` using Keep a Changelog and Semantic Versioning.
- Add notable user-facing changes under `## [Unreleased]`, grouped under
  `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`.
- Skip entries for tests, formatting, internal refactors, and documentation
  changes that do not affect users.
- For a release, move the relevant entries to `## [X.Y.Z] - YYYY-MM-DD`.

## Skills

- `context7-docs` — fetch current library/framework docs before writing code
  against one.
- `debug-third-party` — check for a known upstream bug before working around
  an error that looks like it's from a dependency.
