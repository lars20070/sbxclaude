# Rework `sbxclaude` into a minimal subcommand wrapper

## Context

`scripts/sbxclaude` is a 58-line flag-based wrapper around the `sbx` CLI. Its
flags grew one at a time and were never designed as a set, and its trailing
`*)` case forwards any unrecognised argument straight to Claude Code, so the
script is simultaneously a sandbox manager and a Claude front-end.

The goal is to make it **only a sandbox lifecycle tool**, addressed with
`sbx`-shaped subcommands. Anything it does not expose is reachable by calling
`sbx` (or `claude`) directly.

Scope of the wrapper after this change:

- It manages the sandbox: attach, create, remove, inspect, validate, policy.
- It does **not** pass prompts or flags to Claude Code, and does not wrap
  `sbx stop`.

That single constraint is what keeps the design small: because no argument is
ever destined for the agent, every argument belongs to the wrapper, so parsing
is a plain `case` with no escape hatches, no quoting rules, and no ambiguity
between a command name and free text.

Every factual claim below was verified live against `sbx` v0.38.0 and the
current script.

## Target interface

| Command | Runs |
| --- | --- |
| (no args) | attach; create first if missing |
| `exec CMD...` | `sbx exec [-it] S -- CMD...` |
| `inspect` | `sbx inspect S` |
| `create` | `sbx create --name S --kit K AGENT .` |
| `rm` | `sbx rm S` — no `--force`, sbx confirms |
| `kit validate` | `sbx kit validate K` |
| `policy log` | `sbx policy log S` |
| `policy check HOST` | `sbx policy check network --sandbox S HOST` |
| `help`, `-h`, `--help` | usage text |
| anything else | error: unknown command |

Two-word commands are nested, matching sbx's own structure, so
`sbxclaude X Y` runs `sbx X Y` with the sandbox name and kit path filled in.

Attach is the only path that starts Claude; every subcommand runs and exits.
It stays two-branch, because `sbx run`'s agent positional is optional **only
when the sandbox already exists** (verified in `sbx run --help`):

```bash
if sbx inspect "${SANDBOX}" >/dev/null 2>&1; then
    exec sbx run --name "${SANDBOX}"
fi
sbx kit validate "${KIT}" >/dev/null
exec sbx run --name "${SANDBOX}" --kit "${KIT}" "${AGENT}"
```

No `-- "$@"` separator is needed on either call: there are no agent arguments
to separate.

`rm` is the only destructive command; mark it as such in the help text.
Rebuilding, and applying kit changes, is:

```bash
sbxclaude rm   # confirms (y/N)
sbxclaude      # recreates from the kit and attaches
```

The help text must state that the wrapper exposes only these signatures.
`inspect --json`, `policy log --json`, `exec -w`, `sbx stop`, and any Claude
flag require calling `sbx` or `claude` directly.

## Defects in the current script to fix

- **D1 — real bug.** `sbx policy check network` accepts `--sandbox`, but
  `scripts/sbxclaude:27` calls it without one. So `--check` reports on
  **global** policy while `--log` (line 24) reports on **this sandbox** — a
  visual pair that silently disagrees about scope. Verified: bare
  `sbx policy check network github.com` answers `Context: global`.
- **D2.** `exec` (lines 29-36) forwards everything past `--`, so
  `--exec -w /src ls` becomes `sbx exec -it S -- -w /src ls` →
  `exec: "-w": not found`, which reads as a broken sandbox. Reject a leading
  `-` in the first token after `exec`, pointing the user at `sbx`.
- **D3.** `--rebuild` (lines 38-41) runs `sbx rm --force` and then *falls
  through* to the bottom of the script, so `--rebuild --exec bash` deletes the
  sandbox and then passes `--exec bash` to Claude as arguments: destructive
  work completes before the mistake surfaces. The new dispatch has no
  fall-through — every branch `exec`s — so this cannot recur.
- **D4.** `--reload` (line 37) calls `sbx kit add`, which cannot work here:
  that command accepts only mixin kits, and `sbxclaude/spec.yaml` declares
  `kind: sandbox`. Verified — the strings `has kind` and `is for mixin kits`
  are both present in the `sbx` binary. Drop the command rather than ship one
  that always fails; `rm` + attach is the working refresh.
- **D5.** `--log` is misleadingly generic. `sbx policy log --type` covers
  `network` *and* `filesystem`, so it is the **policy** log; `policy log` is
  both sbx-exact and future-proof.
- The `exec` **tty gate** (`[[ -t 0 ]]`, lines 31-35) is correct and must be
  preserved: `-it` for an interactive terminal, omitted for pipes and
  automation.

## Sandbox naming

