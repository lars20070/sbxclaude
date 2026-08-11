# Platform independence: macOS, Ubuntu, and WSL

## Context

`sbxclaude` has only ever run on macOS (Apple silicon, Homebrew). Four things
break or mislead elsewhere:

- `scripts/sbxclaude:41` uses `readlink -f`, a GNU extension BSD `readlink`
  lacked before macOS 12.3 — and the README installs the script as a symlink,
  so that call is load-bearing.
- `scripts/sbxclaude:46` uses `tr -c` for the sandbox-name slug. BSD `tr` is
  multibyte-aware, GNU `tr` is byte-oriented, so a non-ASCII project directory
  produces a different name per platform and can abort the script with
  `tr: Illegal byte sequence`.
- `scripts/sbxclaude:37` and `README.md:32` offer `brew install docker/tap/sbx`
  as the only install path — a dead end on Ubuntu and WSL.
- `sbxclaude/spec.yaml:28-30` hardcodes `cpu: 8` / `memory: 24g`, which no
  ordinary Ubuntu laptop, cloud VM, or WSL VM can satisfy.

Upstream `sbx` supports macOS 14+ (Apple silicon, Homebrew), Ubuntu 24.04+
(`docker-sbx` deb, KVM), and Windows 11 natively. Docker Desktop is not
required. WSL is undocumented upstream ([docker/sbx-releases#397][397] asks and
is unanswered) but the Linux package works inside WSL2 with nested
virtualization on.

[397]: https://github.com/docker/sbx-releases/issues/397

Intended outcome: one wrapper that runs on all three hosts without crashing,
stays short enough to read in one sitting, and needs no host detection.

### Design rules

1. **No platform detection.** Use commands that behave the same on all three
   hosts. Where a command exists on only some of them, probe for it — the
   existing `shasum` → `sha256sum` fallback at `scripts/sbxclaude:47-53` is the
   model to copy.
2. **Install advice is not platform-specific.** Always print both recipes,
   labelled `macOS:` and `Linux:`.
3. **Simplicity outranks features.** Expect ~135 lines, up from 101. The growth
   is the symlink resolver and the install hint, nothing else.
4. **Keep the small helpers** — `die`, `no_args`, and the new `require_sbx` /
   `install_hint`.
5. **Two OS names only.** Shipped code, code comments, and docs say `macOS` and
   `Linux`, nothing else — no distro or subsystem names anywhere. Unavoidable
   identifiers are not names: the `ubuntu-latest` CI runner label, `apt-get`,
   the `docker-sbx` package, and release asset filenames stay as they are.

   The rule governs shipped artifacts: `scripts/sbxclaude`, its comments,
   `README.md`, `AGENTS.md`, `CHANGELOG.md`. **This plan document deliberately
   keeps the specific names**, because the reasoning depends on them — but do
   not carry that wording into the code or docs.

Starting point is `scripts/sbxclaude` as it stands on `main` (101 lines);
this branch has an identical copy, and all line numbers below refer to it.

### Decisions (settled — do not re-litigate)

- **No env-var size knob.** `sbxclaude/spec.yaml` is already the right place to
  declare resources, so `SBXCLAUDE_CPUS`-style variables would be a second
  config system for the same job.
- **No `scripts/xargs0`.** The BSD/GNU `xargs` empty-input difference is latent
  (every Makefile glob matches today) and can only affect `make lint` on a
  developer machine, never the wrapper. Record it as a known difference in
  `AGENTS.md` instead.
- **Case-folding the sandbox path is out of scope.** On case-insensitive
  filesystems (APFS, WSL DrvFs) `.../Code` and `.../code` yield two sandboxes
  for one directory. Pre-existing, orthogonal, and fixing it rotates every
  existing sandbox name. Document as known behavior.
- **No `sbx.exe` delegation and no `wslpath` translation.** WSL means the Linux
  `sbx` installed inside the distro.
- Out of scope: Git Bash / MSYS / PowerShell hosts; non-Debian Linux.

## Work

### 1. `scripts/sbxclaude` — four changes

**a. Replace `readlink -f` (line 41)** with a symlink-following loop over bare
`readlink`, which exists everywhere:

```bash
# Follow symlinks without GNU `readlink -f`: BSD readlink lacked -f before
# macOS 12.3, and the README installs this script as a symlink, so the chain
# has to be walked to find the kit.
resolve_dir() {
  local path="$1"
  local link
  local hops=0
  while [[ -L "${path}" ]]; do
    ((++hops <= 40)) || die "too many symlinks resolving $1"
    link="$(readlink "${path}")" || return 1
    case "${link}" in
      /*) path="${link}" ;;
      *) path="$(dirname "${path}")/${link}" ;;
    esac
  done
  (cd "$(dirname "${path}")" && pwd -P)
}

SCRIPT_DIR="$(resolve_dir "${BASH_SOURCE[0]}")"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
```

Notes, all verified against `shellcheck --enable=all` and bash:

- The 40-hop guard matters: without it a symlink loop hangs instead of erroring.
  `((++hops <= 40))` allows 40 hops and dies on the 41st, and `set -e` does not
  fire early on it because it sits in an `|| die` list.
- Assign `resolve_dir`'s result to `SCRIPT_DIR` on its own line. Nesting the
  call inside another command substitution in an `&&` list trips SC2310/SC2312.
- Do **not** append `|| exit 1` to the `SCRIPT_DIR=` line. It trips SC2310 (a
  function in an `||` list disables `set -e`) and it is redundant: `set -e`
  already aborts on `X="$(f)"` when `f` returns non-zero. Verified.
- `${braces}` on every reference: `--enable=all` includes SC2250, which flags
  bare `"$path"`.
- `local link` needs no `=""`; declaring and assigning on separate lines is what
  avoids the masked-return-value warning.

**b. Replace the `tr -c` slug (line 46)** with pure bash:

```bash
SLUG="$(basename "${DIR}")"
SLUG="${SLUG//[!a-zA-Z0-9-]/-}"
while [[ "${SLUG%-}" != "${SLUG}" ]]; do
  SLUG="${SLUG%-}"
done
```

Output is identical to the old pipeline for ASCII directory names, so existing
sandboxes keep their names. Verified across `my project`, `.hidden`, `...`,
`trail---`, `UPPER_case9`, `café`, `a€b`.

**c. Replace the top-level `sbx` check (lines 35-39)** with two helpers. Print
both recipes, so there is nothing to detect:

```bash
install_hint() {
  echo "  macOS: brew trust docker/tap && brew install docker/tap/sbx" >&2
  echo "  Linux: curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh" >&2
  echo "         sudo apt-get install docker-sbx" >&2
  echo "         sudo usermod -aG kvm \"\${USER}\" && newgrp kvm" >&2
  # Only present when a Windows sbx leaks into PATH; no host detection needed.
  if command -v sbx.exe >/dev/null 2>&1; then
    echo "  Note: sbxclaude needs the Linux sbx, not sbx.exe." >&2
  fi
}

require_sbx() {
  if command -v sbx >/dev/null 2>&1; then
    return 0
  fi
  echo "sbxclaude: no sbx CLI found in PATH. Install it with:" >&2
  install_hint
  exit 1
}
```

Call `require_sbx` from the case arms that shell out to `sbx` (attach, `exec`,
`inspect`, `create`, `rm`, `kit validate`, `policy log`, `policy check`) rather
than at the top of the script, so `name` and `help` still work on a host where
`sbx` is not installed yet — the state a first-time Ubuntu or WSL user is in.

The `sbx.exe` note earns its two lines: bash will not resolve bare `sbx` to
`sbx.exe`, so someone whose PATH carries a Windows-side install otherwise sees
"no sbx CLI found" while `sbx.exe` plainly works in their shell. It needs no
branching, and the wording names no subsystem.

**d. Comment the hash probe** (lines 47-53) as the capability-probe pattern to
copy. No code change — macOS has no `sha256sum`, minimal Linux images have no
`shasum`, and both print `<hex>  -` so `cut` agrees.

Bash 3.2 is the floor (macOS `/bin/bash`): no `declare -A`, `mapfile`,
`${var,,}`, `[[ -v ]]`, and no bare `"${arr[@]}"` on a possibly-empty array.

### 2. `sbxclaude/spec.yaml` — drop the hardcoded resources

Delete lines 28-30 (`resources: cpu: 8 / memory: 24g`). `sbx` then sizes each
sandbox from the host: all CPUs, 50% of memory capped at 32 GiB. This is the
change that actually unblocks small Ubuntu and WSL hosts. Anyone wanting a fixed
size puts `resources:` back in this file.

Nothing else in the spec is host-dependent; the `apt-get` / `dpkg` /
`user: "1000"` bits and the amd64+arm64 branch at lines 94-107 are guest-side.

### 3. `Makefile` — one line

Add `BASH ?= bash` and use `$(BASH) ./tests/sbxclaude_test.sh` in `test-unit`,
so CI can run the bash-3.2 leg through the documented target. No other change.

### 4. Tests — `tests/sbxclaude_test.sh`

- Update `expected_name()` (lines 59-72) for the new slug logic, and drop its
  duplicated hash computation (lines 66-70 mirror the wrapper's
  `shasum`/`sha256sum` branch). Assert the slug exactly and the hash as
  `[0-9a-f]{6}`; uniqueness, stability, and symlink-transparency are already
  covered by the comparisons at lines 126-136.
- Add: a **symlinked wrapper** (2 hops, run from an unrelated directory) still
  resolves the right `--kit` path. This is the regression guard for change (a),
  and the current suite misses it because it symlinks the workdir at line 119,
  never the script. Cover a **relative** link target too, since that is the
  branch of `resolve_dir`'s `case` that a same-directory `ln -s` produces.
- Add: with `sbx` absent from `PATH`, `name` and `help` still exit 0, while a
  command that needs `sbx` (e.g. `inspect`) fails with a non-empty hint and
  makes no `sbx` call — the guard for change (c).
- Preflight `python3` with a message naming the requirement (≥ 3.9, for
  `os.waitstatus_to_exitcode` at line 216) instead of failing obscurely.

`tests/toolchain_test.sh` needs no change; it runs in the guest.

### 5. `.gitattributes` (new file)

`* text=auto eol=lf`. Without it, a checkout on a Windows drive with
`core.autocrlf=true` gives the wrapper CRLF endings and
`/usr/bin/env bash^M: bad interpreter`. `.editorconfig:5` says
`end_of_line = lf` but Git does not read it. This is a real WSL crash, so it
belongs to design rule 1.

### 6. CI — `.github/workflows/ci.yml`

- `lint` and `test` get
  `strategy: { fail-fast: false, matrix: { os: [ubuntu-latest, macos-latest] } }`
  and `runs-on: ${{ matrix.os }}`. `macos-latest` is arm64, matching `sbx`.
- macOS `lint` needs `yamllint` (`brew install yamllint`); confirm whether the
  runner already provides `shellcheck` and `jq` rather than assuming it does.
- macOS-only step `make test-unit BASH=/bin/bash` pins the bash 3.2 floor. The
  macOS `lint` leg's `bash -n` (Makefile line 15) is also 3.2, so parse errors
  get caught twice.
- `validate` matrixes too, branching the install on `runner.os`: the existing
  Linux tarball path, and `DockerSandboxes-darwin.tar.gz` for macOS (tarball,
  not brew, to avoid `brew trust` interactivity). Keep `latest` and the comment
  explaining why.

This is the only thing that actually proves design rule 1 on BSD userland and
bash 3.2.

### 7. Docs

- **`README.md`**: replace the Homebrew-only `## Install` (lines 27-34) with both
  recipes, headed `macOS` and `Linux`, plus a short **Requirements** section:
  - host OS and architecture (macOS 14+ Apple silicon; Linux x86_64 or aarch64)
  - virtualization — on Linux, `sbx` needs KVM, so `/dev/kvm` must exist and be
    accessible to your user; **if you run Linux inside a virtual machine,
    nested virtualization must be enabled**. That sentence covers the
    subsystem case exactly, without naming it.
  - keep the checkout on a **native Linux filesystem**: some mounted
    filesystems do not preserve the executable bit, which breaks the
    extensionless `scripts/sbxclaude`.
  - host tools the `make` targets need: `bash`, `git`, `python3` ≥ 3.9,
    `node`/`npx`, `jq`, `shellcheck`, `yamllint`, and `gh` only for
    `sbx secret set github`.

  Also reword line 107 so Homebrew is no longer described as *the* host
  install, and add the host-relative sizing plus the
  case-insensitive-filesystem note. Say CI covers macOS and Linux.
- **`AGENTS.md`**: short **Portability** section — supported hosts are macOS and
  Linux; bash 3.2 is the floor; no GNU-only flags (`readlink -f`, `xargs -r`,
  `stat -c`, `date -d`, `sed -i` without an argument); probe for capabilities,
  never for OS names; say `macOS` and `Linux` and no other OS names in code,
  comments, or docs; and the one-line note about the BSD/GNU `xargs`
  empty-input difference.
- **`CHANGELOG.md`** under `## [Unreleased]`: *Changed* — sandbox size now
  follows the host instead of a fixed 8 CPU / 24 GB; *Fixed* — no longer needs
  GNU `readlink -f` (so it works on macOS < 12.3) and no longer mis-derives
  sandbox names for non-ASCII project directories; *Added* — Linux install
  instructions.
- **`.cspell.json`**: add any new words `make lint` flags (it spell-checks every
  tracked file, so this is required, not optional). Likely candidates are
  `kvm`, `usermod`, and `newgrp`; rule 5 keeps subsystem names out entirely.

## Verification

```bash
make lint                       # shellcheck --enable=all, bash -n, cspell
make test-unit                  # bash 5
make test-unit BASH=/bin/bash   # bash 3.2 floor, macOS only
make validate                   # required after touching spec.yaml
sbxclaude rm && sbxclaude       # resources: removed, so rebuild to apply
make test-toolchain             # guest toolchain intact
wc -l scripts/sbxclaude         # expect ~135
```

By hand:

1. **Name stability**: `sbxclaude name` must be byte-identical before and after
   (`sbxclaude-sbxclaude-b6def4` for this repo), so no existing sandbox is
   orphaned.
2. **Symlink install**: `ln -sf "$PWD/scripts/sbxclaude" ~/.local/bin/sbxclaude`,
   then from an unrelated directory `sbxclaude kit validate` must validate this
   repo's kit.
3. **No sbx installed**: with `PATH` stripped of `sbx`, `sbxclaude help` and
   `sbxclaude name` still work, and `sbxclaude inspect` prints both install
   recipes.
4. **Ubuntu 24.04**: install `docker-sbx`, then `sbxclaude` end-to-end on a
   small (~8 GB) host — this is what the removed `resources:` block unblocks.
5. **WSL2**: with `nestedVirtualization=true` and the repo on the Linux
   filesystem, `sbxclaude` works end-to-end; confirm no CRLF with
   `git ls-files --eol scripts/sbxclaude` → `w/lf`.
6. CI: all matrix legs green.
