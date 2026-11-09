# Rex actions and Neovim

Rex owns terminals, windows and sessions. Orc owns project selection, task views
and worker records. Personal keybindings and popup placement belong in the user's
Rex configuration. All owned integration code is Lua.

Start a headless Codex block with `orc pane start <feature> <task> --path <dir>
--brief <file> --transport exec`. The Lua runner writes OSC 7501 root status with
`app=orc`, so Rex activity indicators and worker snapshots recognize it. Raw JSONL
events live in `<dir>/.orc/runs/<runId>.jsonl`; thread ID, usage and exit status
are saved on the worker record. The default `--transport tui` supports steering
and follow-up prompts; exec currently supports start/wait/close only. See the
[transport comparison](../README.md) for limitations and rate-limit recovery.

`pane start` requires the checkout's git toplevel unless `--allow-subdir` is given;
`--here` can target another repository's checkout. Optional
`--precheck '<cmd>'` runs in `--path` using `sh -c` before creation; failure returns
`precheck-failed`, the exit code and the last 40 lines, with no pane or worker record.

For TUI follow-ups, `pane prompt --queue` queues on acknowledged working programs
using Codex Tab or Claude Enter, with the same ownership and hook checks. `queued`
awaits UserPromptSubmit; without the flag, a busy worker returns `not-sent`.
Use `pane wait --until report` to continue until a matching report with Status and
Validation, native user-action block, exit/error or timeout. Plain wait distinguishes
`turn-ended-no-report` from `blocked`; missing evidence does not end a report wait.

## Setup

Use `:Orc` for tasks, `:Orc projects` for the Snacks GHQ picker, and `:Orc workers`
to search non-closed workers and focus their recorded Rex panes. All keep the
existing editor running when their views close. Both pickers require
[snacks.nvim](https://github.com/folke/snacks.nvim); project search also requires GHQ.
The task panel and other workflow commands do not. Missing dependencies produce
a diagnostic rather than silently switching to another picker.

LazyVim already ships snacks.nvim. Otherwise add alongside the orc lazy.nvim spec:

```lua
{ "folke/snacks.nvim", opts = { picker = {} } }
```

## Popup entrypoints

Rex actions can launch a dedicated terminal running Neovim with orc on its
runtimepath:

```lua
require("orc").open({ cwd = project_path, client_id = originating_client, quit_on_close = true })
require("orc").projects({ client_id = originating_client, quit_on_close = true })
require("orc").workers({ cwd = project_path, client_id = originating_client, quit_on_close = true })
```

`quit_on_close` defaults to false. Set it only for a dedicated popup, never an
existing editor with user buffers. With it, the projects and workers pickers fill
the whole popup editor, so size the Rex layer to the picker you want to see.

Use an argv array with `nvim -n -i NONE -c` and a correctly quoted Lua command.
Quote strings with Lua `%q`, not shell interpolation. The Neovim it starts must
expose the orc module and, for the pickers, snacks.nvim. Either use the normal
configuration, or keep the popup free of editor UI such as dashboards and
statuslines with `nvim --clean -u <init>`, where a minimal init adds orc and
snacks.nvim to the runtimepath and calls `require("snacks").setup({ picker = {},
notifier = {} })`. The notifier keeps errors out of the command line.

The workers picker runs `orc status --json` asynchronously in `cwd` (the editor's
current directory by default). Rows show `feature/task`, role (older records
default to `implementer`), kind and state. Enter focuses the selected worker and
closes the picker after success; workers without a confirmed block and focus
failures show a diagnostic. Empty lists and startup failures show a message;
dedicated popups keep that message in a buffer closable with Esc or q.

Capture `ctx.client_id`, `ctx.session_id` and `ctx.block_id` in the Rex action.
Do not choose an arbitrary app or assume its active pane is the action's target.
The popup receives its own Rex block identity; never replace that identity with
the source pane's ID. Task popups need the source pane's absolute local directory.
Validate OSC 7 hosts and percent escapes; do not silently use HOME on failure.

## Session identity and recovery

The picker lists `ghq list -p`. Selection creates a fresh session with a shell in
that repository; it does not run an agent, reuse a label, or change worktrees.
When supplied, the originating client ID selects the exact Rex app. App switching
requires the user's Remote Control setting; orc never enables it or redirects a
denied request to another client.

Creation and selection are separate. After confirmed creation, selection retries
use the same session ID. A timed-out or malformed create reply can still mean a
session exists: inspect `rex ls` before trying again in another picker. Double
confirmation does not replay an in-flight create. Cancellation cannot undo an
operation already accepted by the server.

The adapter validates local Unix endpoints and host/server instance identity.
Task focus uses recorded session/block IDs and selects that session on the
originating app when available. Mismatched/restarted servers fail rather than
using stale IDs. Labels are display text, not ownership. Same-user terminal
access is not an OS sandbox.

## Lifecycle and rollout

Closing a view stops its own watchers and CLI children, leaving workers, created
sessions and shared Inkdrop running. Late callbacks cannot update a closed view.
An unconfirmed create is reported rather than automatically replayed or deleted.

Rex's Lua host registers actions; Neovim's Lua host provides `vim.*` and Snacks.
Do not import Neovim modules into the Rex configuration interpreter. Existing
synchronous adapter methods remain compatible; interactive views use async calls.

Orc never writes, installs, stows or reloads the user's Rex config. Validate a
draft with `rex config check <path>`. `rex do <path> --action <name>` exercises a
draft without replacing the running config, but really executes the action:
choose a test session/client and clean up only the IDs it creates. Activate a
validated config with `rex config reload`; retain a backup for rollback.

See the official [config execution model](https://www.superlogical.com/rex/docs/customize/config)
and [action context and errors](https://www.superlogical.com/rex/docs/customize/actions).
