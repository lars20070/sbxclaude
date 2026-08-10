# sbx setup-inheritance reproducer

<!-- cspell:ignore statsig -->

This reproducer compares a schema-v2 sandbox that only extends the built-in
Claude kit with an otherwise identical sandbox that adds one no-op child setup
command.

## Requirements

- sbx v0.38.0
- A working built-in `claude` sandbox

## Control

From this directory, start the control sandbox:

```bash
sbx run \
  --name setup-inheritance-control \
  --kit ./control \
  setup-inheritance-control .
```

While it is attached, inspect the state volumes from another terminal:

```bash
sbx exec setup-inheritance-control -- stat -c '%U:%G %a %n' \
  /home/agent/.claude/projects \
  /home/agent/.claude/sessions \
  /home/agent/.claude/todos \
  /home/agent/.claude/shell-snapshots \
  /home/agent/.claude/statsig
```

Expected control result: each path is owned by `agent:agent` and writable by
the Claude process.

Remove the control sandbox after exiting Claude:

```bash
sbx rm --force setup-inheritance-control
```

## Broken case

Start the sandbox whose kit adds one no-op `setup.install` command:

```bash
sbx run \
  --name setup-inheritance-broken \
  --kit ./broken \
  setup-inheritance-broken .
```

From another terminal, inspect the state volumes:

```bash
sbx exec setup-inheritance-broken -- stat -c '%U:%G %a %n' \
  /home/agent/.claude/projects \
  /home/agent/.claude/sessions \
  /home/agent/.claude/todos \
  /home/agent/.claude/shell-snapshots \
  /home/agent/.claude/statsig
```

Actual broken result: each path is `root:root 755`, so UID 1000 cannot write
Claude's transcript and session state.

A direct write attempt also fails:

```bash
sbx exec setup-inheritance-broken -- \
  mkdir /home/agent/.claude/projects/reproduction-write-test
```

```text
mkdir: Permission denied
```

Remove the broken sandbox after exiting Claude:

```bash
sbx rm --force setup-inheritance-broken
```
