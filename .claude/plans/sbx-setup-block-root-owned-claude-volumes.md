# Analysis: dropped parent setup in `extends: claude` kits

**Date:** 2026-08-10
**Status:** Root cause confirmed. Two defects found. The committed entrypoint
change is an interim workaround, not the final fix.

Every experimental result below was reproduced independently twice. Claims
that could not be substantiated are called out explicitly.

## Symptom

Starting `sbxclaude` in this repo, Claude Code reports:

```text
⚠ Transcript writes are failing (permission denied — EACCES)
  · recent messages may not be saved for resume
```

The sandbox is otherwise usable — only transcript, session, todo,
shell-snapshot, and statsig persistence fails, so `--resume` loses history.

## Root cause

**Defining a `setup:` block in a kit that uses `extends: claude` replaces the
parent's entire `setup:` block instead of merging with it.** The base `claude`
kit registers a startup command that chowns the Claude state volumes; a derived
kit with its own `setup:` silently loses it, so those volumes stay as raw
`mkfs.ext4` output — `root:root`, mode `755` — while Claude Code runs as
`uid=1000(agent)`, landing in the "other" bucket: read and list, no write.

The `entrypoint` override is **not** implicated in this defect. Any child
`setup:` block triggers it, including a single no-op command, whether that
command runs as root or as user 1000.

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

### What the base kit registers, and what we lose

