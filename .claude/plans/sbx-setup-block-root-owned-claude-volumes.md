# Analysis: EACCES on transcript writes — root-owned `.claude` state volumes

**Date:** 2026-08-10
**Status:** Root cause confirmed by controlled experiment. Fix implemented in
`sbxclaude/spec.yaml`; end-to-end verification not yet run.

## Symptom

Starting `sbxclaude` in this repo, Claude Code reports:

```text
⚠ Transcript writes are failing (permission denied — EACCES)
  · recent messages may not be saved for resume
```

The sandbox is otherwise usable — only transcript, session, todo, shell-snapshot,
and statsig persistence fails, so `--resume` loses history.

## Root cause

**A kit containing a `setup:` block causes sbx to provision the Claude state
volumes without chowning them to the sandbox user.** They come up as raw
`mkfs.ext4` output — `root:root`, mode `755` — while Claude Code runs as
`uid=1000(agent)`, which lands in the "other" permission bucket: read and list,
no write.

This is an upstream `sbx` bug, not something specific to this repo's design. It
is triggered by *any* kit with a `setup:` block, including a single no-op
command. The `entrypoint: [claude]` override is **not** implicated.

## Environment

- `sbx` 0.38.0 (Homebrew cask, installed 2026-08-07); daemon v0.38.0
- Base image `docker/sandbox-templates:claude-code-docker`
  (`sha256:ae8a46a105752b6d8937d4000f2058e8379af51aebffc2881618ceef7914f639`)
- Sandbox user: `uid=1000(agent) gid=1000(agent) groups=sudo,docker`;
  `HOME=/home/agent`

## Evidence

### The volumes

sbx mounts five per-directory persistent ext4 volumes so state survives
sandbox rebuilds:

```text
/dev/vde on /home/agent/.claude/projects        type ext4 (rw,relatime)
/dev/vdf on /home/agent/.claude/sessions        type ext4 (rw,relatime)
/dev/vdg on /home/agent/.claude/todos           type ext4 (rw,relatime)
/dev/vdh on /home/agent/.claude/shell-snapshots type ext4 (rw,relatime)
/dev/vdi on /home/agent/.claude/statsig         type ext4 (rw,relatime)
```

In the broken sandbox all five are `root:root`. A `lost+found` directory inside
`projects/` confirms a freshly formatted filesystem. By contrast
`~/.claude/{backups,cache,plugins}` and `settings.json` are *not* separate
volumes — they live on the normal container filesystem and are correctly owned
by `agent`. That split is exactly why the sandbox works except for persistence.

The chown is performed by sbx/sandboxd itself, not by in-image init: the image
has no entrypoint script (`/usr/local/bin` contains only clipboard helpers) and
`/etc/sandbox-persistent.sh` is zero bytes.

### The controlled experiment

Six configurations, all on sbx 0.38.0 against the same base image. The three
throwaway kits were created via an identical `sbx create` → `sbx exec` path and
removed afterwards.

| Kit configuration | `.claude` volume owner |
| --- | --- |
| Plain `claude` agent, no kit (`claude-md2okf`) | `agent:agent` ✅ |
| `extends: claude`, nothing else | `agent:agent` ✅ |
| `extends: claude` + `entrypoint: [claude]` | `agent:agent` ✅ |
| `extends: claude` + one **root** setup step | `root:root` ❌ |
| `extends: claude` + one **user-1000** setup step | `root:root` ❌ |
| This repo's exact original `spec.yaml` | `root:root` ❌ |

Both setup-step kits used a single no-op command, `touch /tmp/x`.

Reading the table:

- Rows 2–3 clear the entrypoint override — it was the leading suspect and is
  innocent.
- Rows 4–5 isolate `setup:` as the sole trigger, and show the step's `user:`
  field is irrelevant; a no-op command suffices.
- Row 1 confirms the plain agent is healthy, with real `.jsonl` transcripts
  written under `~/.claude/projects/-Users-lars-Code-md2okf/`.

### Minimal reproducer

```yaml
schemaVersion: "2"
kind: sandbox
name: repro
version: "0.1.0"
displayName: repro
description: repro

extends: claude

setup:
  install:
    - command: "touch /tmp/x"
```

Create a sandbox from this kit, then inspect `~/.claude/projects` — it is
`root:root`, and Claude Code running as `agent` cannot write transcripts.

### Mechanism (hypothesis — not verified)

A kit with setup steps presumably makes sbx build a *derived* image, and the
state-volume initialization that runs on the base-agent path is skipped or not
re-applied for that derived path, leaving the volumes as raw `mkfs.ext4`
output. Consistent with all observations, but not confirmed against sbx
internals (the CLI is closed-source).

