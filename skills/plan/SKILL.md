---
name: plan
description: "orc workflow: record implementation decisions and task ownership before substantial separable work."
---

# Plan

Write `.scratch/<feature>/plan.md` in the main checkout's scratch directory.
Resolve interfaces and significant tradeoffs before handing work to implementers.

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
  validate: nvim --clean -l test/run.lua
```
````

The parser accepts flat task fields and inline dependency lists. Keep that format.
Ownership must be disjoint for tasks with no dependency path. A substantial task
is its own module or feature needing multiple edit/test cycles. Batch small tasks.
Show the task ordering; dispatch substantial independent tasks in worktree waves.
