---
name: plan
description: "orc workflow: record implementation decisions and task ownership before substantial separable work."
---

# Plan

Write `.scratch/<feature>/plan.md` in the main checkout's scratch directory.
Resolve interfaces and significant tradeoffs before handing work to implementers.
Read the main checkout's `.orc/backlog.md` and offer items touching planned files as tasks.

## Prerequisites

Verify claims such as "released", "merged" and "exported" before briefing, using
commands such as `npm view <package> version`, `git merge-base --is-ancestor <ref> HEAD`
and `rg <symbol> <source>`. Pass key checks as `orc pane start --precheck '<cmd>'`.
A precheck tests the worker's starting state: do not check for a version or export
that the worker must first add or bump.

## Plan format

Use this shape:

````markdown
# Feature

Base branch: feat/example

## Decisions

- Fixed interfaces, constraints and compatibility decisions.

## Tasks

```yaml
- id: T1
  goal: Observable behavior
  files: [lua/example.lua, test/example_spec.lua]
  depends_on: []
  size: substantial
  validate: "nvim --clean -l test/run.lua  # expect: exit 0, 0 failures"
```
````

The parser accepts flat task fields and inline dependency lists. Keep that format.
Each task's `validate` names done-evidence: the command and expected observable
output that prove its goal. If you cannot name that evidence, scope the task first.
Ownership must be disjoint for tasks with no dependency path. A substantial task
is its own module or feature needing multiple edit/test cycles. Batch small tasks.
Show the task ordering; dispatch substantial independent tasks in worktree waves.
