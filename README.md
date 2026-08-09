# sbxclaude

`sbxclaude` runs Claude Code in an isolated sandbox, with a fixed toolchain
already installed. Think of it as a customized version of `sbx run claude`. 

## What it does

Each sandbox gets:

- Claude Code, with `--dangerously-skip-permissions` turned off
- `jq`, `ripgrep`, and `ruff`, installed at build time
- Passwordless `sudo`, and Docker, inside the sandbox
- A network allowlist, not open internet access
- Your project mounted as the workspace — edits land on your real files

The kit spec lives in `sbxclaude/spec.yaml`. `scripts/sbxclaude` is a wrapper
around the `sbx` CLI that builds (or re-attaches to) one sandbox per project.

## Install

You need the `sbx` CLI and add `sbxclaude` to your `PATH`. For example

```bash
brew install docker/tap/sbx
ln -s /path_to_sbxclaude_repo/scripts/sbxclaude ~/.local/bin/sbxclaude
```

## Use

Run `sbxclaude` from any project directory:

```bash
sbxclaude
```

The first run builds a sandbox for that directory and attaches to it. Later
runs re-attach to the same sandbox, so your work carries over.

Pass it a prompt, and Claude gets straight to work:

```bash
sbxclaude "fix the failing test in foo.py"
```

### Flags

| Flag | Effect |
| --- | --- |
| `--help` | Show usage |
| `--validate` | Check the kit spec against the current schema |
| `--inspect` | Show the sandbox's state |
| `--log` | Show its network policy log |
| `--check HOST` | Check network access to `HOST` |
| `--exec CMD` | Run `CMD` inside the sandbox |
| `--create` | Build the sandbox, don't attach |
| `--reload` | Recreate the sandbox from the kit, keep its state |
| `--rebuild` | Remove the sandbox, then build it fresh |