`scripts/sbxclaude:14` derives the name from `basename "$PWD"` alone, so
`~/work/api` and `~/oss/api` both produce `sbxclaude-api`. Lookup is purely by
name and the workspace is fixed at creation (verified: `sbx inspect` run from
`/tmp` still reports the sandbox's original workspace). So
`cd ~/oss/api && sbxclaude` attaches to `~/work/api`'s sandbox and silently
mounts **the wrong project**, with edits landing on the wrong host tree. That
is a correctness bug in the core path.

Add a short hash of the canonical path:

```bash
DIR="$(pwd -P)"        # canonical, so a symlink is not a second identity
SLUG="$(basename "${DIR}" | tr -c 'a-zA-Z0-9-' '-' | sed 's/-*$//')"
HASH="$(printf '%s' "${DIR}" | shasum -a 256 | cut -c1-6)"   # sha256sum fallback
SANDBOX="sbxclaude-${SLUG:+${SLUG}-}${HASH}"
```

Verified against real paths:

```text
/Users/lars/work/api        -> sbxclaude-api-48c03d
/Users/lars/oss/api         -> sbxclaude-api-7f8f66
/Users/lars/Code/sbxclaude  -> sbxclaude-sbxclaude-b6def4
/Users/lars/...             -> sbxclaude-217a55
```

- **Delete the empty-name guard** at `scripts/sbxclaude:15-18`. The hash is
  always non-empty, so even a directory named `...` (basename sanitizes to
  nothing) yields a valid unique name — verified above.
- `shasum -a 256` and `sha256sum` produce identical output here (both
  `b6def4`), so names do not drift between macOS and Linux CI.
- Keyed to `$PWD`, **not** the git root: a subdirectory gets its own sandbox.
- **One-time migration.** Existing sandboxes are orphaned, since their names no
  longer derive from their paths: `sbxclaude-sbxclaude` becomes
  `sbxclaude-sbxclaude-b6def4`. The old one keeps its session state until
  `sbx rm sbxclaude-sbxclaude`. Document this in the README.

## Expected size

The result is roughly **85–90 non-blank lines**, up from today's 58. The growth
is deliberate and buys:

- a real `usage()` (today's help is a one-line `echo`) — `AGENTS.md:13` points
  agents at `-h`, so this text is documentation-of-record
- arity checking, so extra arguments error instead of being silently dropped
- nested `kit`/`policy` dispatch
- path-hash naming
- the D1 and D2 fixes

If that trade is unwanted, the cheapest reversals are the `usage()` heredoc and
the arity helper.

## Files to change

- `scripts/sbxclaude` — rewrite naming and dispatch. Two small helpers (`die`,
  `no_args`) absorb the repetition; no `attach` helper is needed, since only
  the no-argument case attaches.
- `Makefile` — `--validate` → `kit validate`; add a `test` target.
- `README.md` — flag table becomes a command table; document the rebuild
  recipe, the naming migration, and that prompts, Claude flags, and `stop`
  require `sbx` or `claude` directly.
- `AGENTS.md` — "current flag list" → "command list"; add `make test`.
- `.github/workflows/ci.yml` — add a `make test` step to the lint job. It needs
  no real `sbx`, because the tests supply a fake one on `PATH`.
- `.claude/settings.local.json` — entries pinning `--validate`, `--inspect`,
  and `--exec` go stale and would reintroduce permission prompts.

## Tests (`tests/sbxclaude_test.sh`, new)

A fake `sbx` on `PATH` that appends its argv to a log file, so dispatch is
provable without touching a real sandbox:

- **Name derivation** (needs no `sbx` at all): two directories sharing a
  basename differ; the same directory is stable across runs; a symlink and its
  target agree; a basename that sanitizes to empty still yields a valid name.
- **Attach**: missing sandbox → `kit validate` then
  `run --name S --kit K AGENT`; existing sandbox → `run --name S` only. Assert
  neither call contains `--`.
- **`rm`** issues exactly one `sbx rm`, with **no** `--force`.
- **Arity**: `inspect extra`, `create extra`, bare `kit`, bare `policy`, and
  `policy check` with 0 or 2 arguments each emit **no** `sbx` call at all.
- **Unknown command** (`sbxclaude foo`) errors and emits no `sbx` call.
- **`exec`**: `-it` present under a pty, absent when stdin is a pipe; a leading
  `-` in the first token is rejected.
- **`policy check`** passes `--sandbox`.

## Verification

- `bash -n scripts/sbxclaude`, and `shellcheck --enable=all` on both the script
  and the test file.
- `make lint`, `make test`, `make validate-kit`.
- `cspell "**/*.md" "scripts/**" "sbxclaude/**/*.yaml"` — new command names may
  trip the dictionary.
- `./scripts/sbxclaude help` — commands, the destructive marker on `rm`, and
  the "use sbx directly" note.
- Live, read-only only: `inspect`, `policy log`, `policy check github.com`.
  Confirm D1 by comparing against `sbx policy check network github.com` with no
  `--sandbox`, which should give the global answer.
- **Do not** run `rm` against the live sandbox during verification.
