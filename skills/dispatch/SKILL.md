---
name: dispatch
description: "orc workflow: execute independent substantial plan tasks in isolated worktrees, then review and merge serially."
---

# Dispatch

Read `.scratch/<feature>/plan.md`. Select ready substantial tasks with disjoint
ownership. Never run two writers in one checkout. Use the harness's native
subagents normally; use [Rex workers](references/rex.md) in pane mode.

1. Create worktrees with `orc wt new <base> <task>...`; retain returned paths.
   Re-running it is safe: live task worktrees are reused (`action: reused`).
2. Write one brief per task, including plan section, decisions, ownership, docs
   acceptance criteria and validation command. Tell workers others are active.
3. Start implementers concurrently in their assigned worktrees. Do not allow commits.
4. Read each report and inspect each diff. Rerun checks. A partial/blocked report
   requires a follow-up, never a merge. At most two fix rounds per worker.
   Pane workers then self-review: `orc pane review <task> --path <worktree>`, waited
   like any run. Review again after each fix round; close refuses an unreviewed diff.
5. Apply the active level and cross-vendor rules: default (Single) reviews risky
   diffs only; high (Cascade) escalates kind or Claude model after a failed review
   round and records why; max (Critique) runs two independent vendor reviews in
   parallel for every substantial diff and merges findings into one follow-up
   for the same implementer. Deterministic checks precede model review.
6. Close the accepted task's owned worker pane, then merge tasks one at a time:
   `orc wt merge <base> <task> --message "feat: concrete behavior"`.
   A successful merge removes the task checkout, so `orc pane close` no longer
   resolves it. A conflict retains the checkout; the orchestrator resolves it.
   A `merged` result with a `warning` already landed: clean up the named leftover,
   never merge it again.
   When the user wants to review before any commit on base, use
   `orc wt apply <base> <task>` instead: it stages the task, including new files,
   in the current checkout without committing. After a fix round, apply again:
   only the delta lands while those files still hold the last apply; files edited
   since then are reported as a conflict. Remove the task with
   `orc wt remove <base> <task>` after the user accepts it.
7. Run combined validation after each wave.

For an abandoned task, close its pane with `--no-review` and use `orc wt remove <base> <task>`;
this discards its worktree and branch. Never apply it to unrelated work.
Do not leave task worktrees or workers after completing the feature.
Commit/push/PR shipping beyond local task merges still requires the user's request.
