# Fix: transcript writes failing with EACCES in the sandbox

## Context

Starting `sbxclaude` produces:

```
⚠ Transcript writes are failing (permission denied — EACCES) · recent messages may not be saved for resume
```

This was diagnosed live against the running sandbox `sbxclaude-sbxclaude-b6def4`
(`sbx exec ... mount`, `ls -la`, `id`). Findings:

- Claude Code inside the sandbox runs as a non-root user: `uid=1000(agent)
  gid=1000(agent)`, `HOME=/home/agent`.
- Docker Sandboxes gives five `~/.claude` subdirectories their own persistent
  virtio-block volumes, so session state survives sandbox rebuilds:

  ```
  /dev/vde on /home/agent/.claude/projects        type ext4
  /dev/vdf on /home/agent/.claude/sessions        type ext4
  /dev/vdg on /home/agent/.claude/todos           type ext4
  /dev/vdh on /home/agent/.claude/shell-snapshots type ext4
  /dev/vdi on /home/agent/.claude/statsig         type ext4
  ```

- Each is freshly `mkfs.ext4`-formatted (confirmed by a `lost+found` entry
  under `projects/`) and mounts with the ext4 default: `root:root`, mode
  `755`. `agent` falls into "other" — read/list only, no write.
- `~/.claude/backups`, `cache`, `plugins`, and `settings.json` are **not**
  separate volumes; they live on the normal container filesystem and are
  correctly owned by `agent`. This is why the sandbox otherwise works and
  only transcript/session/todo/snapshot/statsig writes fail.
- **Why a `setup.install` step can't fix this:** per `AGENTS.md`, `setup`
  commands are "baked into the sandbox" at kit/image build time. The five
  volumes above are attached at container/VM *start*, not at build time, so
  anything chowned during `setup.install` would be overwritten by the fresh
  volume mount before Claude Code ever runs. The fix has to run at container
  start, after the volumes are attached and before `claude` launches — i.e.
  in `sandbox.entrypoint`, which `sbxclaude/spec.yaml` already overrides
  (currently just `[claude]`, to drop `--dangerously-skip-permissions`).
- This is a Docker Sandboxes / base `claude` agent provisioning gap, not
  something introduced by this repo. The fix is a local workaround: use the
  entrypoint override we already control to chown `~/.claude` before `claude`
  starts. `sudo` is passwordless in the sandbox (per `agentInstructions` in
  `spec.yaml`), so no privilege-escalation setup is needed.

## Fix

In `sbxclaude/spec.yaml`, change the entrypoint from a bare command to a
one-line shell wrapper that fixes ownership of the whole `~/.claude` tree
(not just the five known volumes, so it stays correct if Docker Sandboxes
changes which subdirectories get their own volume) before handing off to
`claude`:

```yaml
sandbox:
  entrypoint:
    - sh
    - -c
    - 'sudo chown -R "$(id -u):$(id -g)" "$HOME/.claude" && exec claude'
  resources:
    ...
```

Notes on this specific form:

- Uses `$(id -u):$(id -g)` rather than hardcoding `agent:agent`, so it keeps
  working if the image's username/uid ever changes.
- `exec claude` (not just `claude`) preserves the existing behavior of
  replacing the shell process rather than leaving it as a wrapper, keeping
  signal handling and the "drops `--dangerously-skip-permissions`" comment's
  intent intact.
- `chown -R` runs on every container start, not just the first. Cost is
  proportional to transcript/session volume size on local block devices —
  negligible in practice, and simplicity/robustness (whole-tree chown vs.
  hardcoding five paths) is worth it here.
- Replace the existing `# Drops --dangerously-skip-permissions` comment with
  one that also explains the chown (see draft above).

Also update `CHANGELOG.md` under `## [Unreleased]` → `Fixed`, per the
changelog conventions in `AGENTS.md` (this is a user-facing bug fix):

- Something like: "Fixed sandbox startup failing to persist Claude Code
  transcripts/session state (`EACCES` on `~/.claude/projects` and related
  dirs) by chowning them in the entrypoint before Claude Code starts."

No changes needed to `scripts/sbxclaude` or `tests/sbxclaude_test.sh` — the
test suite only exercises the wrapper's dispatch logic against a fake `sbx`
CLI and doesn't touch `spec.yaml` content or real sandbox behavior.

## Verification

1. `make validate` — static schema check (no Docker/network), confirms the
   new `entrypoint` array is still schema-valid.
2. `shellcheck` doesn't apply here (this is a YAML-embedded shell string, not
   `scripts/sbxclaude`), but sanity-check the quoting by eye: single-quoted
   YAML scalar containing double-quoted `$(...)` substitutions, no nested
   single quotes.
3. Rebuild the sandbox to pick up the kit change, per the project's own
   documented flow in `README.md`:
   ```bash
   sbxclaude rm   # confirms (y/N) — destroys the current sandbox instance
   sbxclaude      # recreates from the kit and attaches
   ```
4. Inside the new sandbox, confirm the fix:
   ```bash
   sbxclaude exec bash -c 'ls -la ~/.claude/projects ~/.claude/sessions ~/.claude/todos ~/.claude/shell-snapshots ~/.claude/statsig'
   ```
   All five should now be owned by `agent:agent` (or the current uid/gid).
5. Attach interactively (`sbxclaude`) and confirm the `EACCES` transcript
   warning no longer appears at startup, and that a session can be resumed
   normally after exiting and reattaching.