## Why the fix has to live in the entrypoint

`setup.install` commands are baked in at kit-build time. The five volumes are
attached at container **start**, mounting *over* whatever those paths held in
the image — so anything chowned during setup is masked before Claude Code runs.
The repair must happen after the volumes are attached and before `claude`
launches. `sandbox.entrypoint` is the only such hook the kit controls, and this
kit already overrides it (to drop `--dangerously-skip-permissions`).
`sudo` is passwordless in the sandbox, so no extra privilege setup is needed.

## Implemented fix

`sbxclaude/spec.yaml` now wraps the entrypoint:

```yaml
sandbox:
  # Repair root-owned Claude state volumes before starting without
  # --dangerously-skip-permissions.
  entrypoint:
    - sh
    - -c
    - |
      set -eu
      owner="$(id -u):$(id -g)"
      for path in "$HOME/.claude" "$HOME/.claude"/*; do
        if [ -e "$path" ] || [ -L "$path" ]; then
          sudo chown -h "$owner" "$path"
        fi
      done
      exec claude "$@"
    - sbxclaude-entrypoint
```

Design notes:

- **Shallow, not recursive.** The volumes contain nothing but `lost+found` at
  mount time, so chowning `.claude` and its immediate children is sufficient;
  Claude Code then creates everything beneath them itself with correct
  ownership. Avoids a recursive walk on every start and leaves `lost+found`
  at its filesystem-expected `root:root 700`.
- **`$(id -u):$(id -g)`** rather than a hardcoded `agent:agent`, so it survives
  a change to the image's user.
- **`-e`/`-L` guard** handles the literal-glob case under `set -u` and broken
  symlinks; **`chown -h`** avoids dereferencing a symlink out of `.claude`.
- **`exec claude "$@"`** replaces the shell rather than leaving a wrapper,
  preserving signal handling. `sbxclaude-entrypoint` is `$0`, a readable
  process name.
- **Trade-off:** `set -eu` means a `sudo chown` failure aborts startup rather
  than degrading to a warning. With passwordless `sudo` this should not trigger.

Validated with `make validate` (schema) and `shellcheck --shell=sh` on the
extracted script (only style-level SC2250/SC2312 remain). `CHANGELOG.md` has a
matching `Fixed` entry. No changes needed to `scripts/sbxclaude` or
`tests/sbxclaude_test.sh` — those cover wrapper dispatch against a fake `sbx`
and never read `spec.yaml`.

## Upstream status

Searched `docker/sbx-releases` (the tracker for the closed-source CLI; found via
`brew info docker/tap/sbx`) across ~10 query angles — `EACCES`, `permission
denied`, `chown`, `transcript`, `.claude/projects`, `root owned volume`,
`resume session`, the five directory names, and a broad `permission` sweep.
**No existing report matches.** No sbx release notes or merged PRs claim a fix.

Related but distinct:

- [#113](https://github.com/docker/sbx-releases/issues/113) — mounting host
  `~/.claude` into the sandbox (open). Confirms `/home/agent` as the runtime
  user and that `projects/` and `shell-snapshots/` are special-cased paths.
- [#51](https://github.com/docker/sbx-releases/issues/51) — Linux virtiofs
  blocked file creation (closed/fixed). Same genus — guest UID not translating
  to write access on a host-provisioned mount — different mechanism.
- [#76](https://github.com/docker/sbx-releases/issues/76),
  [#400](https://github.com/docker/sbx-releases/issues/400) — other
  `mkfs.ext4` provisioning bugs, confirming it as sbx's volume mechanism.
- [#47](https://github.com/docker/sbx-releases/issues/47) /
  [#131](https://github.com/docker/sbx-releases/issues/131) — an
  entrypoint-overriding kit is Docker's own recommended way to drop
  `--dangerously-skip-permissions`, with a maintainer noting "run options are
  not customizable with custom agents... yet".

## Open items

- [ ] End-to-end verification (not yet run): `sbxclaude rm` then `sbxclaude`,
      confirm the five directories are `agent`-owned, the EACCES warning is
      gone, and a session resumes after detach/reattach.
- [ ] Decide whether to file the minimal reproducer upstream against
      `docker/sbx-releases` — public action, needs sign-off.
- [ ] `.claude/plans/please-add-a-plan-reactive-hare.md` has a stale Context
      section attributing the bug to a generic base-agent provisioning gap.
      Superseded by this document.
