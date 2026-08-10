# GitHub issue draft

<!-- cspell:ignore statsig -->

Proposed title:

> schema v2: child setup drops parent setup commands in extends: claude kits

## Summary

On sbx v0.38.0, adding a `setup` block to a schema-v2 sandbox that uses
`extends: claude` stops the parent kit's own setup from running.

One no-op child install command is enough to trigger it. Claude's persistent
state volumes stay `root:root`, and the UID 1000 agent cannot write to them.
Drop the child `setup` block, and ownership is fixed.

## Environment

- sbx: `v0.38.0 c022b14634c4bea846ca12870d1d5e97d5868b54`
- Daemon: `v0.38.0`
- Host: macOS 26.6.1, arm64
- Image: `docker/sandbox-templates:claude-code-docker`
- Image digest:
  `sha256:ae8a46a105752b6d8937d4000f2058e8379af51aebffc2881618ceef7914f639`

## Minimal broken kit

Create `broken/spec.yaml`:

```yaml
schemaVersion: "2"
kind: sandbox
name: setup-inheritance-broken
version: "0.1.0"
displayName: Setup inheritance broken case
description: Reproduces dropped parent setup commands

extends: claude

setup:
  install:
    - command: "true"
      description: No-op child setup command
```

Start it:

```bash
sbx run \
  --name setup-inheritance-broken \
  --kit ./broken \
  setup-inheritance-broken .
```

While it runs, check the Claude state volumes from another terminal:

```bash
sbx exec setup-inheritance-broken -- stat -c '%U:%G %a %n' \
  /home/agent/.claude/projects \
  /home/agent/.claude/sessions \
  /home/agent/.claude/todos \
  /home/agent/.claude/shell-snapshots \
  /home/agent/.claude/statsig
```

Observed:

```text
root:root 755 /home/agent/.claude/projects
root:root 755 /home/agent/.claude/sessions
root:root 755 /home/agent/.claude/todos
root:root 755 /home/agent/.claude/shell-snapshots
root:root 755 /home/agent/.claude/statsig
```

A direct write check as the agent also fails:

```bash
sbx exec setup-inheritance-broken -- \
  mkdir /home/agent/.claude/projects/reproduction-write-test
```

```text
mkdir: Permission denied
```

## Control experiment

Create `control/spec.yaml`. It differs only by leaving out `setup`:

```yaml
schemaVersion: "2"
kind: sandbox
name: setup-inheritance-control
version: "0.1.0"
displayName: Setup inheritance control case
description: Controls for inherited parent setup commands

extends: claude
```

Run it the same way:

```bash
sbx run \
  --name setup-inheritance-control \
  --kit ./control \
  setup-inheritance-control .
```

The same ownership check reports:

```text
agent:agent 755 /home/agent/.claude/projects
agent:agent 700 /home/agent/.claude/sessions
agent:agent 755 /home/agent/.claude/todos
agent:agent 755 /home/agent/.claude/shell-snapshots
agent:agent 755 /home/agent/.claude/statsig
```

The agent can write to all five paths.

## Expected result

sbx should add the child's install command after the parent's, not replace
them. Docker's
[schema-v2 composition documentation](https://github.com/docker/sbx-kits-contrib/blob/main/skills/kit-author/topics/composition.md)
says setup lists are concatenated, parent entries first.

So the derived sandbox should keep Claude's built-in setup, with writable
state volumes.

## Actual result

Defining the child `setup.install` block wipes out the built-in ownership
step. The state volumes keep their raw root ownership, so Claude cannot write
transcripts, sessions, todos, shell snapshots or statsig state.

## Impact

Derived Claude kits cannot add install commands without silently losing the
parent's setup. The ownership failure is easy to spot, but other inherited
install or startup steps may be missing too.

## Related issues

- [#408](https://github.com/docker/sbx-releases/issues/408) is about a
  settings startup race. Its logs show the built-in Claude ownership startup
  command, but it does not report this setup-inheritance bug.
- [#299](https://github.com/docker/sbx-releases/issues/299) asks for startup
  commands to block. It concerns startup ordering, not parent setup commands
  going missing.

## Cleanup

```bash
sbx rm --force setup-inheritance-broken
sbx rm --force setup-inheritance-control
```
