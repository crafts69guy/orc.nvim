# Rex workers

Use Rex only through `orc pane`; never infer success from a screen capture.
Pane mode is automatic inside Rex; `--no-panes` or `ORC_PANES=0` disables it.
Delegate scopers and implementers through Codex pane workers instead of native
subagents; review follows the orchestrator rules' cross-vendor rule; shipper stays native.

For a Codex-written diff under a Codex orchestrator, run the read-only Claude
review with the harness's background execution and save stdout/stderr under
`.scratch/<feature>/`:

```sh
claude -p --permission-mode plan --tools Read,Grep,Glob,Bash --append-system-prompt 'Review only; do not edit files.' 'Review the uncommitted diff against the task brief; report concrete findings.'
```

- Start: `orc pane start <feature> <task> --path <worktree> --brief <file> --role implementer [--transport tui|exec]`.
  Codex and implementer are defaults; use `--role scoper` for read-only scoping
  or `--kind claude` to choose Claude. Transport defaults to `tui`; `exec` is
  Codex-only, records JSONL/usage, and supports start/wait/close without steering.
  Workers start no MCP servers; add `--mcp <name,...>` only when the brief needs
  one (for example `--mcp figma` for a design task).
- Wait: `orc pane wait <task> --path <worktree> --until report --timeout 1800000`, using the
  harness's background execution (foreground Bash is capped at 10 minutes).
  Waits for the current run's report with Status and Validation, a native user-action
  block, process exit/error or timeout. Missing evidence never ends this wait.
  After five idle minutes without that report it returns `turn-ended-no-report` with a hint.
  Plain wait can return `turn-ended-no-report` or, after 60 s without acknowledgment,
  `unacknowledged`; inspect the pane and trust the hooks before retrying.
  A running wait follows follow-ups (`prompt`, with or without `--queue`, and `review`)
  to the newest run; `previousRuns` lists each replaced run's `runId`, `report` (or
  null) and `status`. Do not start a second wait while one is running; after a wait
  returns, start a new one for the next follow-up.
  Failures return `state: "wait-failed"` with `stderr` and a `hint`; follow the hint.
  Exec `state: "rate-limited"` includes a hint: close it, then restart the same
  brief/worktree with `--kind claude --transport tui`.
- Follow-up: `orc pane prompt <task> --path <worktree> --file <brief>` or `--text`.
  Add `--queue` for an acknowledged working TUI: Codex queues with Tab, Claude with
  Enter. `queued` still awaits UserPromptSubmit; inspect before any resend.
  The queued run is current at once: a running wait keeps going and returns the
  queued run's report, with the first turn's report in `previousRuns`.
  TUI only; exec follow-ups currently require close/start with a fresh thread.
- Review: `orc pane review <task> --path <worktree> [--skill ponytail-review|ponytail-audit] [--target <range|paths>]`
  sends an idle worker a read-only review turn: the reviewer role, the skill per kind
  (`$ponytail-review` for Codex, the Skill tool for Claude) and a final-message report
  with Findings. Default target: the uncommitted diff, else `<base>...HEAD` of the
  `<base>--<task>` branch; a clean checkout needs `--target` or the audit skill.
  Its wait result adds `mode: "review"` and `readOnly`; `false` carries a `violation`
  because the checkout changed. It never replaces the cross-vendor review.
- Pause: `orc pane pause <task> --path <worktree>` sends Esc to a working worker and
  records the ended turn (or records a manual Esc). Resume with `orc pane prompt`;
  never type into a worker pane with `rex send`, which bypasses run IDs and reports.
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

For a single task use `start --here --path <checkout>`; the orchestrator
does not edit beside its implementer. Scopers never claim checkout ownership.
Pair mode uses one Codex implementer at a time in that checkout. Review the diff
and rerun validation before closing. Parallel work uses dispatch task worktrees.
Start requires a checkout toplevel; `--allow-subdir` permits a subdirectory, including
with `--here`, which also supports another repository. Use `--precheck '<cmd>'` in
`sh` before creating a pane; failure returns `precheck-failed`, its exit code and
the last 40 output lines.
