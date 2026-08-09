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
  current flag list rather than relying on this doc, which won't track it.

## Commands

```bash
make validate-kit   # validate against the current Docker Sandbox Kit schema
shellcheck --enable=all scripts/sbxclaude   # lint the wrapper script
bash -n scripts/sbxclaude                   # syntax-check the wrapper script
cspell "**/*.md" "scripts/**" "sbxclaude/**/*.yaml"   # spell-check
```

## Critical Requirement

Before finishing any task that touches `sbxclaude/spec.yaml` or
`sbxclaude/files/`, run `make validate-kit` — it's a static schema check with
no Docker, no `sbx login`, and no network, so there's no reason to skip it.
Before finishing any task that touches `scripts/sbxclaude`, run both
`shellcheck --enable=all` and `bash -n` on it.

## Skills

- `context7-docs` — fetch current library/framework docs before writing code
  against one.
- `debug-third-party` — check for a known upstream bug before working around
  an error that looks like it's from a dependency.
