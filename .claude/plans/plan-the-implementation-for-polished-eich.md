# Escalate blocked network requests instead of working around them

## Context

The sandbox allowlists network egress. When a request is blocked, the proxy
returns HTTP 403 with a structured body, and `agentInstructions` in
`sbxclaude/spec.yaml` (lines 39-42) tells the agent to stop and ask the user to
run `sbx policy allow network "<host>"` on the host.

That instruction is advice. In practice Claude Code reads the 403, decides the
task can proceed some other way, and silently works around it. The user never
learns a host needs allowlisting.

Fix: make the escalation mechanical rather than advisory. A `PostToolUse` /
`PostToolUseFailure` hook inspects tool output, and on a proxy block it **ends
the turn** and **prints a message to the user's terminal**. The agent does not
get a vote.

The hook is installed as **managed settings** (`/etc/claude-code/managed-settings.json`),
root-owned, so the agent cannot disable its own guard by accident or by ordinary
file edits. It is not tamper-proof — see *Known trade-offs*.

## Design

Both artifacts are written by a single root `setup.install` command in
`spec.yaml`. Nothing goes through `sbxclaude/files/`, which lands in `$HOME`
and is agent-writable.

| Artifact | Path in sandbox | Owner |
|---|---|---|
| Guard filter | `/usr/local/lib/sbxclaude/network-block.jq` | root, 0644 |
| Hook config | `/etc/claude-code/managed-settings.json` | root, 0644 |

The guard is a **jq filter**, not a shell script: the hook contract is
JSON-in / JSON-out, so jq does the whole job with no shell quoting and no
executable-bit dependency. `jq` is already installed (`spec.yaml` line 89).

### Detection

The hook input shape is only documented for `PostToolUse`
(`{session_id, tool_name, tool_input, tool_response}`). `PostToolUseFailure`
reports the failure elsewhere — a top-level `.error` string — and for `Bash`
the success payload is structured (`{stdout, stderr, interrupted, isImage}`).

So do **not** name a field. Collect every nested string from the whole input
*except* `.tool_input`, and join:

```jq
def haystack: [ (del(.tool_input) | .. | strings) ] | join("\n");
```

This covers `.tool_response`, `.error`, and any field naming that changes
under us. `.tool_input` is excluded because it is the skip-list source and
would otherwise self-match.

Match that against the three proxy block shapes. These are documented in
`/Users/lars/Code/CLAUDE.md` — the parent-directory instructions one level
*above* this repo, not in `sbxclaude/AGENTS.md`, which has no network section.
Treat that file as the source of truth if the wording ever changes:

- `Blocked by network policy: domain <host>`
- `Blocked by local rule for <host>`
- `Blocked by org policy`

Extract `<host>` where present; fall back to `an allowlisted host`.

**Skip list** (avoid false positives). Stringify *all* of `.tool_input` — not
just `.tool_input.command`, since `WebFetch` passes `{url, prompt}` and a fetch
of documentation containing these strings must also be skipped:

```jq
[ (.tool_input // empty) | .. | strings ] | join(" ")
```

Bail out when that matches this repo's own docs or the guard's own tests, which
contain the literal block strings:

`AGENTS\.md|CLAUDE\.md|network-block|toolchain_test`

### Output

```json
{
  "continue": false,
  "stopReason": "Sandbox network policy blocked <host>. Stopping — do not retry, mirror, vendor, or otherwise work around this. The user must allowlist the host.",
  "systemMessage": "Blocked host: <host>\nRun on your host:  sbx policy allow network \"<host>\""
}
```

- `continue: false` ends the turn — this is the enforcement, and it is the one
  universal mechanism across all four candidate events.
- `stopReason` carries the "don't work around it" wording.
- `systemMessage` prints to the user's terminal regardless of what the agent does.
- No match emits `{}`, a no-op.

Deliberately **no** `decision: "block"` / `reason`. On `PostToolUse` that would
end the turn too, but stacking two mechanisms with different per-event
semantics makes the behaviour harder to reason about. One primary mechanism.

### Hook registration

Registered on **both** events under matcher `Bash|WebFetch`:

- `PostToolUse` — tool succeeded (e.g. `curl` printed the 403 body but exited 0)
- `PostToolUseFailure` — tool failed (`curl -f`, `npm install`, `pip` on a block)

`PostToolUseFailure` is the common case and is easy to miss; omitting it would
let most real blocks through.