Startup output quoted in [#408][i408] shows a plain `claude` run registering
**3 install** and **3 startup** commands, the first startup command being the
ownership repair itself:

```text
→ register 4 startup command(s), run on every container start
  + sh -c chown -R agent:agent /home/agent/.claude/projects /ho…
      (kit=claude, user=0)
  + sh -c command -v apt-get > /dev/null 2>&1 && (apt-get updat…
      (kit=claude, user=root)
  + sh -c set -e [ -n "$MCP_GATEWAY_URL" ] || exit 0 export PAT…
      (kit=claude, user=agent)
  + …                                              (kit=<child>, user=1000)
```

`sbx kit inspect sbxclaude` on this repo's kit reports:

```text
Policies:
  Commands:     2 install, 0 startup, 0 init files
```

Two install commands — ours — and **zero** startup commands. The parent's
three install and three startup commands are gone, not concatenated. That is
the defect, observed directly.

The lost commands are broader than the chown: MCP gateway wiring and an
apt-get startup step are also missing from this repo's sandboxes.

### The controlled experiment

Six configurations on sbx 0.38.0 against the same base image, each run twice
with different no-op setup commands (`touch /tmp/x` and `true`), same results:

| Kit configuration | `.claude` volume owner |
| --- | --- |
| Plain `claude` agent, no kit | `agent:agent` ✅ |
| `extends: claude`, nothing else | `agent:agent` ✅ |
| `extends: claude` + `entrypoint: [claude]` | `agent:agent` ✅ |
| `extends: claude` + one **root** setup step | `root:root` ❌ |
| `extends: claude` + one **user-1000** setup step | `root:root` ❌ |
| This repo's exact original `spec.yaml` | `root:root` ❌ |

Rows 2–3 clear the entrypoint override. Rows 4–5 isolate `setup:` as the sole
trigger and show the step's `user:` field is irrelevant. Row 1 confirms the
plain agent is healthy, with real `.jsonl` transcripts written under
`~/.claude/projects/`.

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
    - command: "true"
```

Create a sandbox from this kit and inspect `~/.claude/projects` — it is
`root:root`, and Claude Code running as `agent` cannot write transcripts.
`sbx kit inspect` on it reports `0 startup` commands.

## Second defect: the entrypoint override never dropped yolo mode

This repo's README, `CHANGELOG.md`, and the old `spec.yaml` comment all claimed
`entrypoint: [claude]` drops `--dangerously-skip-permissions`. **It does not.**

The kit reference states: "The effective command is `entrypoint` plus
`command.default` for non-interactive launches, and `entrypoint` plus
`command.interactive` for TTY sessions." A bare `entrypoint: [claude]` supplies
a binary with no run options, so the parent agent's interactive arguments still
apply.

Confirmed at runtime by launching each kit under a pty and reading
`/proc/*/cmdline` inside the sandbox:

| Kit `entrypoint` | Actual process argv |
| --- | --- |
| `[claude]` | `claude --dangerously-skip-permissions` |
| current wrapper (below) | `claude` |

So the security claim was false for the repo's entire history, and the
ownership workaround incidentally made it true: the wrapper supplies explicit
run options, which replace the inherited interactive arguments, leaving `"$@"`
empty.

That is load-bearing behavior resting on an undocumented detail. `exec claude
"$@"` would forward the inherited flag if sbx ever appended it. Dropping
`"$@"`, or setting an explicit `command:` override, would make the guarantee
robust rather than incidental.

## Current workaround

`sbxclaude/spec.yaml` wraps the entrypoint:

```yaml
sandbox:
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

- **Shallow, not recursive.** The volumes hold nothing but `lost+found` at
  mount time, so chowning `.claude` and its immediate children suffices.
  Upstream's own repair is `chown -R` scoped to the five paths, run as
  `user=0` without `sudo`.
- **`$(id -u):$(id -g)`** rather than a hardcoded `agent:agent`.
- **`-e`/`-L` guard** handles the literal-glob case under `set -u`;
  **`chown -h`** avoids dereferencing a symlink out of `.claude`.
- **Trade-off:** `set -eu` means a `sudo chown` failure aborts startup rather
  than degrading to a warning.

Validated with `make validate` and `shellcheck --shell=sh` on the extracted
script (only style-level SC2250/SC2312 remain).

**Assessment.** It fixes the EACCES symptom and avoids the [#299][i299] startup
race, and it happens to deliver the advertised security posture. But it
addresses one consequence of the missing parent setup; MCP gateway wiring and
the apt-get startup step are still absent. It should not be treated as the
final fix.

`setup.startup` is the other hook that runs after the volumes mount, but per
[#299][i299] startup commands do not block agent launch, so a startup-command
repair would race Claude Code's first transcript write. The entrypoint is the
right place for this particular repair.

## Caveat: the merge contract is undocumented

It is tempting to call this a violation of documented schema-v2 composition
rules — that parent and child `setup.install`, `setup.startup`, and
`setup.files` lists are concatenated with parent entries first. **That could
not be substantiated.** Both the kit reference and the kits overview were
checked; neither documents merge, concatenation, or precedence for `setup:`
across `extends`. The behavior appears undocumented rather than contradicting
a stated rule.

This matters for how the upstream report is framed: silently dropping the
parent's ownership repair is clearly undesirable, but absent a documented merge
contract it should be reported as a defect in effect, not as a spec violation.

## Upstream status

Searched `docker/sbx-releases` across ~10 query angles — `EACCES`, `permission
denied`, `chown`, `transcript`, `.claude/projects`, `root owned volume`,
`resume session`, the five directory names, and a broad `permission` sweep.
**No existing report matches** this setup-inheritance defect.

- [#299][i299] — startup commands do not block agent launch; startup
  preparation can race the agent.
- [#408][i408] — documented way to override agent settings does not work;
  its output shows the built-in Claude ownership startup command in v0.38.0.
- [#409](https://github.com/docker/sbx-releases/issues/409) — another v0.38.0
  regression involving custom kit configuration, not this merge failure.
- [#113](https://github.com/docker/sbx-releases/issues/113) — mounting host
  `~/.claude` into the sandbox.
- [#47](https://github.com/docker/sbx-releases/issues/47) /
  [#131](https://github.com/docker/sbx-releases/issues/131) — an
  entrypoint-overriding kit is Docker's recommended way to drop
  `--dangerously-skip-permissions`; per the runtime probe above, the bare form
  of that advice does not actually work.

[i299]: https://github.com/docker/sbx-releases/issues/299
[i408]: https://github.com/docker/sbx-releases/issues/408

## Recommended next steps

1. **Correct the security claims** in `README.md` and `CHANGELOG.md`, and make
   the yolo-mode drop explicit rather than incidental (drop `"$@"` or set an
   explicit `command:`).
2. **Evaluate moving the tool installs into a separate mixin kit** supplied
   alongside the derived sandbox. If runtime composition appends mixin setup
   while preserving the base Claude setup, that restores every lost parent
   command and makes the entrypoint chown removable. Unverified against
   v0.38.0 — needs testing before adoption.
3. **Report upstream** with the minimal reproducer, framed as described above.
4. **End-to-end verification** of the current workaround: `sbxclaude rm`, then
   `sbxclaude`; confirm the five directories are `agent`-owned, the EACCES
   warning is gone, and a session resumes after detach and reattach.
5. After restoring inherited setup, **remove the entrypoint chown** and retest
   transcript creation, restart, and resume.

## Superseded

`.claude/plans/please-add-a-plan-reactive-hare.md` attributes the bug to a
generic base-agent provisioning gap and claims the entrypoint is the only
available hook. Both are wrong; this document replaces it.
