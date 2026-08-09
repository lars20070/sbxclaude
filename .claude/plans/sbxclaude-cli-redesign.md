# Redesign `sbxclaude` as subcommands mirroring `sbx`

## Context

The wrapper's flags grew one at a time across this session and were never designed
as a set. The user asked whether to rename/reconfigure them for internal
consistency *and* similarity to `sbx`, then chose to go further: **switch from
flags to subcommands**, with prompts required to be quoted.

I ran a 13-agent design panel (proposals → adversarial critiques → synthesis).
**It partially failed — the monthly spend limit was hit after 5 of 13 agents.**
All 4 proposals and 1 critique completed; 7 critiques and the synthesis were
killed. This plan is my own synthesis of the completed work plus the user's
subsequent decisions, not the panel's output.

Every factual claim below was verified live against `sbx` v0.38.0 and this repo.

### Why subcommands are viable here (the mechanism the user asked for)

Subcommands were the one design the panel warned against, because a bare argument
is a free-text prompt and imperative verbs (`create`, `inspect`, `stop`) are
exactly how prompts begin. The user's fix — require prompts to be quoted —
resolves it, but **not by detecting quotes**: the shell strips them before the
script runs. Verified empirically:

```text
sbxclaude "fix the test"   ->  $# = 1   $1 = [fix the test]
sbxclaude fix the test     ->  $# = 3   $1 = [fix]
```

So the enforceable form of "prompts must be quoted" is **"a prompt must arrive as
exactly one argument."** Same contract for the user, checkable with `$#`.

### Dispatch rules (evaluated in order)

1. **No args** → attach: `sbx run --name S`.
2. **`$1` starts with `-`** → *not ours*: forward everything to Claude Code
   (`sbx run --name S -- "$@"`), except `-h`/`--help`. This preserves
   `sbxclaude --resume`, `--model opus`, `-c`, `-p`, which work today because
   unrecognised args already fall through to the agent. Breaking this would be a
   real regression — the panel critique found a design where `sbxclaude --resume`
   errored and suggested the flag that *destroys* the session being resumed.
3. **`$1` matches a known subcommand** → dispatch, enforcing arity. A zero-arg
   subcommand given extra args is an **error**, never a silent no-op:
   `sbxclaude create a test` → *"create takes no arguments. To send a prompt,
   quote it: sbxclaude \"create a test\""*.
4. **`$# -eq 1`** → prompt.
5. **`$# -gt 1`** → error: *"Multi-word prompts must be quoted."*

Rule 5 is the deliberate cost of this design: unquoted multi-word prompts stop
working. They fail loudly with a message naming the fix, rather than silently
running a lifecycle operation.

### Answer to the user's original example: reject `--create` → `--build`

`sbx create` exists and means create-without-attaching — precisely what this does.
`--build` would falsely imply image-building (what the kit's `setup.install`
actually does) and would read as a sibling of `rebuild`, which differs materially.
All four panelists reached this independently. The subcommand is `create`.

## The interface

`sbxclaude X Y Z` runs `sbx X Y Z`, with the sandbox name and kit path filled in.

| New | Was | Runs |
| --- | --- | --- |
| (no args) | same | `sbx run --name S` — attaches |
| `"PROMPT"` | same | `sbx run --name S -- "PROMPT"` |
| `-<anything>` | (implicit) | forwarded to Claude Code |
| `exec CMD...` | `-e`, `--exec` | `sbx exec -it S -- CMD...` |
| `inspect` | `-i`, `--inspect` | `sbx inspect S` |
| `create` | `--create` | `sbx create --name S --kit K AGENT .` |
| `rebuild` | `--rebuild` | *composite:* `sbx rm --force S`, then attach |
| `rm` | (new) | `sbx rm --force S` |
| `stop` | (new) | `sbx stop S` |
| `kit validate` | `-v`, `--validate` | `sbx kit validate K` |
| `kit add` | `--reload` | `sbx kit add S K` |
| `policy log` | `-l`, `--log` | `sbx policy log S` |
| `policy check HOST` | `--check` | `sbx policy check network --sandbox S H` |
| `help`, `-h`, `--help` | same | grouped help text |

