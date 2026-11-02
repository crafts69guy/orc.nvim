# orc.nvim

An orchestration workflow written in Lua for Neovim, Rex, Claude Code and Codex.
One agent scopes, delegates, reviews and ships; independent implementers work in
separate Git worktrees. Neovim provides the task panel. Rex runs the terminals.

The CLI, hooks, generator, tests and evaluation fixtures run with Neovim's Lua
runtime. They do not load your Neovim configuration. There is no Node backend.

## Requirements

- Neovim 0.11 or newer, Git and [worktrunk](https://worktrunk.dev).
- Claude Code or Codex.
- [Rex](https://www.superlogical.com/rex/docs) for pane and pair workers.
- curl for the optional Inkdrop local-server integration.
- Developers: StyLua 2.6 and Neovim's Lua Tree-sitter parser.

## Local installation

Clone this repository and add its absolute `bin` directory to PATH. In fish:

```fish
fish_add_path ~/Developments/github.com/crafts69guy/orc.nvim/bin
orc doctor
```

For lazy.nvim, use the checkout directly until the repository is published:

```lua
{
  dir = vim.fn.expand("~/Developments/github.com/crafts69guy/orc.nvim"),
  name = "orc.nvim",
  cmd = "Orc",
  opts = {},
}
```

The CLI loads the local Claude plugin explicitly. Install/trust the Codex plugin
hooks through your normal plugin workflow before using hook-driven automation.
Never enable the old Orchestra plugin and this plugin for the same session.

## Commands

| Command | Purpose |
| --- | --- |
| `orc claude`, `orc codex` | Start an orchestrator with shared rules and approved lessons |
| `orc claude --pair` | One Codex worker beside the orchestrator in Rex |
| `orc claude --panes` | Dispatch workers in Rex panes, one task worktree each |
| `orc wt new\|merge\|remove\|list\|session` | Manage isolated worktrees and serial merges |
| `orc pane start\|wait\|prompt\|close` | Manage a worker and its report |
| `orc status --json` | Feature/task/worker snapshot, also usable outside Rex |
| `orc doctor --json` | Prerequisite and integration checks |
| `orc context --scope all --json` | Audit static Claude/Codex context sources |
| `orc inkdrop init\|inbox\|claim\|push\|pull\|lessons` | Mirror managed feature blocks and approved lessons |
| `orc completion fish` | Print fish completion definitions |
| `orc eval` | Explicitly run model-based behavior evaluations |
| `orc update` | Fast-forward the clean Git checkout and update installed plugins |

Use `orc --help` for arguments. Permission bypass is explicit (`--yolo`), never
the default. Workers must not commit or push. Review changes and rerun validation
before accepting a task; a terminal's `done` indicator is not validation.

## Neovim

`:Orc` opens the task panel. It shows features, tasks and workers, including pair
workers without a plan. Open the selected task's brief, report or diff, focus its
Rex pane, or send a follow-up. Closing the panel stops its watchers; worker
processes continue in Rex. Reopening reconstructs state from disk and Rex.

## State and integrations

Plans and capture logs live in the main checkout's `.scratch/<feature>/`. Approved
lessons and worker records live in `.orc/`, excluded from Git. Each assignment has
a `runId`; reports must identify it. An unconfirmed delivery is not automatically
resent. A failed follow-up must not erase the previous report.

Inkdrop uses `INKDROP_LOCAL_USERNAME`, `INKDROP_LOCAL_PASSWORD` and optionally
`INKDROP_LOCAL_SERVER_URL` (default `http://localhost:19840`). Keep credentials in
an untracked local file. Only loopback HTTP servers are accepted; redirects are
refused. Only the managed `<!-- orc:begin -->` block is replaced, preserving user
text and refusing damaged markers.

`status`, `doctor` and `context` expose `schemaVersion: 1` JSON. New fields are
additive; consumers ignore unknown fields and retain the distinction between
`null`, empty arrays and empty objects.

## Development

```fish
nvim --clean -l test/run.lua
nvim --clean -l test/run.lua --coverage
nvim --clean -l scripts/gen-agents.lua --check
stylua --check lua test scripts bin/orc plugin
```

Unit/integration tests use fake process/network adapters and temporary
repositories. The ordinary suite does not call a model or require a Rex server.
Coverage has separate 98% gates for executable source lines, branches and
functions. See [coverage definitions](docs/coverage.md).

Paid evaluations are separate: `orc eval` uses the existing explicit model cost
cap (`ORC_EVAL_MAX_COST`, default 5 USD). All fixtures are Lua and form a new
benchmark series; old JavaScript timings are historical, not a comparable baseline.

See [architecture](docs/architecture.md) and [cutover](docs/cutover.md).
