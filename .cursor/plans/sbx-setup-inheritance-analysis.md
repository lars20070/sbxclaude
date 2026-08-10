# sbx Claude setup-inheritance analysis

## Problem

Starting this repository's `sbxclaude` kit produced the following Claude Code
warning:

```text
Transcript writes are failing (permission denied — EACCES)
```

Claude runs as `uid=1000(agent)`, but these persistent ext4 volume roots were
owned by `root:root` with mode `0755`:

```text
/home/agent/.claude/projects
/home/agent/.claude/sessions
/home/agent/.claude/todos
/home/agent/.claude/shell-snapshots
/home/agent/.claude/statsig
```

Consequently, Claude could not create transcript or related session-state
files.

## Plain sbx control

A fresh sandbox started directly with `sbx run claude` on sbx v0.38.0 did not
reproduce the problem. All five directories were owned by `agent:agent` and
writable.

The built-in Claude kit registers a startup command that changes ownership of
these state directories. The startup output included in
[docker/sbx-releases#408](https://github.com/docker/sbx-releases/issues/408)
also shows this built-in ownership repair.

This establishes that root-owned block-volume mount points are expected at a
low level, but the standard Claude kit normally repairs them.

## Isolation experiments

Disposable schema-v2 kits were tested to identify which customization caused
the built-in repair to disappear.

### Minimal inheritance

```yaml
schemaVersion: "2"
kind: sandbox
name: claude-extends-probe
extends: claude
```

Result: all Claude state directories were `agent:agent` and writable.

### Entrypoint override

Adding the following did not break ownership repair:

```yaml
sandbox:
  entrypoint: [claude]
```

Result: all Claude state directories remained writable.

### Child setup block

Adding one harmless install command reproduced the failure:

```yaml
setup:
  install:
    - command: "true"
```

Result: all five state directories remained `root:root` and were not writable
by `agent`.

The repository's composed kit similarly reported its two child install
commands but zero startup commands. The inherited Claude ownership command was
absent.

## Root cause

In sbx v0.38.0, defining `setup` in a sandbox kit that uses `extends: claude`
causes the parent's setup commands to be dropped instead of merged.

This contradicts the official schema-v2 composition rules, which specify that
parent and child `setup.install`, `setup.startup`, and `setup.files` lists are
concatenated with parent entries first.

The permission error is therefore a consequence of an sbx inheritance bug
triggered by this repository's `setup.install` block. It is not a general
problem with `sbx run claude`, and `extends` without child setup works.

The impact is broader than transcript ownership: other built-in Claude install
and startup initialization may also be missing from the derived kit.

No existing issue or merged pull request was found that reports this exact
setup-inheritance defect.

## Related upstream issues

- [docker/sbx-releases#299](https://github.com/docker/sbx-releases/issues/299)
  tracks the fact that startup commands do not block agent launch. This can
  allow startup preparation to race the agent.
- [docker/sbx-releases#408](https://github.com/docker/sbx-releases/issues/408)
  demonstrates a related startup race and shows the built-in Claude ownership
  command in v0.38.0.
- [docker/sbx-releases#409](https://github.com/docker/sbx-releases/issues/409)
  reports another v0.38.0 regression involving custom kit configuration, but
  not this specific setup merge failure.

## Entrypoint finding

The original comment that `entrypoint: [claude]` removes
`--dangerously-skip-permissions` was also incorrect. A disposable derived kit
with that entrypoint still ran:

```text
claude --dangerously-skip-permissions
```

The inherited command arguments remain unless they are explicitly overridden
or bypassed.

## Assessment of the current workaround

The current entrypoint wrapper changes ownership before executing Claude. It
prevents the EACCES warning and avoids the startup race, but it only masks one
symptom of the missing parent setup. It does not restore the other inherited
Claude setup behavior.

It should therefore not be treated as the final root-cause fix.

## Recommended next steps

1. Report the minimal `extends` plus `setup.install: true` reproduction to
   `docker/sbx-releases`.
2. Avoid defining `setup` directly in the derived sandbox until sbx fixes the
   merge behavior.
3. Evaluate moving this repository's tool-install commands into a separate
   schema-v2 mixin supplied alongside the derived sandbox. Runtime kit
   composition should append the mixin setup while preserving the base Claude
   setup, but this must be verified against sbx v0.38.0.
4. Explicitly correct the sandbox command configuration so Claude starts
   without `--dangerously-skip-permissions`.
5. After verifying inherited Claude initialization, remove the entrypoint
   ownership workaround and retest transcript creation, restart, and resume.

All disposable sandboxes and temporary probe kits used during this analysis
were removed.
