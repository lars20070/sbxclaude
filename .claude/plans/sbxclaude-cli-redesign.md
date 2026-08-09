# Redesign `sbxclaude` as subcommands mirroring `sbx`

## Context

The wrapper's flags grew one at a time across this session and were never
designed as a set. The user asked whether to rename/reconfigure them for
internal consistency *and* similarity to `sbx`, then chose to go further:
**switch from flags to subcommands**, with prompts required to be quoted.

A 13-agent design panel informed this plan. **It partially failed — the monthly
spend limit was hit after 5 of 13 agents**, so this is my synthesis of the
completed work plus the user's decisions, not the panel's output.

A subsequent review (`.cursor/plans/sbxclaude-cli-redesign-review.md`) found two
blockers and two further defects in the first draft. **All four were verified
and are incorporated below** — see "Review fixes applied".

Every factual claim was verified live against `sbx` v0.38.0 and this repo.

### Why subcommands are viable here

Subcommands collide with free text: a bare argument is a prompt, and imperative
verbs (`create`, `inspect`, `stop`) are exactly how prompts begin. Requiring
prompts to be quoted resolves most of this, but **not by detecting quotes** —
the shell strips them before the script runs. Verified:

```text
sbxclaude "fix the test"   ->  $# = 1   $1 = [fix the test]
sbxclaude fix the test     ->  $# = 3   $1 = [fix]
sbxclaude "rm"             ->  $# = 1   $1 = [rm]     <- identical to...
sbxclaude rm               ->  $# = 1   $1 = [rm]     <- ...this
```

So quoting is detectable for *multi-word* prompts (via `$#`) but **not for
one-word prompts**, which are byte-identical to a subcommand. That gap is why
rule 2 below exists.

### Dispatch rules (evaluated in order)

1. **No args** → the attach path (below).
2. **`$1` is `--`** → everything after is prompt/agent args, never a
   subcommand. This is the escape hatch for one-word prompts that collide with
   command names: `sbxclaude -- rm`. Must be checked *before* rule 4, since
   `--` starts with a dash.
3. **`$1` is `-h`/`--help`** → grouped help text.
4. **`$1` starts with `-`** → *not ours*: forward all args to Claude Code via
   the attach path. Preserves `sbxclaude --resume`, `--model opus`, `-c`, `-p`,
   which work today. Breaking this would be a real regression — the panel found
   a design where `sbxclaude --resume` errored and suggested the command that
   *destroys* the session being resumed.
5. **`$1` matches a known subcommand** → dispatch, enforcing arity. A zero-arg
   subcommand given extra args is an **error**, never a silent no-op:
   `sbxclaude create a test` → *"create takes no arguments; to send a prompt,
   quote it or use --"*.
6. **`$# -eq 1`** → prompt.
7. **`$# -gt 1`** → error: *"Multi-word prompts must be quoted."*

Rule 7 is the deliberate cost: unquoted multi-word prompts stop working, failing
loudly with a message naming the fix rather than silently running a lifecycle
operation.

### Sandbox naming (resolved: path hash)

Lookup is **purely by name** — the workspace is fixed at creation and returned
regardless of cwd (verified: `sbx inspect` from `/tmp` reports the original
workspace). So today `cd ~/oss/api && sbxclaude` derives `sbxclaude-api`,
finds `~/work/api`'s sandbox, and silently mounts **the wrong project**. That
is a correctness bug in the core path, not just a hazard for `rm`.

Names become `sbxclaude-<slug>-<hash6>`:

```bash
DIR="$(pwd -P)"        # canonical, so a symlinked path is not a 2nd identity
SLUG="$(basename "${DIR}" | tr -c 'a-zA-Z0-9-' '-' | sed 's/-*$//')"
HASH="$(printf '%s' "${DIR}" | shasum -a 256 | cut -c1-6)"
SANDBOX="sbxclaude-${SLUG:+${SLUG}-}${HASH}"
```

Verified against real paths:

```text
/Users/lars/work/api        -> sbxclaude-api-48c03d
/Users/lars/oss/api         -> sbxclaude-api-7f8f66
/Users/lars/Code/sbxclaude  -> sbxclaude-sbxclaude-b6def4
/Users/lars/...             -> sbxclaude-217a55
```