Target shape for `/etc/claude-code/managed-settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Bash|WebFetch",
      "hooks": [{
        "type": "command",
        "command": "jq -f /usr/local/lib/sbxclaude/network-block.jq",
        "timeout": 5
      }]
    }],
    "PostToolUseFailure": [{
      "matcher": "Bash|WebFetch",
      "hooks": [{
        "type": "command",
        "command": "jq -f /usr/local/lib/sbxclaude/network-block.jq",
        "timeout": 5
      }]
    }]
  }
}
```

**Open question — does `continue: false` actually stop the turn on
`PostToolUseFailure`?** The docs conflict: `continue: false` is documented
universally as halting processing, but `PostToolUseFailure` decision control
only documents `additionalContext`, and prompt-hook docs say a
`PostToolUseFailure` block feeds back to the model and the turn *continues*.
Resolve empirically during implementation via the E2E test below.

**If it does not stop**: add `PostToolBatch` as a backstop. It is a real event
in the settings schema and explicitly supports `continue: false` to halt the
agentic loop before the next model call. It takes no matcher, so the same jq
filter runs on every tool batch — acceptable, since a non-matching run is one
cheap jq invocation emitting `{}`.

## Files to change

1. **`sbxclaude/spec.yaml`** — one new `setup.install` entry (runs as root,
   like the existing `CLI tools` and `sbx CLI` entries), writing both files via
   heredocs. Add `description: Network-block escalation hook`.

2. **`sbxclaude/spec.yaml`, `agentInstructions` lines 39-42** — add one line
   noting the guard is enforced by a hook, so the behaviour is visible in the
   agent's own context, not just at the kit level.

3. **`tests/toolchain_test.sh`** — new cases following the existing
   `check_tool` / `pass` / `fail` pattern:
   - `/etc/claude-code/managed-settings.json` exists and is valid JSON
   - it registers the hook on both `PostToolUse` and `PostToolUseFailure`
   - a `PostToolUse` fixture — block string under
     `.tool_response.stderr` — yields `continue == false` and a
     `systemMessage` naming the host
   - a `PostToolUseFailure` fixture — block string under a top-level
     `.error` — yields the same result
   - piping a clean fixture yields `{}`
   - the skip list fires for a Bash `.tool_input.command` mentioning
     `CLAUDE.md`, **and** for a WebFetch `.tool_input.url` pointing at
     `AGENTS.md`

4. **`CHANGELOG.md`** — under `## [Unreleased]` → `### Added`.

5. **`.cspell.json`** — add any new words the linter rejects (likely
   `stopReason`, `systemMessage`, `PostToolUse`).

## Verification

```bash
make lint                 # markdownlint, jq, yamllint, shellcheck, cspell
make validate             # kit schema check — required, touches spec.yaml
./scripts/sbxclaude       # rebuild the sandbox so setup: re-runs
make test-toolchain       # runs the new cases inside the live sandbox
```

Then two live end-to-end checks inside the rebuilt sandbox, against a host that
is not on the allowlist. **Both paths must be exercised** — they hit different
hook events:

| Command | Exits | Event | Expected |
|---|---|---|---|
| `curl -sS https://example.org` | 0 (body printed) | `PostToolUse` | turn ends |
| `curl -f https://example.org` | non-zero | `PostToolUseFailure` | turn ends |

Expected terminal output in both cases:

```
Blocked host: example.org
Run on your host:  sbx policy allow network "example.org"
```

If the `curl -f` case does **not** end the turn, `continue: false` is not
honoured on `PostToolUseFailure` — apply the `PostToolBatch` backstop from
*Hook registration* and re-run this check.

Finally, confirm the guard is not casually removable:
`rm /etc/claude-code/managed-settings.json` without `sudo` must fail with
`Permission denied`.

## Known trade-offs

- **Not tamper-proof.** The sandbox grants passwordless `sudo`, so an agent
  that decides to can run `sudo rm /etc/claude-code/managed-settings.json` or
  `sudo tee /usr/local/lib/sbxclaude/network-block.jq` and disable the guard.
  Root ownership raises the bar from *silent workaround* to *deliberately
  disabling a policy file* — a visible, deliberate act rather than a quiet
  one. That is the actual goal here. Real tamper-proofing would need
  host-level policy outside the sandbox, which is out of scope for this change.
- **Blast radius.** A block anywhere in a long task ends the whole turn. That
  is the point, but it will occasionally interrupt work that could have
  continued.
- **Lint coverage.** The jq filter lives in a `spec.yaml` heredoc, so
  `make lint` does not check it. `make test-toolchain` covers it instead, by
  exercising the actually-installed file.
- **Detection is string-based.** It only fires when the 403 body reaches the
  tool output. A tool that swallows the response body (e.g. `curl -f -s` with
  no `-S`) will not trigger the guard.
