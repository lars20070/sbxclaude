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
around the `sbx` CLI that builds (or re-attaches to) one sandbox per project,
named `sbxclaude-<project_directory>-<hash>`. The hash comes from the
canonical absolute path, so same-named directories do not share a sandbox.

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

To enter the sandbox with a Bash shell:

```bash
sbxclaude exec bash
```

### Commands

| Command | Effect |
| --- | --- |
| `sbxclaude` | Attach; create the sandbox first if missing |
| `sbxclaude create` | Build the sandbox without attaching |
| `sbxclaude rm` | Remove the sandbox after confirmation |
| `sbxclaude name` | Print the derived sandbox name |
| `sbxclaude exec CMD...` | Run a command inside the sandbox |
| `sbxclaude inspect` | Show the sandbox's state |
| `sbxclaude policy log` | Show the sandbox policy log |
| `sbxclaude policy check HOST` | Check sandbox network access to `HOST` |
| `sbxclaude kit validate` | Check the kit against the current schema |
| `sbxclaude help` | Show usage |

The wrapper accepts only these signatures. It does not forward prompts or
Claude flags. Use `sbx` and the name directly for
anything outside the table. For example

```bash
S="$(sbxclaude name)"
sbx inspect "${S}"
```

### Rebuild after kit changes

Remove and re-create the sandbox to apply changes to the kit:

```bash
sbxclaude rm   # confirms (y/N)
sbxclaude      # recreates from the kit and attaches
```
