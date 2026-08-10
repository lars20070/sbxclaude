# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial Docker Sandbox Kit for running Claude Code with 8 CPUs, 24 GB of
  memory, Docker, passwordless `sudo`, and the host project mounted as the
  workspace.
- `sbxclaude` wrapper with per-project sandbox naming and commands to attach,
  create, remove, inspect, execute commands, validate the kit, and inspect
  network policy.
- Interactive and piped command execution with appropriate TTY and stdin
  handling.
- Pre-installed `jq`, `ripgrep`, `curl`, Python 3, ShellCheck, Ruff,
  yamllint, markdownlint-cli2, and CSpell tooling.
- In-sandbox `sbx` CLI (latest release, architecture-matched) for daemon-free
  kit commands (`version`, `kit validate`, `kit inspect`, `kit pack`), so the
  kit can be validated from inside the sandbox.
- Agent instructions covering the sandbox environment, the limits of the
  in-sandbox `sbx`, and the pre-installed toolchain.
- ELI5 output style, available to Claude Code inside the sandbox.
- Installation, usage, shell-access, rebuild, and direct-`sbx` documentation.

### Fixed

- `git fetch` against GitHub SSH remotes works inside the sandbox by rewriting
  them to HTTPS on the allowlisted port 443, without changing the host
  checkout's remote URL.

### Security

- Claude Code runs without `--dangerously-skip-permissions`.
- Network access is default-deny with an explicit host allowlist.
- The kit ships no pre-approved Bash permissions, so tool use inside the
  sandbox still goes through Claude Code's own approval.
- Sandbox removal retains `sbx` confirmation, and invalid wrapper commands fail
  before invoking `sbx`.
