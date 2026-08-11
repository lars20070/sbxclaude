# Platform independence: macOS, Ubuntu, and WSL

## Context

`sbxclaude` has only ever been developed and run on macOS (Apple silicon,
Homebrew). Nothing in the repo detects the host OS, and several pieces are
either macOS-shaped or macOS-broken:

- `scripts/sbxclaude:41` uses `readlink -f`, a GNU extension that BSD
  `readlink` only gained in macOS 12.3 — and the script depends on it to
  resolve the README's symlink install back to the kit directory.
- The only documented install path is `brew install docker/tap/sbx`
  (`README.md:32`, echoed in the wrapper's own error at
  `scripts/sbxclaude:37`), which is a dead end on Ubuntu and WSL.
- `sbxclaude/spec.yaml:28-30` hardcodes `cpu: 8` / `memory: 24g`. That
  assumes a 32 GB+ host and cannot be met on most Ubuntu laptops, cloud VMs,
  or inside a WSL VM (which is itself capped by `.wslconfig`).
- CI is Ubuntu-only, so the BSD-userland path — the one every real user is
  on — is never tested.

Upstream reality (verified against `sbx` v0.38.0 and Docker's docs): `sbx`
supports **macOS 14+ on Apple silicon** (Homebrew), **Ubuntu 24.04+ on
x86_64/aarch64** (`docker-sbx` deb, KVM required), and **Windows 11**
natively (winget/MSI). Docker Desktop is not required. WSL is *not*
documented upstream — [docker/sbx-releases#397][397] asks exactly this and
has no maintainer answer — but the Linux package works inside WSL2 when
nested virtualization is on and `/dev/kvm` is present.

[397]: https://github.com/docker/sbx-releases/issues/397

Intended outcome: `sbxclaude` runs unmodified on macOS, Ubuntu 24.04+, and
WSL2; every host-dependent value is derived or overridable rather than
hardcoded; and CI proves both userlands.

### Scope decisions (confirmed with the user)

- **WSL = "Ubuntu with extra preflight."** Require the Linux `sbx` inside
  the WSL distro. No `sbx.exe` delegation, no `wslpath` translation — if
  only the Windows CLI is reachable, say so and stop.
- **Resources become host-relative** by deleting the `resources:` block and
  letting `sbx` apply its own defaults (all host CPUs; 50% of host memory,
  capped at 32 GiB), with opt-in env overrides.
- **CI gains a macOS leg plus an explicit bash 3.2 leg.**
- **A new `sbxclaude doctor` command** carries the diagnostics.

### Explicit non-goals

- **Case-folding the sandbox path before hashing.** On case-insensitive
  filesystems (APFS, WSL DrvFs) `cd .../Code` and `cd .../code` produce two
  sandbox names for one directory. Real, but pre-existing and orthogonal to
  portability, and fixing it rotates every existing sandbox name. Document
  it as known behavior instead.
- Git Bash / MSYS / native PowerShell hosts. WSL is the Windows story.
- Non-Debian Linux (Rocky/Fedora). `sbx` ships an RPM; we only document
  Ubuntu, which is what upstream documents.

## Work

### 1. `scripts/sbxclaude` — remove the GNU/BSD dependencies

**Replace `readlink -f` (line 41)** with a bash-3.2-safe symlink resolver.
Only `REPO` is needed, so walk the symlink chain with bare `readlink` (POSIX
everywhere), then `cd -P`:

```bash
resolve_dir() {          # prints the canonical directory holding "$1"
  local path="$1" link hops=0
  while [[ -L "${path}" ]]; do
    hops=$((hops + 1))
    [[ "${hops}" -le 40 ]] || die "symlink loop resolving ${1}"
    link="$(readlink "${path}")"
    case "${link}" in
      /*) path="${link}" ;;
      *) path="$(dirname "${path}")/${link}" ;;
    esac
  done
  (cd "$(dirname "${path}")" && pwd -P)
}
```

Then `REPO="$(cd "$(resolve_dir "${BASH_SOURCE[0]}")/.." && pwd -P)"`, and
`KIT`/`AGENT` stay as they are. Note `tests/sbxclaude_test.sh:6` already uses
this portable idiom for its own root — the wrapper was the outlier.

**Replace the `tr -c` slug (line 46)** with pure bash. BSD `tr` is
multibyte-aware under UTF-8 while GNU `tr` is byte-oriented, so a project
directory like `café` currently yields a *different* name per platform and
can abort with `tr: Illegal byte sequence` under `set -e`:

```bash
SLUG="$(basename "${DIR}")"
SLUG="${SLUG//[!a-zA-Z0-9-]/-}"
while [[ "${SLUG%-}" != "${SLUG}" ]]; do SLUG="${SLUG%-}"; done
```

Identical output to today for ASCII directory names (so existing sandboxes
keep their names); only the already-broken non-ASCII cases change.

**Keep** the existing `shasum` → `sha256sum` → `die` probe (lines 47-53) —
it is the correct capability-probe pattern and macOS has no `sha256sum`
while minimal WSL images have no `shasum`. Use it as the model, and add a
comment marking it as such.

**Move the `sbx` preflight off the top level.** The `command -v sbx` guard at
lines 35-39 runs before the dispatch, so it would pre-empt `doctor` — whose
most useful output is precisely "no `sbx` here, install it like this."
Convert it into a `require_sbx` function called from the arms that actually
shell out to `sbx` (attach, `exec`, `inspect`, `create`, `rm`, `kit
validate`, `policy *`). `name`, `help`, and `doctor` then work on a host
with no `sbx` at all, which is also the state a first-time Ubuntu or WSL user
is in.

**Make the missing-`sbx` hint OS-aware** (lines 35-38) via a small helper
used by both `require_sbx` and `doctor`:

| Host | Hint |
| --- | --- |
| Darwin | `brew trust docker/tap && brew install docker/tap/sbx` |
| Linux (non-WSL) | `get.docker.com` script + `apt-get install docker-sbx` |
| WSL | same as Linux, plus the `.wslconfig` / `/dev/kvm` note |

Host detection uses `uname -s`, and WSL is detected from
`/proc/sys/kernel/osrelease` matching `*icrosoft*` or `${WSL_DISTRO_NAME:-}`
being set. This is the **only** place in the repo that branches on OS name;
everything else stays capability-probed.

Implementation guardrail: when probing WSL via `/proc/...`, first check that
the file exists/readable (or that the read succeeds) so `set -u`/platform
differences don't turn detection into a hard failure before the scripted
capability checks run.

**Add resource overrides.** Read `SBXCLAUDE_CPUS` and `SBXCLAUDE_MEMORY`,
and append `--cpus` / `--memory` **only on the creating paths** (`create`,
and the attach path when `sbx inspect` fails) — `sbx run --name` on an
existing sandbox ignores creation-time flags. Build them into an array
(`RESOURCE_ARGS`) so an unset variable contributes nothing. Pass values
through unvalidated; `sbx` already rejects bad ones (`--memory` wants binary
units like `8g`) and duplicating that check here would only drift.

Implementation guardrail: because the wrapper runs under `set -u`, any
reading/building of `SBXCLAUDE_CPUS`/`SBXCLAUDE_MEMORY` must use safe
parameter expansions (for example `${SBXCLAUDE_CPUS:-}` / `${SBXCLAUDE_MEMORY:-}`
or explicit `[[ -n "${VAR:-}" ]]` checks) so “unset” never throws.

Deliberately **environment variables only — no `.env` file**:

- The values describe the *host*, not the project. A committed per-project
  `.env` would travel to a differently-sized machine and reintroduce exactly
  the hardcoding this change removes. The host's shell profile is the right
  home, and behaves identically on all three platforms.
- Sourcing a project-local file would be a host-side code-execution vector:
  the wrapper runs outside the sandbox with the user's credentials, so
  `cd`-ing into an untrusted clone and running `sbxclaude` would execute that
  repo's `.env` *before* any isolation exists. Parsing instead of sourcing
  means hand-rolling a quoting/comment/`export` parser in bash 3.2 for two
  values.
- It matches upstream (`DOCKER_SANDBOXES_IP_STACK`,
  `DOCKER_SANDBOXES_CLONED_WORKSPACE_SIZE`) and keeps the wrapper
  config-free, so `sbxclaude name` stays a pure function of `$(pwd -P)` —
  which is what the naming tests assert. Anyone wanting per-directory sizing
  can use `direnv`, which solves the trust problem properly.

Document the creation-time caveat in README beside the variables: resources
are fixed when the sandbox is created, so changing a variable takes effect
only after `sbxclaude rm && sbxclaude`. Same rule as the existing "pin bumps
need a rebuild" note at `README.md:86`.

**Add `doctor`.** It *complements* `name` rather than replacing it, even
though it also prints the name. `name` is the machine-readable primitive —
one line on stdout, no `sbx` calls (asserted at
`tests/sbxclaude_test.sh:136`), and the documented seam to `sbx` proper
(`README.md:69-75`, `scripts/sbxclaude:29-31`). `doctor` is human-facing
prose that round-trips to the daemon and exits non-zero on failure, so it is
unusable in `S="$(...)"`: it would mean grepping prose, paying daemon
latency, and failing when the daemon is down even though the name is a pure
function of `$(pwd -P)`. Keep both; label doctor's line (`sandbox name:
…`) so it never looks like an API.

New `case` arm, `no_args`-guarded, read-only, exits non-zero if a required
check fails:

1. Host: `uname -s -m`, plus `WSL` when detected.
2. `sbx` on `PATH` + `sbx version`; if absent, the OS-aware hint. On WSL,
   if `sbx.exe` is reachable but the Linux `sbx` is not, say explicitly that
   `sbxclaude` needs the Linux package inside the distro and will not drive
   `sbx.exe`.
3. Daemon reachability (`sbx ls >/dev/null 2>&1`), pointing at
   `sbx diagnose` on failure rather than reimplementing it.
4. On Linux/WSL: `/dev/kvm` present and writable; if not, the `kvm`-group
   remedy (`sudo usermod -aG kvm "$USER"; newgrp kvm`), and on WSL the
   `nestedVirtualization=true` `.wslconfig` remedy.
5. Resolved sandbox name, kit path, and any active resource overrides.

Update `usage()` (lines 15-33) and the README command table together.

`doctor` should have a testable output contract:

- Keep the step headings stable and in a fixed order (even if the
  per-step prose changes slightly).
- Exit non-zero on any failure, but allow warnings/extra detail to vary
  without breaking tests; prefer substring assertions in
  `tests/sbxclaude_test.sh`.

Implementation note: `sbxclaude help` / `usage()` must still show the
`doctor` row even on hosts without `sbx` (because `require_sbx` runs only in
command arms that actually invoke `sbx`).

### 2. `sbxclaude/spec.yaml` — drop the hardcoded resources

Delete lines 28-30 (`resources: cpu: 8 / memory: 24g`). `sbx` then sizes
each sandbox from the actual host. Consequence to state in `CHANGELOG.md`:
a 64 GB Mac now gets 32 GiB rather than 24 GB, and small hosts get a
working sandbox instead of a failure. `SBXCLAUDE_CPUS` / `SBXCLAUDE_MEMORY`
cover anyone who wants the old fixed sizing.

Nothing else in `spec.yaml` is host-dependent — the `apt-get`/`dpkg`/`user:
"1000"` assumptions and the amd64+arm64 branch at lines 94-107 are all
guest-side and already correct.

### 3. `Makefile` — kill the `xargs` empty-input divergence

`Makefile:11-16` pipes `git ls-files -z` into `xargs -0`. On empty input GNU
`xargs` runs the tool with no arguments while BSD `xargs` skips it, so the
day a glob stops matching, Ubuntu fails confusingly and macOS passes. GNU's
`-r` is not available on macOS, so add `scripts/xargs0` — a tiny wrapper
that reads NUL-delimited paths (`while IFS= read -r -d ''`), exits 0 when
there are none, and otherwise execs the tool (honoring a `-n1` flag for the
`jq empty` and `bash -n` lines). Route all six lint lines through it. It
lives under `scripts/`, so `make lint` already shellchecks it.

Also add `BASH ?= bash` and use `$(BASH) ./tests/sbxclaude_test.sh` in
`test-unit`, so CI can pin the bash-3.2 leg through the documented target
rather than bypassing the Makefile.

### 4. Tests

`tests/sbxclaude_test.sh`:

- `expected_name()` (lines 59-72) currently reimplements the hash with its
  own `shasum`/`sha256sum` branch, duplicating `scripts/sbxclaude:47-53`. Cut
  the hash out of it: assert the *slug* exactly (pure bash, matching §1) and
  the hash as `[0-9a-f]{6}`. The invariants that matter — unique per path,
  stable, symlink-transparent — are already covered by the comparisons at
  lines 126-136 and don't need the exact digest.
- Preflight `python3` with a message naming the requirement (≥ 3.9, for
  `os.waitstatus_to_exitcode` at line 216) instead of failing obscurely.
- New cases: `doctor` exits 0 under the fake `sbx` and prints the resolved
  name; `doctor extra` is rejected before any `sbx` call
  (`reject_without_call`); with `PATH` stripped of the fake `sbx`, `name` and
  `help` still succeed and `doctor` still reports the missing CLI with a
  non-zero exit — the regression guard for moving `require_sbx` off the top
  level; `SBXCLAUDE_CPUS`/`SBXCLAUDE_MEMORY` appear in the
  `create` and missing-sandbox-attach argv and are **absent** from the
  existing-sandbox attach; a symlinked wrapper still resolves the right
  `--kit` path (guards the `readlink -f` fix — the current suite symlinks
  the *workdir* at line 119 but never the script).
- Extend the help assertions (lines 197-203) for the `doctor` line.

`tests/toolchain_test.sh` needs no change; it runs entirely in the guest.

### 5. Repo hygiene for WSL

- **Add `.gitattributes`** with `* text=auto eol=lf`. Without it, a checkout
  on a Windows drive with `core.autocrlf=true` gives the wrapper CRLF line
  endings and `/usr/bin/env bash^M: bad interpreter`. `.editorconfig:5`
  states `end_of_line = lf` but Git doesn't read it.
- Document in README that the repo should live on the **Linux filesystem**
  (`~/…`), not `/mnt/c/…`: DrvFs without the `metadata` option synthesizes
  the exec bit from the file extension, which breaks the extensionless
  `scripts/sbxclaude`, and bind-mounting `/mnt/c` into a microVM is slow.

### 6. CI — `.github/workflows/ci.yml`

- `lint` and `test` gain
  `strategy: { fail-fast: false, matrix: { os: [ubuntu-latest, macos-latest] } }`
  with `runs-on: ${{ matrix.os }}`. `macos-latest` is arm64, matching `sbx`'s
  Apple-silicon requirement.
- macOS `lint` needs a `brew install yamllint` step (shellcheck and jq are
  preinstalled; markdownlint/cspell already come from pinned `npx`).
  Verify the macOS runner provides `shellcheck` and `jq`; if it doesn't, add
  an install step rather than assuming they exist.
  Unpinned brew installs are consistent with the "floating integration
  surfaces" policy already stated in `README.md:102-107`.
- Add a macOS-only step `make test-unit BASH=/bin/bash` to lock the bash 3.2
  floor. Note the macOS `lint` leg's `bash -n` (line 15) is also 3.2 there,
  so parse regressions get caught twice.
- `validate` also matrixes; the install step branches on
  `runner.os` — the existing Linux tarball path, and
  `DockerSandboxes-darwin.tar.gz` + `install.sh` for macOS (tarball, not
  brew, to avoid `brew trust`'s interactivity). Keep `latest`, keep the
  comment explaining why.

### 7. Docs

- **`README.md`**: replace the single-recipe `## Install` (lines 27-34) with
  a **Requirements** table (host OS/arch, virtualization, and the host tools
  each `make` target needs: `bash`, `git`, `python3` ≥ 3.9, `node`/`npx`,
  `jq`, `shellcheck`, `yamllint`, optional `gh` for `sbx secret set github`)
  plus per-OS install sections for macOS / Ubuntu 24.04+ / WSL2. State
  plainly that WSL is best-effort and not covered by CI. Reword line 107 so
  Homebrew is no longer described as *the* host install. Add the resource
  defaults and `SBXCLAUDE_CPUS`/`SBXCLAUDE_MEMORY`, the `doctor` row in the
  command table, and the case-insensitive-filesystem note from Non-goals.
- **`AGENTS.md`**: add a short **Portability** section — supported hosts;
  bash 3.2 is the floor (macOS `/bin/bash`), so no `declare -A`, `mapfile`,
  `${var,,}`, or `[[ -v ]]`; no GNU-only flags (`readlink -f`, `sed -i`
  without an arg, `xargs -r`, `stat -c`, `date -d`); probe for capabilities,
  not OS names, with the `uname` helper in `scripts/sbxclaude` as the single
  sanctioned exception.
- Add a brief “bash-3.2 syntax only” note near the wrapper changes reminding
  implementation to avoid newer bash features while building arrays and
  using parameter-expansion defaults.
- **`CHANGELOG.md`** under `## [Unreleased]`: *Added* — `sbxclaude doctor`,
  `SBXCLAUDE_CPUS`/`SBXCLAUDE_MEMORY`, Ubuntu and WSL install docs;
  *Changed* — sandbox resources now sized from the host instead of a fixed
  8 CPU / 24 GB; *Fixed* — wrapper no longer requires GNU `readlink -f`, so
  it works on macOS < 12.3 and with non-ASCII project directory names.
- **`.cspell.json`**: add the new words (`kvm`, `wslconfig`, `winget`,
  `distro`, `coreutils`, `nested` if flagged). `make lint` spell-checks every
  tracked file, so this is required, not optional.

## Verification

Run on macOS (primary dev host) and, for the Linux half, inside the sandbox
or a CI run:

```bash
make lint                          # incl. shellcheck + bash -n on the new scripts
make test-unit                     # bash 5
make test-unit BASH=/bin/bash      # bash 3.2 floor, macOS only
make validate                      # schema check; required after spec.yaml edits
sbxclaude rm && sbxclaude create   # resources block removed -> rebuild needed
make test-toolchain                # guest toolchain still intact
```

Then, by hand:

1. `sbxclaude doctor` on macOS — expect all checks green and the resolved
   name matching `sbxclaude name`.
2. **Symlink install** (the `readlink -f` regression guard):
   `ln -sf "$PWD/scripts/sbxclaude" ~/.local/bin/sbxclaude`, then from an
   unrelated directory run `sbxclaude kit validate` and confirm it validates
   the repo's kit rather than erroring on a bad path.
3. **Name stability**: `sbxclaude name` before and after the change must be
   byte-identical for this repo, so no one's existing sandbox is orphaned.
4. **Resource override**: `SBXCLAUDE_MEMORY=8g sbxclaude create` then
   `sbxclaude inspect` and confirm 8 GiB; `sbxclaude` (re-attach) must not
   pass the flag.
5. **Ubuntu 24.04**: install `docker-sbx`, `sbxclaude doctor`, then
   `sbxclaude` end-to-end on a small (e.g. 8 GB) host to confirm the
   removed `resources:` block is what unblocks it.
6. **WSL2**: with `nestedVirtualization=true` and the repo on the Linux
   filesystem, `sbxclaude doctor` should pass; with the Windows-only `sbx`
   installed it must fail with the explicit "needs the Linux package"
   message. Also confirm the checkout has no CRLF
   (`git ls-files --eol scripts/sbxclaude` → `w/lf`).
7. CI: all matrix legs green on the PR.
