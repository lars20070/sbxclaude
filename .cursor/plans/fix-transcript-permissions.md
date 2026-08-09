---
name: fix-transcript-permissions
overview: Determine why Claude’s persistent state volumes are mounted root-owned, then add a startup gate that normalizes their ownership before Claude can write transcripts. Verify the fix in a disposable sandbox and document the rebuild requirement for existing sandboxes.
todos:
  - id: isolate-cause
    content: Reproduce the root-owned Claude state volumes in a disposable sandbox and identify their source
    status: pending
  - id: gate-startup
    content: Add an idempotent entrypoint launcher that repairs state-volume ownership before executing Claude
    status: pending
  - id: verify-fix
    content: Validate the kit and test transcript writes across clean start and reattach
    status: pending
  - id: document-fix
    content: Update the changelog and rebuild guidance
    status: pending
isProject: true
---

# Fix Claude transcript permissions

## 1. Reproduce and isolate the ownership failure
- Create a disposable sandbox from the current kit and record the Claude process UID, mount sources, modes, and owners for `/home/agent/.claude/{projects,sessions,shell-snapshots,statsig,todos}`.
- Compare the inherited `claude` kit behavior with this repository’s composed kit to establish whether the root-owned block-volume mount points originate upstream or from local configuration.
- Confirm the exact failure by checking whether UID 1000 can create the project transcript directory, without altering the user’s existing sandbox.

## 2. Gate Claude startup on safe ownership repair
- Update [sbxclaude/spec.yaml](/Users/lars/Code/sbxclaude/sbxclaude/spec.yaml) to install/use a small runtime launcher as the sandbox entrypoint.
- Have the launcher idempotently change only the known Claude state mount roots to UID/GID 1000, skipping absent paths and avoiding recursive ownership changes, then replace itself with `claude` via `exec` while forwarding all arguments.
- Use an entrypoint gate rather than an asynchronous `setup.startup` repair so Claude cannot race transcript initialization against the ownership change.

## 3. Verify on a clean sandbox
- Run `make validate` as required for changes to the kit spec/files.
- Build a uniquely named disposable sandbox, verify every repaired state directory is writable by `agent`, launch Claude from the repository root, and confirm a transcript is created without the EACCES warning.
- Reattach/restart the disposable sandbox to prove the repair is idempotent, then remove it.
- Run `make test` and `make lint` to catch wrapper or repository-wide regressions.

## 4. Document the user-facing fix
- Add a `Fixed` entry under `Unreleased` in [CHANGELOG.md](/Users/lars/Code/sbxclaude/CHANGELOG.md).
- Add a concise troubleshooting/rebuild note to [README.md](/Users/lars/Code/sbxclaude/README.md), explaining that existing per-project sandboxes must be removed and recreated because kit changes are only applied at sandbox creation.
