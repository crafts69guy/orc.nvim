---
name: dispatch
description: "orc workflow: execute independent substantial plan tasks in isolated worktrees, then review and merge serially."
---

# Dispatch

Read `.scratch/<feature>/plan.md`. Select ready substantial tasks with disjoint
ownership. Never run two writers in one checkout. Use the harness's native
subagents normally; use [Rex workers](references/rex.md) in pane mode.

1. Create worktrees with `orc wt new <base> <task>...`; retain returned paths.
2. Write one brief per task, including plan section, decisions, ownership, docs
   acceptance criteria and validation command. Tell workers others are active.
3. Start implementers concurrently in their assigned worktrees. Do not allow commits.
4. Read each report and inspect each diff. Rerun checks. A partial/blocked report
   requires a follow-up, never a merge. At most two fix rounds per worker.
5. Merge accepted tasks one at a time:
   `orc wt merge <base> <task> --message "feat: concrete behavior"`.
   A conflict retains the task checkout; the orchestrator resolves it.
6. Run combined validation after each wave. Close owned worker panes after merge.

For an abandoned task, close its pane and use `orc wt remove <base> <task>`;
this discards its worktree and branch. Never apply it to unrelated work.
Do not leave task worktrees or workers after completing the feature.
Commit/push/PR shipping beyond local task merges still requires the user's request.
