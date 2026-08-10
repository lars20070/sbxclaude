# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- In-sandbox `sbx` CLI (latest release, architecture-matched) for daemon-free
  kit commands (`version`, `kit validate`, `kit inspect`, `kit pack`).
- Initial Docker Sandbox Kit for running Claude Code with 8 CPUs, 24 GB of
  memory, Docker, passwordless `sudo`, and the host project mounted as the
  workspace.
- `sbxclaude` wrapper with per-project sandbox naming and commands to attach,
  create, remove, inspect, execute commands, validate the kit, and inspect
  network policy.
- Interactive and piped command execution with appropriate TTY and stdin
  handling.
- Pre-installed `jq`, `ripgrep`, and `ruff` tooling.
- Installation, usage, shell-access, rebuild, and direct-`sbx` documentation.

### Security

- Claude Code runs without `--dangerously-skip-permissions`.
- Network access is default-deny with an explicit host allowlist.
- Sandbox removal retains `sbx` confirmation, and invalid wrapper commands fail
  before invoking `sbx`.