- **The empty-name guard at `scripts/sbxclaude:15-18` can be deleted.** The
  hash is always non-empty, so even a directory named `...` (basename
  sanitizes to nothing) yields a valid unique name — verified above.
- `shasum -a 256` is macOS base; fall back to `sha256sum` where it is absent.
  CI runs the wrapper via `make validate-kit`, so this must work on Linux too.
- 6 hex chars = 24 bits, ample here; widen to 8 if it ever feels tight.
- Name stays inside sbx's charset (letters, numbers, hyphens).
- Naming remains keyed to `$PWD`, **not** the git root (decided): running from
  a subdirectory still creates its own sandbox.

**Migration (one-time, unavoidable).** Every existing sandbox is orphaned,
since its name no longer derives from its path. Today's
`sbxclaude-sbxclaude` becomes `sbxclaude-sbxclaude-b6def4`; the old one
survives with its session state until removed with
`sbx rm sbxclaude-sbxclaude`. Call this out in the README so it is not a
surprise.

### The attach path (used by rules 1, 2, 4 and 6)

`sbx run`'s agent positional is optional **only when the sandbox already
exists** (verified in `sbx run --help`). So attaching is always two-branch —
this is the current script's logic and it must be preserved:

```bash
if sbx inspect "${SANDBOX}" >/dev/null 2>&1; then
    exec sbx run --name "${SANDBOX}" -- "$@"                     # re-attach
fi
sbx kit validate "${KIT}" >/dev/null
exec sbx run --name "${SANDBOX}" --kit "${KIT}" "${AGENT}" -- "$@"  # create
```

### `rebuild` removed (decided)

`rebuild` was exactly `rm` followed by the attach path. Dropping it is a net
simplification, not just one fewer name:

- **The attach rule becomes exception-free.** No subcommand attaches, so P3
  (unpredictable attach behaviour) is *dissolved* rather than documented.
- **It eliminates D3's bug class by construction.** `rebuild` was the only
  command that did work and then fell through to the bottom of the script;
  without it, no command can complete destructive work before a later
  argument error surfaces.
- **Cost:** one extra step for a rare operation.

The replacement is two commands:

```bash
sbxclaude rm   # confirms (y/N) — rm keeps sbx's own prompt
sbxclaude      # recreates from the kit and attaches
```

Document that recipe in the README where `--rebuild` used to be. For a
non-interactive rebuild, `sbx rm --force <name>` is the direct route; the
wrapper deliberately offers no force path of its own.

### Answer to the user's original example: reject `--create` → `--build`

`sbx create` exists and means create-without-attaching — precisely what this
does, making `create` the tool's best-aligned name. `--build` would falsely
imply image-building, which is what the kit's `setup.install` actually does.
All four panelists reached this independently.

## The interface

| New | Was | Runs |
| --- | --- | --- |
| (no args) | same | attach path |
| `"PROMPT"` | same | attach path, prompt as agent arg |
| `-- ARGS...` | (new) | attach path; forces prompt interpretation |
| `-<anything>` | (implicit) | attach path; forwarded to Claude Code |
| `exec CMD...` | `-e`, `--exec` | `sbx exec [-it] S -- CMD...` |
| `inspect` | `-i`, `--inspect` | `sbx inspect S` |
| `create` | `--create` | `sbx create --name S --kit K AGENT .` |
| `rm` | (new) | `sbx rm S` — **no `--force`**, sbx confirms |
| `stop` | (new) | `sbx stop S` |
| `kit validate` | `-v`, `--validate` | `sbx kit validate K` |
| `kit add` | `--reload` | `sbx kit add S K` |
| `policy log` | `-l`, `--log` | `sbx policy log S` |
| `policy check HOST` | `--check` | `sbx policy check network --sandbox S H` |
| `help`, `-h`, `--help` | same | grouped help text |

`--rebuild` is **retired** with no replacement command — see above.

`-it` on `exec` stays **conditional on `[[ -t 0 ]]`**, as today — allocated for
an interactive terminal, omitted for pipes and automation.

Two-word commands are **nested** (decided), matching sbx's structure. The two
`kit` commands are syntactically uniform but semantically asymmetric:
`kit validate` is a static file check needing no sandbox, no Docker and no
network, while `kit add` **recreates the container** — kit-owned volumes
(session state) survive, running processes do not — and refuses sandboxes
lacking the recreate-aware label. Nothing in either name signals that, so the
grouped help text must carry an explicit marker (e.g. `[recreates]`,
`[destroys]`) on every command that is not read-only. That marker is the
mitigation for putting a safe and a disruptive command in one namespace.

