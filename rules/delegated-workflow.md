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
- For a task that edits or reads `.ts` or `.tsx` files, give the absolute path of
  [typescript-best-practices](../skills/typescript-best-practices/SKILL.md) in its
  brief and in any review prompt you write, since the skill never loads on its own.
  `orc pane review` adds the path itself. This applies in pair mode too.
- Give the absolute path of [test-discipline](../skills/test-discipline/SKILL.md)
  and the edge cases the task's tests must cover in every implementer brief, and
  the path in any review prompt you write. `orc pane review` adds the path itself.

## Reports and review

- Worker reports must identify their current Run and contain Status and Validation.
  Require done status, validation evidence and docs for changed exports and touched
  behavior. A bug fix or new check that a test can reproduce also needs the test
  failing before the change and passing after, or a stated reason why not.
- For `needs-context`, answer the questions and continue with the same worker.
  In pane mode use `orc pane prompt <task> --path <checkout> --file <answer>`.
  Reserve fix rounds for changes requested on the worker's implementation.
- Mark each delegated task risky or non-risky in its brief and task log. Risky
  means it touches security, concurrency, migrations, public APIs or fund safety.
  Re-mark it risky when its diff or a fix round reaches one of those areas.
  The steps below name the mark that needs them.
- For a non-risky task, rerun the report's targeted tests and inspect the diff;
  the worker's red run and mutation probes stand.
- For a risky task, before review, while the worker is idle, verify in the task
  checkout, which already has its dependencies (a fresh worktree may lack
  `node_modules`). Save `git diff HEAD | shasum`, `git status --porcelain` and
  copies of the changed non-test files outside the checkout. For one red claim,
  put the base version of those files in place (`git checkout HEAD -- <files>`,
  moving new ones aside), run the new tests and confirm the failure has the named
  reason. Then restore the copies, apply one mutant of your own to a changed
  decision the report did not mutate and confirm a targeted test fails. Restore
  again and confirm the checksum and status match. A surviving mutant goes into
  the follow-up. Give the reported mutation probe survivors to the review as
  questions, not as tests to write.
- If a native subagent has handed back its report and shows "waiting on
  its own background work", stop it with TaskStop and keep the report.
- For an implementer pane, get the report, inspect the diff, run deterministic
  checks, follow [no-comments](../skills/no-comments/SKILL.md) once the worker is
  idle, complete the applicable review, then close the pane. The wait result's
  `next` field names the review or close command. Use `orc pane close <task> --path
  <checkout>` or `orc pane prune --path <checkout>` before reporting completion.
  See dispatch's Rex reference for the close gate, `--review` and `--no-review`.
- Single (default) gives the initial diff one model review: pane self-review
  (`orc pane review`) when non-risky, one independent review when risky. Fix
  rounds follow Follow-ups below.
- Cascade (high) escalates after a failed review round. Switch the worker to the
  other `--kind` or a stronger Claude model and record why.
- Critique (max) uses two independent reviews in parallel where available for
  every substantial diff. Prefer different vendors and combine findings into one
  follow-up for the same implementer.
- Prefer the other vendor for independent review. If quota or unsupported review
  transport prevents it, start a fresh same-vendor reviewer and record the reason
  in the task log. Give that reviewer the brief and current diff in a new session.
  If no independent reviewer can run, record the blocker and leave the independent
  review pending. Deterministic checks and the applicable review still apply,
  including for work with no parallel tasks.
- Before launching a saved independent review of a pane task, write the reviewer
  prompt to a file. Name the package at `<review-file>.diff` in the prompt and ask
  the reviewer to read it once. Pin the checkout and create the package with
  `orc pane review-begin <task> --path <checkout> --review <review-file> --prompt <prompt-file>`.
  Save the reviewer's output at `<review-file>` and read the verdict before passing
  that same path to `orc pane close --review`. See dispatch's Rex reference for details.
- For cross-vendor review of Codex implementation from a Claude orchestrator, use
  a native `orc:reviewer`. For Claude implementation or a second opinion, write the
  brief, acceptance criteria and instructions to read `<review-file>.diff` once
  and end with a verdict to the prompt file. Pass the file to `review-begin --prompt`,
  then run `codex --no-daemon -a never exec --ephemeral --sandbox read-only
  --ignore-rules -o <report> - < <prompt-file>` in the task checkout using the
  harness's background execution. `codex review --uncommitted` rejects a custom
  prompt, so it cannot carry the brief. Save stdout and stderr under
  `.scratch/<feature>/`.
  For a Codex-written diff under a Codex orchestrator, follow dispatch's Rex
  reference for the Claude review command. Give reviewers the fresh package, brief
  and acceptance criteria. Rerun safe, reviewer-bounded `proven` commands and treat
  other claims as `unproven`. Drop non-repros and log each as a ruling. An
  `inconclusive` verdict is not a pass: run the missing check or record the
  review as pending.

## Follow-ups and handoff

- After integration, run the applicable validation through the existing
  `orc gate` on the exact tree that will be committed. Reuse a gate run when the
  tree and required checks match. Run the affected checks again if integration or
  fixes change that tree.
- Log each dropped finding and each decision you make without the user in
  `.scratch/<feature>/log.md` as `Ruling: <what> — <why> — <cost if wrong>`.
  List every ruling in the handoff to the user.
- Merge findings into one follow-up for the same implementer. Allow at most two
  fix rounds, then sharpen the brief for a new worker. When a fix round leaves
  its finding open, write the assumption the failed fixes share in the task log
  and check it before the next attempt. Give a new worker the original brief,
  the follow-ups and the last report. Record kind, level, model/effort and
  escalation reasons in the task log.
- After a fix round, run no-comments on the paths it changed. For a risky task,
  recheck with the same worker's `orc pane review --target <paths changed in the
  round>`. For a non-risky task, skip the model recheck: inspect the round's diff,
  rerun its targeted tests, then close with `--no-review` and record those
  commands in the task log. Start a fresh native `orc:reviewer` only if the round
  touches a new risky area.
- The close gate accepts a delta since the last review that only deletes whole
  comments in TypeScript or Lua files, so a late no-comments deletion there
  needs no new review. Any other change
  needs the review or the non-risky close above.
- On a usage or rate limit, restart the same brief and worktree with the other
  `--kind` and preserve prior work.
- Use one task per context and record state in the plan and
  `.scratch/<feature>/log.md`. Start with report Status and Validation and
  `git diff --stat`. After accepting and closing a worker, log progress and
  recommend `/clear`. If a large session has been idle for more than an hour,
  use `/clear` and reload from the log before resuming.