Two-word commands are **nested**, matching sbx's real structure. All short flags
except `-h` are deleted, not reassigned — `-e`/`-i` collided with `sbx exec`'s
own `-e` (env) and `-i` (interactive), and `-v` universally means `--version`.

**Attach rule:** only a bare invocation and `rebuild` attach; every other
subcommand runs and exits. `rebuild` is now honestly describable as "`rm`, then
a bare run". State this in `--help` — `AGENTS.md:13` tells agents to trust `-h`
over prose, so the help text is documentation-of-record.

## Behaviour fixes (verified defects, independent of naming)

- **D1 — real bug.** `sbx policy check network` accepts `--sandbox`; the wrapper
  never passes it (`scripts/sbxclaude:27`). So `--check` reports on **global**
  policy while `--log` reports on **this sandbox** — a visual pair that silently
  disagrees about scope. Fix: pass `--sandbox "${SANDBOX}"`.
- **D2.** `exec` hardcodes `-it` and forwards everything past `--`, so
  `sbxclaude exec -w /src ls` becomes `sbx exec -it S -- -w /src ls` →
  `exec: "-w": not found`, which reads as a broken sandbox; `-d` can never work.
  Fix: if the first token after `exec` starts with `-`, exit non-zero explaining
  the wrapper sets the tty itself and sbx-exec flags are not forwarded.
- **D3.** A second operation is silently swallowed today: `--rebuild --exec bash`
  deletes the sandbox, then passes `--exec bash` to Claude as arguments. The new
  arity check must reject this **before** any destructive work runs.
- **D5.** `sbx policy log --type` covers `network` *and* `filesystem`, so this is
  the **policy** log, not a network log — naming it `net-log` would be wrong
  going forward. `policy log` is both sbx-exact and future-proof.

## Files to change

- `scripts/sbxclaude` — the parser and dispatch (the whole `case` block).
- `Makefile:16` — `--validate` → `kit validate`.
- `README.md:36-64` — flag table becomes a command table; add the
  quoted-prompt rule and the attach rule; update the `exec` example.
- `AGENTS.md` — verify the "creates, rebuilds, and re-attaches" wording at
  line 13 still holds.
- `.claude/settings.local.json` — lines 17, 29, 30, 55, 56 pin
  `--validate`/`--inspect`/`--exec`; stale entries mean permission prompts
  return for already-approved commands.

## Verification

- `bash -n scripts/sbxclaude` and `shellcheck --enable=all scripts/sbxclaude`.
- `make lint` and `make validate-kit` (exercises `kit validate` via the Makefile).
- `./scripts/sbxclaude --help` — grouped output, attach rule, quoting rule.
- Read-only commands against the live sandbox: `inspect`, `policy log`,
  `policy check github.com` — and confirm D1 is genuinely fixed by comparing
  against `sbx policy check network github.com` (no `--sandbox`), which should
  give the *global* answer.
- Error paths, all non-destructive — each must fail **without** side effects:
  - `create a test` → arity error naming the quoting fix
  - `fix the test` (unquoted) → "multi-word prompts must be quoted"
  - `exec -w /src ls` → refuses with the new message
  - `rebuild exec bash` → refuses, and `inspect` afterwards confirms the sandbox
    still exists
- Passthrough regression: an unknown `-flag` must still reach Claude, not error.
- **Do not** run `rm`, `rebuild`, or `stop` against the user's live sandbox
  during verification — they destroy or halt real session state.

## Open questions

1. **Nested (`kit validate`) vs hyphenated (`kit-validate`).** Nested is exactly
   sbx's structure and was chosen for fidelity; hyphenated is materially simpler
   to parse in bash and still derivable. Easy to switch if the nested dispatcher
   proves fiddly.
2. **Is `rebuild` worth keeping** once `rm` exists, given it is exactly `rm`
   plus a bare run? It costs one name and the sole attach-rule exception.
3. **Directory-name collision.** `~/work/api` and `~/oss/api` both derive
   `sbxclaude-api`. Adding `rm`/`stop` makes this materially more dangerous: a
   confirmation prompt naming the sandbox cannot disambiguate, since both produce
   the identical name. Worth a `name` command (print the derived name) or an
   explicit target override before, or alongside, the destructive commands.
