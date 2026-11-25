# Rex workers

Use Rex only through `orc pane`; never infer success from a screen capture.
Pane mode is automatic inside Rex; `--no-panes` or `ORC_PANES=0` disables it.
Delegate scopers and implementers through Codex pane workers instead of native
subagents; choose review by the active level in the orchestrator rules; shipper stays native.

For independent review, prefer the other vendor. If quota or unsupported
transport prevents that, start a fresh same-vendor reviewer and record the reason
in the task log. Critique uses two independent reviews where available. Use TUI
for interactive work. Opt in to exec for bounded one-turn work. If independent
review is unavailable, record the blocker and leave the review pending.

For a Codex-written diff under a Codex orchestrator, this is a bounded Claude
review. Run it from the task checkout with absolute `worktree`, `brief` and
`report` paths. Pin the checkout before launching the reviewer.

```fish
orc pane review-begin "$task" --path "$worktree" --review "$report"
and claude -p --permission-mode plan --tools Read,Grep,Glob,Bash,Skill \
    --append-system-prompt 'Review only. Read the code and diff without writing files or running tests.' \
    "Use ponytail:ponytail-review when available. Review the uncommitted diff against the brief at $brief and report findings and a verdict." \
    > "$report" 2> "$report.stderr"
```

Read the saved verdict and close only after accepting it:

```fish
orc pane close "$task" --path "$worktree" --review "$report"
```

For parallel reviewers, pin the acceptance report before dispatch. Save both
outputs and verdicts in that report and accept both before closing.

- Start: `orc pane start <feature> <task> --path <worktree> --brief <file> --role implementer [--transport tui|exec]`.
  Codex and implementer are defaults; use `--role scoper` for read-only scoping
  or `--kind claude` to choose Claude. Transport defaults to `tui`; `exec` is
  Codex-only, records JSONL/usage, and supports start/wait/close without steering.
  Workers start no MCP servers; add `--mcp <name,...>` only when the brief needs
  one (for example `--mcp figma` for a design task).
- Wait: `orc pane wait <task> --path <worktree> --until report --timeout 1800000`, using the
  harness's background execution (foreground Bash is capped at 10 minutes).
  Waits for the current run's report with Status and Validation, a native user-action
  block, process exit/error or timeout; a working TUI transcript unchanged for 30+ minutes returns `stalled` with a recovery hint. Missing evidence never ends this wait.
  A done report adds `next`: `orc pane review` for a TUI implementer's work run, then
  `orc pane close` after its review run (directly for scopers and exec workers).
  When the active level requires independent review, use `pane review-begin`
  followed by a saved report and `close --review <file>`.
  After five idle minutes without that report it returns `turn-ended-no-report` with a hint.
  Plain wait can return `turn-ended-no-report` as soon as a turn ends without evidence.
  Both wait modes return `unacknowledged` after 60 seconds without acknowledgment.
  For a queued prompt, the window starts when Rex reports `idle` or `done`.
  Answer any pane dialog, check hook trust and "Hook failed" messages, then rerun `orc pane wait`.
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
  sends the owning idle worker a read-only self-review turn: the reviewer role, the skill per kind
  (`$ponytail-review` for Codex, the Skill tool for Claude) and a final-message report
  with Findings. Default target: the uncommitted diff, else `<base>...HEAD` of the
  `<base>--<task>` branch; a clean checkout needs `--target` or the audit skill.
  Use `--skill ponytail-audit` only when a whole-repo audit is asked.
  Its wait result adds `mode: "review"` and `readOnly`; `false` carries a `violation`
  because the checkout changed: inspect the diff before accepting anything.
  Single (default) gets exactly one model review per diff: non-risky diffs get only
  self-review; risky diffs (security, concurrency, migrations, public APIs, fund safety)
  get one independent review. For that initial diff, pin the checkout before
  dispatching a reviewer and use the saved report to close after acceptance.
  Otherwise, initial self-review stays required after the report and deterministic checks.
  After a fix round, self-review only the paths changed in that round, taken from
  the follow-up report and `git status`:
  `orc pane review <task> --path <worktree> --target <paths changed in the round>`.
  Use the same worker; never start a fresh native `orc:reviewer` unless the round
  touches a new risky area. Keep high (Cascade) and max (Critique) review patterns.
  The close gate still compares the whole checkout.
- Pause: `orc pane pause <task> --path <worktree>` sends Esc to a working worker and
  records the ended turn (or records a manual Esc). Resume with `orc pane prompt`;
  never type into a worker pane with `rex send`, which bypasses run IDs and reports.
- Pin independent review: `orc pane review-begin <task> --path <worktree> --review <new-file>`.
  Use a new path under `.scratch/<feature>/`, preferably outside the task
  checkout. Start the reviewer after pinning succeeds. If the run or checkout
  changes, pin again with a new path and review the updated tree.
- Close: `orc pane close <task> --path <worktree> [--review <file>]`. A live TUI
  implementer closes only after a done self-review of the checkout as it is now or
  an accepted saved independent review passed with `--review <file>`. Close checks
  the pinned path, run and checkout fingerprint. The orchestrator checks the verdict.
  Without either, close returns `status: "not-reviewed"` naming the review command;
  a missing or empty report file also returns `status: "not-reviewed"`.
  `--review` and `--no-review` are mutually exclusive. `--no-review` closes anyway:
  use it for cleanup of an abandoned, stalled or failed task;
  record why in the task log. If Rex restarted
  or pane creation failed, close and start refuse the stranded record; after checking
  the pane is gone, add `--force` to mark it closed without touching Rex.
- Prune: `orc pane prune --path <checkout>` closes successful exits and idle/done
  workers with a matching done report and validation evidence across that repository.
  It uses non-force close checks, including the self-review check, and per-task locks;
  JSON lists closed and skipped workers with each skip's reason.

Keep returned session/block/run IDs. `not-sent`, blocked or unconfirmed delivery
is not success: surface the pane to the user and inspect current state before
retrying. Never answer permission, auth or trust dialogs for the user.
Only the report belonging to the current run can be accepted; review its actual
Status and Validation. `idle`, `done` program status and exit zero are insufficient.
Close only panes created for your task. Closing Neovim leaves workers running.

For a single task use `start --here --path <checkout>`; the orchestrator
does not edit beside its implementer. Scopers never claim checkout ownership.
Pair mode uses one Codex implementer at a time in that checkout. Review the diff
and rerun validation before closing. The same gates apply when only one task can
run. Parallel work uses dispatch task worktrees. After integration, use `orc gate`
for checks against the actual tree to be committed.
Start requires a checkout toplevel; `--allow-subdir` permits a subdirectory, including
with `--here`, which also supports another repository. Use `--precheck '<cmd>'` in
`sh` before creating a pane; failure returns `precheck-failed`, its exit code and
the last 40 output lines.
