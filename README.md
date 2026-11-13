# orc.nvim

Visible, isolated multi-agent coding for Neovim, [Rex](https://www.superlogical.com/rex/docs),
Claude Code and Codex.

One orchestrator agent scopes, delegates, reviews and ships. Implementers work in
separate Git worktrees inside Rex terminals you can watch and steer. Neovim shows
the live task panel. Nothing is accepted until the orchestrator reads the diff and
reruns validation.

Everything — CLI, hooks, generator, tests and evals — is Lua running on Neovim's
runtime (`nvim -l`). It does not load your Neovim configuration and has no Node
backend.

## Architecture

```mermaid
flowchart LR
  dev([Developer])
  subgraph harness[Claude Code / Codex]
    orch[Orchestrator<br/>rules · skills · hooks]
  end
  subgraph orc[orc.nvim · Lua]
    cli[orc CLI]
    core[Workflow core<br/>runs · records · reports]
    panel[":Orc task panel"]
  end
  subgraph rex[Rex]
    w1[Worker pane]
    w2[Worker pane]
  end
  wt[(Git worktrees<br/>via worktrunk)]
  state[(.scratch/ plans<br/>.orc/ records)]
  ink[(Inkdrop notes<br/>optional)]

  dev --> orch
  dev --> panel
  orch --> cli --> core
  panel --> core
  core --> wt
  core -->|spawn · prompt · focus| rex
  w1 & w2 -->|edit| wt
  w1 & w2 -->|run-specific report| core
  core --> state
  core -.-> ink
```

- **Harness** makes decisions from canonical Markdown roles, rules and skills.
- **orc** owns identities (`runId`), worktrees, subprocesses and report validation.
- **Rex** owns terminal processes, layout and events. Workers outlive the UI.
- **Neovim** renders state and calls the same workflow asynchronously.

Details: [architecture](docs/architecture.md) · [Rex integration](docs/rex-integration.md).

## Requirements

- Neovim 0.11+, Git and [worktrunk](https://worktrunk.dev).
- Claude Code or Codex.
- [Rex](https://www.superlogical.com/rex/docs) for pane and pair workers.
- Optional: [ghq](https://github.com/x-motemen/ghq) and
  [snacks.nvim](https://github.com/folke/snacks.nvim) for `:Orc projects`;
  curl for the Inkdrop local-server integration.
- Development: StyLua 2.6 and Neovim's Lua Tree-sitter parser.

## Installation

Clone once and put `bin` on PATH (fish shown):

```fish
git clone https://github.com/crafts69guy/orc.nvim ~/.local/share/orc.nvim
fish_add_path ~/.local/share/orc.nvim/bin
orc doctor
```

Neovim (lazy.nvim):

```lua
{ "crafts69guy/orc.nvim", cmd = "Orc", opts = {} }
```

Register the checkout as a plugin marketplace for each harness you use:

```fish
claude plugin marketplace add ~/.local/share/orc.nvim
claude plugin install orc@orc-nvim
codex plugin marketplace add ~/.local/share/orc.nvim
codex plugin add orc@orc-nvim
```

The CLI also loads the local Claude plugin explicitly. Restart agent sessions and
approve new or changed hooks through the harness's normal trust controls before
relying on hook-driven automation. `orc update` fast-forwards the clean checkout
and updates the installed plugins.
After `orc update` changes hooks, re-trust them in Codex's `/hooks` before
workers can be acknowledged.

## Commands

| Command | Purpose |
| --- | --- |
| `orc claude`, `orc codex` | Start an orchestrator with shared rules and approved lessons |
| `orc claude --pair` | One Codex worker beside the orchestrator in Rex |
| `orc claude --panes`, `orc codex --panes` | Force pane delegation (automatic inside Rex) |
| `orc claude --no-panes`, `orc codex --no-panes` | Disable automatic pane mode |
| `orc wt new\|merge\|apply\|remove\|list\|session` | Manage isolated worktrees and serial merges; `apply` stages a task in the current checkout without committing on base; re-running it after a fix round stages only the delta; `new` reuses live task worktrees; a merge whose cleanup fails still reports `merged` with a `warning` |
| `orc pane start\|wait\|prompt\|close [--force] [--no-review]` | Manage a worker and its report; `close` refuses a live TUI implementer without a done self-review of the current checkout (`status: "not-reviewed"`) unless `--no-review`; `close --force` marks an unreachable record closed without calling Rex |
| `orc pane prune --path <dir>` | Close successful exits or idle/done workers with a matching done report and evidence, skipping unreviewed live TUI implementers; print closed/skipped JSON with reasons |
| `orc pane start ... [--allow-subdir] [--precheck '<cmd>']` | Require a checkout toplevel by default; check prerequisites before pane creation |
| `orc pane start ... [--mcp <name,...>]` | Workers start no MCP servers, configured or Codex-plugin, unless allowlisted; a Codex worker refuses to launch if Codex rejects the overrides or would still start one; the orchestrator keeps its own |
| `orc pane prompt ... --queue` | Queue follow-ups on acknowledged working TUI workers; await hook acknowledgment |
| `orc pane review <task> --path <dir> [--skill ponytail-review\|ponytail-audit] [--target <range\|paths>]` | Send an idle TUI worker a read-only ponytail review of its uncommitted diff (else `<base>...HEAD`); `pane wait` adds `readOnly` and a `violation` when the checkout changed; required before closing a TUI implementer, again after each fix round |
| `orc pane wait ... --until report` | Wait for a matching report, user-action block, exit/error, five idle minutes without a report, or timeout; a done report adds `next`: `pane review` after a TUI implementer's work run, else the close command; follows follow-up runs and lists replaced ones in `previousRuns`; failures return `state: "wait-failed"` with a `hint` |
| `orc pane pause <task> --path <dir>` | Interrupt a working TUI worker with Esc (or record a manual Esc); resume with `orc pane prompt` |
| `orc gate [--label <name>] [--log <file>] -- <cmd...>` | Serialize heavy commands across the machine; stream output and optionally save a log |
| `orc status --json` | Feature/task/worker snapshot, also usable outside Rex |
| `orc doctor --json` | Prerequisite and integration checks |
| `orc context --scope all --json` | Audit static Claude/Codex context sources |
| `orc inkdrop init\|inbox\|claim\|push\|pull\|lessons` | Mirror managed feature blocks and approved lessons |
| `orc inkdrop-mcp` | Explicit shared Inkdrop service setup, migration and lifecycle |
| `orc completion fish` | Print fish completion definitions |
| `orc eval` | Explicitly run model-based behavior evaluations |
| `orc update` | Fast-forward the clean Git checkout and update installed plugins |

Run `orc --help` for arguments.

Choose `--level default|high|max` (or `ORC_LEVEL`; the flag wins):

| Level | Routing after deterministic checks |
| --- | --- |
| `default` (Single) | One implementer per task; reviewer only for security, concurrency, migrations or public API risks |
| `high` (Cascade) | Escalate kind or Claude model after a failed review round; record why |
| `max` (Critique) | Two independent vendor reviews in parallel for every substantial diff; one combined follow-up to the same implementer |

Claude `high` and `max` share elevated role models; Codex model selection stays
native. Worker records and picker rows show the level captured at start; older
records show `default`. Primary review uses the other vendor. On a usage/rate
limit, restart the same brief and worktree with the other `--kind`.

Inside Rex (`REX_SESSION` and `REX_BLOCK` set), pane mode turns on automatically
unless pair mode, `--no-panes`, or `ORC_PANES=0` applies. `--panes` or `ORC_PANES=1`
forces it; `--panes` conflicts with `--no-panes`. Start workers with
`orc pane start <feature> <task> --path <checkout> --brief <file>`: Codex and
`--role implementer` are defaults. Use `--role scoper` for read-only scoping or
`--kind claude` for Claude. Scopers return reports in their final message; the
Stop hook saves a matching Run report when its file is absent.

Choose a worker transport with `--transport tui|exec`:

| Transport | Providers | Trade-off |
| --- | --- | --- |
| `tui` (default, including older records) | Codex, Claude | Interactive steering, approvals and `pane prompt` follow-ups; hook-based reports |
| `exec` (opt-in) | Codex | Headless JSONL events and token usage; no interactive steering or `pane prompt` follow-ups |

For example, add `--transport exec` to `orc pane start`. Exec workers save raw
events to `<checkout>/.orc/runs/<runId>.jsonl` and store `threadId`, last-turn
`usage`, `exitCode` and `rateLimited` on the worker record. They retain the same
hook acknowledgement and Markdown report checks. `pane wait` returns
`rate-limited` with a restart hint when an exec error or stderr indicates a quota,
usage or rate limit. Close that worker and restart the same brief and worktree
with `--kind claude --transport tui`. Exec follow-ups currently require closing
and starting a new worker; the saved thread ID is diagnostic metadata, not an
automatic resume. Workers never answer approvals.

In pane mode, scopers and implementers use pane workers (Codex by default);
review follows the cross-vendor rules and shippers stay native. For one task add
`--here --path <checkout>` and do not edit beside its implementer. Parallel
tasks use dispatch worktrees.
Start requires the checkout's git toplevel; `--allow-subdir` explicitly permits a
subdirectory. `--here` also supports a checkout in another repository.
`--precheck '<cmd>'` runs in `--path` using `sh -c` before creation;
failure returns `precheck-failed`, `exitCode` and the last 40 output lines without
creating a pane or worker record. Check prerequisites that already exist, not a
version bump or export assigned to the worker.

Run `orc pane wait --until report` with the harness's background execution. It
continues through missing-evidence stops until the current run has a report with
Status and Validation, a native user-action block, process exit/error or timeout.
A worker that stays idle without that report for five minutes returns
`turn-ended-no-report` with a hint, because pane workers never resume on their own.
Plain wait reports `turn-ended-no-report` for a turn without evidence. If the prompt
is still unacknowledged after 60 s (for example untrusted hooks in Codex), plain wait
returns `unacknowledged` with a hint instead of running to timeout. `--until report`
keeps waiting and includes the same hint if it times out without acknowledgment.
Prune uses the same ownership/process checks as non-force close and a lock per task
across the repository.
A follow-up (`pane prompt`, with or without `--queue`, or `pane review`) makes its
run current at once. A running wait follows it to the newest run instead of failing
and adds `previousRuns`: each replaced run's `runId`, its `report` (or null) and
`status`; do not start a second wait while one is running. Wait failures return `status: "error"`,
`state: "wait-failed"`, `stderr` and a `hint`, never a stack trace.
`pane prompt --queue` uses Codex Tab or Claude Enter on acknowledged working TUI
workers; `queued` awaits the same UserPromptSubmit acknowledgment as other delivery.
Until then the first turn's Stop keeps only that turn's final-message report, and
plain wait counts its 60 s `unacknowledged` limit only after the running turn ends.
Without `--queue`, busy workers still return `not-sent`. `sent: true` means the
terminal write completed; `status` stays `unconfirmed` until the hook acknowledges it.

To pause, run `orc pane pause <task> --path <dir>`: it sends Esc to a working TUI
worker it owns, waits for the native idle state and records the ended turn, because
an interrupted turn emits no Stop hook. After a manual Esc it only records the idle
turn. It refuses permission or user-action dialogs. Resume with `orc pane prompt`,
which starts a new run with its own report path; never type into the pane by hand.

### Validation profile

Place optional free Markdown in the main checkout's `.orc/validation.md`, beside
`.orc/lessons.md`. Context audits list it as project memory and implementer prompts
tell workers to read it; it overrides the brief's Validate section. Describe three
tiers with concrete commands, for example:

```markdown
# Validation
- edit: run syntax and formatting checks on touched files.
- task: run focused behavior tests for the task.
- gate: run the full suite and coverage once before commit.
```

Workers run only edit and task tiers. The orchestrator alone runs the gate tier once
before commit through `orc gate`; never run two gates at once. `orc gate` preserves
the child exit code, streams stdout/stderr and tees both to `--log` when supplied.
Its lock is `$ORC_GATE_LOCK`, otherwise `${XDG_CACHE_HOME:-~/.cache}/orc/gate.lock`.
The private JSON lock records pid, label, cwd and start time; waiting prints the
holder and age once, then sleeps. Dead owners and owners predating the last boot
by more than five seconds are recovered with a diagnostic. If uptime is unavailable,
live owners are retained.

**Safety defaults:** permission bypass is explicit (`--yolo`), never the default.
Workers must not commit or push. A terminal's `done` indicator is not validation —
review the diff and rerun checks before accepting a task.

## Neovim

- `:Orc` opens the task panel: features, tasks and workers (including pair
  workers without a plan). Open a task's brief, report or diff, focus its Rex
  pane, or send a follow-up. Closing the panel stops only its watchers; workers
  keep running and state is rebuilt from disk and Rex on reopen.
- `:Orc projects` searches `ghq list -p` in a compact Snacks picker and opens a
  fresh Rex session for the selected repository. LazyVim already ships snacks.nvim.

Rex actions can open either view in a floating Neovim and pass the originating app
for session selection. See [Rex integration](docs/rex-integration.md).

## State and integrations

- Plans and capture logs live in the main checkout's `.scratch/<feature>/`.
  `status` lists only `.scratch/<feature>/plan.md`; move finished features to
  `.scratch/.archive/<feature>` to drop them from the snapshot.
  Approved lessons and worker records live in `.orc/`, excluded from Git.
- Every assignment has a `runId`; reports must identify it. An unconfirmed
  delivery is never resent automatically, and a failed follow-up never erases the
  previous report.
- Worker scans skip records whose root or file identity no longer matches; `status`
  lists their file paths in `warnings`. Unreadable or invalid JSON records remain errors.
- `status`, `doctor` and `context` emit `schemaVersion: 1` JSON. New fields are
  additive; consumers should ignore unknown fields and keep the distinction
  between `null`, empty arrays and empty objects. Each task carries a `state`
  (merged, agent, report status, `worktree` or `pending`); plain-text `orc status`
  prints it. Task report status comes from the matching worker's run-specific report,
  never a shared checkout report. A worker report counts only with `Status:` (`done|partial|blocked`)
  and a nonempty `Validation`; markdown bold labels are accepted, and a headed
  `Validation` may hold deeper sub-headings.

**Inkdrop** (optional) reads `INKDROP_LOCAL_USERNAME`, `INKDROP_LOCAL_PASSWORD`
and `INKDROP_LOCAL_SERVER_URL` (default `http://localhost:19840`). Keep
credentials in an untracked local file. Only loopback HTTP is accepted, redirects
are refused, and only the managed `<!-- orc:begin -->` block is replaced. For an
opt-in LaunchAgent shared by Claude, Codex and Rex workers, see
[shared Inkdrop MCP](docs/shared-inkdrop.md).

## Development

```fish
nvim --clean -l test/run.lua
nvim --clean -l test/run.lua --coverage
nvim --clean -l scripts/gen-agents.lua --check
stylua --check lua test scripts bin/orc plugin evals
```

Tests use fake process/network adapters and temporary repositories; they never
call a model or need a Rex server. Coverage has separate 98% gates for lines,
branches and functions ([definitions](docs/coverage.md)).

Paid evaluations are separate: `orc eval` enforces a model cost cap
(`ORC_EVAL_MAX_COST`, default 5 USD).

### Worktrunk project hooks

Use project hooks in `.config/wt.toml` as the deterministic gate before agent
review. For this project's validation, the recommended configuration is:

```toml
[pre-merge]
validate = """
orc gate --label orc-pre-merge -- sh -c '
nvim --clean -l test/run.lua --coverage &&
nvim --clean -l scripts/gen-agents.lua --check &&
stylua --check lua test scripts bin/orc plugin evals'
"""

[pre-start]
copy = "wt step copy-ignored"
```

With project hooks approved, `orc wt merge` refuses a failing `pre-merge` check.
Approve them before relying on the gate: declining approval skips project hooks.
`pre-start` blocks worktree creation until it finishes, so dependencies exist before
`orc pane start`; `post-start` runs in the background and can race a worker or
`--precheck`. `copy-ignored` copies ignored build caches and dependencies such as
`node_modules` from the primary worktree; a package install (for example
`bun install`) also works. Limit
copies to intended caches with `.worktreeinclude`.

Task worktrees live in `.worktrees/` inside the main checkout, so they inherit the
project's Codex trust and stay within the orchestrator's project directory. Git and
rg skip them through `.git/info/exclude`; tools that walk the tree themselves do not.
Exclude `.worktrees/` from watchers, type checkers and test runners (for example
tsconfig `exclude`, Jest `modulePathIgnorePatterns`, Metro `resolver.blockList`,
ESLint ignores), or the main checkout indexes and runs in-flight tasks, and Metro
reports duplicate modules once `copy-ignored` copies `node_modules`.

Verified with Worktrunk v0.81.0 (`wt --help`, `wt hook --help`,
`wt step copy-ignored --help`) and the official
[hook](https://worktrunk.dev/hook/) and
[copy-ignored](https://worktrunk.dev/step/#wt-step-copy-ignored) documentation.

See also [cutover](docs/cutover.md) for migrating from the earlier Orchestra plugin.

## License

[MIT](LICENSE)