All short flags except `-h` are deleted, not reassigned — `-e`/`-i` collided
with `sbx exec`'s own `-e` (env) and `-i` (interactive), and `-v` universally
means `--version`.

**Scope of the sbx resemblance (honest limit):** the wrapper exposes the fixed
signatures above; it does **not** forward arbitrary sbx flags. `inspect --json`,
`policy log --json`, and `exec -w` are not supported — use `sbx` directly for
those. The help text must say this, so "mirrors sbx" is not over-promised.

**Attach rule (exception-free):** a bare invocation, `--`, a prompt, and
unrecognised `-flags` attach. **Every subcommand runs and exits** — none falls
through. State this in `--help`; `AGENTS.md:13` tells agents to trust `-h` over
prose, so the help text is documentation-of-record.

## Review fixes applied

- **R1 (blocker).** One-word prompts are indistinguishable from subcommands
  (`sbxclaude "rm"` ≡ `sbxclaude rm`) — verified. Without an escape, a quoted
  prompt could force-delete the sandbox. Fixed by the `--` escape (rule 2).
- **R2 (blocker).** The first draft mapped a bare invocation to
  `sbx run --name S`, losing the inspect/create fallback, so first use would
  fail. Fixed by making the two-branch attach path explicit and reusing it for
  every attaching route.
- **R3.** The draft acknowledged the directory-name collision and then specified
  `rm --force` anyway. Fixed twice over: naming is now collision-free by
  construction (see "Sandbox naming"), **and** `rm` drops `--force` so sbx's own
  confirmation stands — destroying session state deserves one y/N even when the
  target is unambiguous.
- **R4.** The draft showed unconditional `sbx exec -it`, which would regress the
  tty gate added earlier this session, and claimed an sbx fidelity the
  leading-dash rejection does not deliver. Fixed in the table and in the
  "Scope of the sbx resemblance" note.

## Behaviour fixes (verified defects, independent of naming)

- **D1 — real bug.** `sbx policy check network` accepts `--sandbox`; the wrapper
  never passes it (`scripts/sbxclaude:27`). So `--check` reports on **global**
  policy while `--log` reports on **this sandbox** — a visual pair that silently
  disagrees about scope. Fix: pass `--sandbox "${SANDBOX}"`.
- **D2.** `exec` forwards everything past `--`, so `sbxclaude exec -w /src ls`
  becomes `sbx exec -it S -- -w /src ls` → `exec: "-w": not found`, which reads
  as a broken sandbox. Fix: if the first token after `exec` starts with `-`,
  exit non-zero explaining that sbx-exec flags are not forwarded.
- **D3 — now eliminated by construction.** Today `--rebuild --exec bash`
  deletes the sandbox, then passes `--exec bash` to Claude as arguments:
  destructive work completes before the mistake surfaces. With `rebuild` gone
  no command falls through, so this cannot recur. The arity check is still
  required — `rm foo` must error rather than silently ignore `foo` — but it no
  longer guards a destructive fall-through.
- **D5.** `sbx policy log --type` covers `network` *and* `filesystem`, so this is
  the **policy** log, not a network log — `net-log` would be wrong going
  forward. `policy log` is sbx-exact and future-proof.

## Implementation approach: plain bash, no new dependencies

`argc` (a bash CLI framework, `brew install argc`) was evaluated and rejected.
Two of its properties are disqualifying here:

- **No unknown-flag passthrough.** Its full `@meta` table has no
  ignore-unknown or passthrough option; argc exists to validate and reject
  undeclared input. Dispatch rule 4 needs the opposite — `--resume`,
  `--model opus`, `-c`, `-p` must reach Claude Code untouched.
- **No free-text bare argument alongside subcommands.** Once `@cmd` is
  declared, an unrecognised bare word is an unknown-subcommand error; rule 6
  needs it treated as a prompt. `@arg x~` captures trailing args but is not a
  root-level catch-all that coexists with subcommand dispatch.

Working around both means capturing everything with `@arg rest~` and
hand-parsing anyway, leaving argc contributing nothing but help text.

