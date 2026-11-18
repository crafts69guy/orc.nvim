# Delegated workflow

## Dispatch

- Use `plan` for separable tasks. Use `dispatch` to run 2–3 independent substantial
  tasks with disjoint files in their own worktrees. Review and merge serially.
- Pane mode is automatic inside Rex unless `--no-panes` or `ORC_PANES=0`.
  In pane mode, launch scopers and implementers through
  `orc pane start <feature> <task> --path <checkout> --brief <file> --role scoper|implementer`.
  Codex is the default worker. Outside pane and pair modes, use native subagents.
  The shipper is always native. Workers start MCP servers only when explicitly
  allowlisted with `--mcp <name,...>`.
- For one task in the selected session checkout, add `--here --path <checkout>`.
  Pair mode uses one Codex implementer there with `--here --kind codex` while
  the orchestrator reads and reviews. Keep one writer per checkout.
- Run `orc pane wait --until report` using the harness's background execution.
  Keep one wait per worker. It follows `pane prompt [--queue]` and `pane review`
  to the newest run and lists replaced runs' reports in `previousRuns`. On
  `state: "wait-failed"`, follow the returned hint. See dispatch's Rex reference.
- A delivery without acknowledgment is unconfirmed. Inspect before any retry.

## Reports and review

- Worker reports must identify their current Run and contain Status and Validation.
  Require done status, validation evidence and docs for changed exports and touched
  behavior. If a native subagent has handed back its report and shows "waiting on
  its own background work", stop it with TaskStop and keep the report.
- For an implementer pane, get the report, inspect the diff, run deterministic
  checks, complete the applicable review, then close the pane. The wait result's
  `next` field names the review or close command. Use `orc pane close <task> --path
  <checkout>` or `orc pane prune --path <checkout>` before reporting completion.
  See dispatch's Rex reference for the close gate, `--review` and `--no-review`.
- Single (default) uses exactly one model review per delegated diff. For non-risky
  diffs, use pane self-review (`orc pane review`). For risky diffs (security,
  concurrency, migrations, public APIs, fund safety), use one cross-vendor review
  and close with `--review <saved report>`.
- Cascade (high) escalates after a failed review round. Switch the worker to the
  other `--kind` or a stronger Claude model and record why.
- Critique (max) uses two independent reviews in parallel from different vendors
  for every substantial diff. Combine findings into one follow-up for the same
  implementer.
- For cross-vendor review of Codex implementation from a Claude orchestrator, use
  a native `orc:reviewer`. For Claude implementation or a second opinion, run
  `codex --no-daemon review --uncommitted` in the task checkout using the harness's
  background execution. Save stdout and stderr under `.scratch/<feature>/`.
  For a Codex-written diff under a Codex orchestrator, follow dispatch's Rex
  reference for the Claude review command. Give reviewers the fresh diff, brief
  and acceptance criteria. Rerun safe, reviewer-bounded `proven` commands and treat
  other claims as `unproven`. Drop non-repros.

## Follow-ups and handoff

- Merge findings into one follow-up for the same implementer. Allow at most two
  fix rounds, then sharpen the brief for a new worker. Record kind, level,
  model/effort and escalation reasons in the task log.
- Recheck fixes with the same worker's `orc pane review --target <paths changed in
  the round>`. Start a fresh native `orc:reviewer` only if the round touches a new
  risky area.
- On a usage or rate limit, restart the same brief and worktree with the other
  `--kind` and preserve prior work.
- Use one task per context and record state in the plan and
  `.scratch/<feature>/log.md`. Start with report Status and Validation and
  `git diff --stat`. After accepting and closing a worker, log progress and
  recommend `/clear`. If a large session has been idle for more than an hour,
  use `/clear` and reload from the log before resuming.
