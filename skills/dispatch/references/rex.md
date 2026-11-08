# Rex workers

Use Rex only through `orc pane`; never infer success from a screen capture.
Pane mode is automatic inside Rex; `--no-panes` or `ORC_PANES=0` disables it.
Delegate scopers and implementers through Codex pane workers instead of native
subagents; reviewer and shipper stay native.

- Start: `orc pane start <feature> <task> --path <worktree> --brief <file> --role implementer [--transport tui|exec]`.
  Codex and implementer are defaults; use `--role scoper` for read-only scoping
  or `--kind claude` to choose Claude. Transport defaults to `tui`; `exec` is
  Codex-only, records JSONL/usage, and supports start/wait/close without steering.
- Wait: `orc pane wait <task> --path <worktree> --timeout 1800000`, using the
  harness's background execution (foreground Bash is capped at 10 minutes).
  If the prompt stays unacknowledged for 60 s (untrusted orc hooks), wait returns
  `state: "unacknowledged"` with a `hint`; trust the hooks and inspect the pane.
  Exec `state: "rate-limited"` includes a hint: close it, then restart the same
  brief/worktree with `--kind claude --transport tui`.
- Follow-up: `orc pane prompt <task> --path <worktree> --file <brief>` or `--text`.
  TUI only; exec follow-ups currently require close/start with a fresh thread.
- Close: `orc pane close <task> --path <worktree>`. If Rex restarted or pane
  creation failed, close and start refuse the stranded record; after checking the
  pane is gone, add `--force` to mark it closed without touching Rex.
- Prune: `orc pane prune --path <checkout>` closes successful exits and idle/done
  workers with a matching done report and validation evidence across that repository.
  It uses non-force close checks and per-task locks; JSON lists closed and skipped workers.

Keep returned session/block/run IDs. `not-sent`, blocked or unconfirmed delivery
is not success: surface the pane to the user and inspect current state before
retrying. Never answer permission, auth or trust dialogs for the user.
Only the report belonging to the current run can be accepted; review its actual
Status and Validation. `idle`, `done` program status and exit zero are insufficient.
Close only panes created for your task. Closing Neovim leaves workers running.

For a single task use `start --here --path <session checkout>`; the orchestrator
does not edit beside its implementer. Scopers never claim checkout ownership.
Pair mode uses one Codex implementer at a time in that checkout. Review the diff
and rerun validation before closing. Parallel work uses dispatch task worktrees.
