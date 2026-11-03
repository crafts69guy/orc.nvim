# orc.nvim

Fresh Lua 5.1 implementation for Neovim >= 0.11 and Rex. All owned runtime code
is Lua; there is no Node/JavaScript or legacy orc runtime bridge. The optional
shared Inkdrop service uses pinned external proxy/backend dependencies.
No Herdr or semantic-index integration.

Use apply_patch for edits. Run shell commands with shell="fish" on macOS.
Do not overwrite user changes. Documentation and exported Lua interfaces need
LuaLS annotations. Markdown is canonical for roles, rules and skills.

This rewrite explicitly uses implementer subagents in isolated git worktrees.
Follow .scratch/lua-rewrite/plan.md and your assigned ownership. Do not edit
another task's files. Do not publish, push, or create a remote repository.

Validation: `nvim --clean -l test/run.lua`, `stylua --check lua test scripts bin/orc plugin evals`.
Coverage must report lines, branches and functions separately, each >=98%.
Never replace missing coverage with estimates or exclude production modules.
Tests must validate behavior, including errors and recovery, using fake adapters
and temporary repositories. Paid model evals are separate from ordinary checks.
