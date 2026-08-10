# sbxclaude

`sbxclaude` runs Claude Code in an isolated sandbox, with a fixed toolchain
already installed. Think of it as a customized version of `sbx run claude`.

## What it does

Each sandbox gets:

- Claude Code, with `--dangerously-skip-permissions` turned off
- `jq`, `ripgrep`, `curl`, Python 3, and ShellCheck
- Ruff and yamllint as Python development tools
- markdownlint-cli2 and CSpell for documentation checks
- An `sbx` CLI for daemon-free kit commands (`version`, `kit validate`,
  `kit inspect`, `kit pack`) so `make validate` works inside the sandbox
- Passwordless `sudo`, and Docker, inside the sandbox
- A network allowlist, not open internet access
- Your project mounted as the workspace — edits land on your real files
- GitHub SSH remotes rewritten to HTTPS inside the sandbox, so `git fetch`
  works on the allowlisted port 443 without changing the host checkout

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

### Git over HTTPS

Sandbox network policy allows `github.com:443` but not SSH port 22. The kit
rewrites `git@github.com:` and `ssh://git@github.com/` remotes to
`https://github.com/` for the sandbox user only, so `git fetch` works without
changing the host checkout's remote URL.

Public repositories need no extra setup. For private repositories, store a
GitHub token on the host so the credential proxy can inject it:

```bash
echo "$(gh auth token)" | sbx secret set github
```
