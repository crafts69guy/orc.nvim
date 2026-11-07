# Rex workers

Use Rex only through `orc pane`; never infer success from a screen capture.

- Start: `orc pane start <feature> <task> --path <worktree> --brief <file>`.
  Add `--kind codex` to choose Codex; Claude is otherwise used.
- Wait: `orc pane wait <task> --path <worktree> --timeout 1800000`.
- Follow-up: `orc pane prompt <task> --path <worktree> --file <brief>` or `--text`.
- Close: `orc pane close <task> --path <worktree>`. If Rex restarted or pane
  creation failed, close and start refuse the stranded record; after checking the
  pane is gone, add `--force` to mark it closed without touching Rex.

Keep returned session/block/run IDs. `not-sent`, blocked or unconfirmed delivery
is not success: surface the pane to the user and inspect current state before
retrying. Never answer permission, auth or trust dialogs for the user.
Only the report belonging to the current run can be accepted; review its actual
Status and Validation. `idle`, `done` program status and exit zero are insufficient.
Close only panes created for your task. Closing Neovim leaves workers running.

In pair mode use `start --here --kind codex --path <session checkout>` for one worker
at a time. Do not create task worktrees or edit alongside it. Review the resulting
checkout diff and rerun validation before closing. Parallel work uses dispatch.