Secondary costs: a new CI install step (`ubuntu-latest` has no argc, and the
workflow runs the wrapper via `make validate-kit`); `eval "$(argc
--argc-eval ...)"` yields `argc_*` variables shellcheck cannot see, so SC2154
would fire under this repo's `--enable=all` rule; and thin adoption (44
installs in 30 days) makes it a bus-factor risk for a tool whose job is to be
dependable.

The complete parser — nested `kit`/`policy` dispatch, arity enforcement, the
tty gate, the `--` escape, multi-word rejection, and the shared attach path —
is **39 non-blank lines** of valid bash, kept readable by three helpers:
`die`, `no_args`, and `attach`. Dependencies stay `bash` + `sbx`.

If tab-completion later becomes the real motivation, prefer a hand-written
completion file over adopting a framework.

## Files to change

- `scripts/sbxclaude` — name derivation (lines 14-19: add the hash, delete the
  empty-name guard); parser and dispatch; factor the attach path into a
  function shared by rules 1/2/4/6.
- `Makefile:16` — `--validate` → `kit validate`.
- `README.md:16-64` — the "named `sbxclaude-<project_directory>`" line is now
  wrong and must describe the hash suffix; flag table becomes a command table;
  document the quoted-prompt rule, the `--` escape, the exception-free attach
  rule, the fidelity limit, the `rm` + bare-run rebuild recipe, and the
  one-time orphaned-sandbox migration.
- `AGENTS.md` — line 13 says the wrapper "creates, rebuilds, and re-attaches";
  "rebuilds" now names a command that does not exist, so this must change (not
  merely be checked). Also "current flag list" → "command list".
- `.claude/settings.local.json` — lines 17, 29, 30, 55, 56 pin
  `--validate`/`--inspect`/`--exec`; stale entries mean permission prompts
  return for already-approved commands.

## Verification

Destructive paths cannot be exercised against the live sandbox, so dispatch is
verified with a **fake `sbx` on `PATH` that records its argv** (the review's
point 5). This is the only way to prove first-run creation and
arity-rejection-before-side-effects without destroying real state.

- Fake-`sbx` cases: first-run creation (missing sandbox → validate + create
  branch); re-attach (existing → `run --name`); `rm` issues exactly one
  `sbx rm` with **no** `--force`; arity rejection emits **no** `sbx` call at
  all; `exec` tty-gating with stdin a tty vs a pipe; `--` forcing prompt
  interpretation of `rm`; and that **no subcommand ever reaches the attach
  path** (the exception-free attach rule).
- Name derivation, checkable without sbx at all: two directories sharing a
  basename must yield different names; the same directory must be stable across
  runs; a symlinked path and its target must agree; a directory whose basename
  sanitizes to empty (e.g. `...`) must still produce a valid name.
- `bash -n scripts/sbxclaude` and `shellcheck --enable=all scripts/sbxclaude`.
- `make lint`, `make validate-kit` (exercises `kit validate` via the Makefile),
  and `cspell "**/*.md" "scripts/**" "sbxclaude/**/*.yaml"` (review's minor
  note — new command names may trip the dictionary).
- `./scripts/sbxclaude --help` — grouped output, destructive markers, attach
  rule, quoting rule, fidelity limit.
- Live read-only only: `inspect`, `policy log`, `policy check github.com` —
  confirm D1 by comparing against `sbx policy check network github.com` with no
  `--sandbox`, which should give the *global* answer.
- Passthrough regression: an unknown `-flag` must still reach Claude, not error.
- **Do not** run `rm` or `stop` against the user's live sandbox.

## Must resolve during implementation

**Is `sbx kit add` idempotent?** Its help says the container is recreated "with
the new kit **appended to its original kit list**" — an append, not a replace.
The wrapper re-adds the *same* kit to refresh it, so if the list accumulates
(or `setup.install` re-runs on every add), the whole reload story rests on an
operation not designed for repetition. Static inspection of the sbx binary
found no dedup strings either way, so this needs an empirical check: run
`kit add` twice against a scratch sandbox and compare the `Kits:` line from
`sbx inspect` before and after. If it accumulates, `kit add` is the wrong
primitive and the honest refresh is `rm` followed by a bare run.

## Decisions

All resolved: subcommands over flags; quoted-prompt rule with a `--` escape;
sandbox naming by path hash, `$PWD`-keyed and not git-root anchored; nested
two-word commands; `rebuild` removed; plain bash with no new dependencies
(`argc` evaluated and rejected).
