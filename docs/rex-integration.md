# Rex actions and Neovim

Rex owns terminals, windows and sessions. Orc owns project selection, task views
and worker records. Personal keybindings and popup placement belong in the user's
Rex configuration. All owned integration code is Lua.

## Setup

Use `:Orc` for tasks and `:Orc projects` for the Snacks GHQ picker. Both keep
the existing editor running when their views close. Project search requires
GHQ and [snacks.nvim](https://github.com/folke/snacks.nvim);
the task panel and other workflow commands do not. Missing dependencies produce
a diagnostic rather than silently switching to another picker.

LazyVim already ships snacks.nvim. Otherwise add alongside the orc lazy.nvim spec:

```lua
{ "folke/snacks.nvim", opts = { picker = {} } }
```

## Popup entrypoints

Rex actions can launch a dedicated terminal using the normal Neovim configuration:

```lua
require("orc").open({ cwd = project_path, client_id = originating_client, quit_on_close = true })
require("orc").projects({ client_id = originating_client, quit_on_close = true })
```

`quit_on_close` defaults to false. Set it only for a dedicated popup, never an
existing editor with user buffers. Use an argv array with `nvim -n -i NONE -c`
and a correctly quoted Lua command. Quote strings with Lua `%q`, not shell
interpolation. The normal Neovim configuration must expose the orc module.

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
