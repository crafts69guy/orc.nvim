# Lua behavior and benchmark evaluation

Run `orc eval --case inline-small --runs 1 --ablation none` for an explicit paid
model evaluation. The default cap is USD 5; `orc eval --bench` defaults to USD 20.
`ORC_EVAL_MAX_COST` overrides either cap. Ordinary tests never execute model calls.

Seven behavior cases exercise inline work, one implementer, batching, approved
lesson capture, substantial parallel dispatch and two workflow boundaries.
Two benchmark sizes exercise four utilities and three parsers/evaluators.
Lua specs intentionally replace
JavaScript-specific representation with module tables, structured errors,
UTC epoch milliseconds, Lua patterns and Neovim JSON sentinels.

This is a new benchmark series: establish with/without-plugin baselines on these
Lua tasks. Historical JavaScript time/cost deltas are not directly comparable.
Summarize saved runs with `orc eval summarize [aggregate-result.json]`.
Reports exclude runs failing no-peek guards from means and include mean/median
duration, outcome-only score, agent cost, judge cost and paired deltas.
Arm rows show score and duration ranges (`min..max`). A delta row marks each range
`separated` only when both arms have at least 2 runs and their ranges do not
touch; `overlap` and `n<2` mean no measured difference. Use at least 5 runs per
arm before calling one arm better.

## Workflow routing boundaries

Run both cases from the plugin copy you want to evaluate. The command keeps
reports local and applies the existing USD 5 ceiling to the combined run.

```fish
env ORC_PANES=0 ORC_PAIR=0 ORC_LEVEL=single ORC_EVAL_MAX_COST=5 ./bin/orc eval \
    --tag workflow-boundary --case 'boundary-*' --runs 1 --ablation none
```

Use `--case boundary-typo` or `--case boundary-lock` to rerun one case. Both
cases also carry the default `orc` behavior tag. To compare two versions of
the rules, run the same command in separate plugin copies with identical case
files, model and cost ceiling. Compare the individual routing grader verdicts
in the local results.

`boundary-typo` checks both documents byte for byte and requires checker
output for exactly two uncommitted changes. It checks tool traces for `Task`
and `Agent`, orchestration Skills, and recognizable Orc, Git and model CLI
invocations in Bash. `EnterPlanMode` and `EnterWorktree` are checked when
available. The headless pilot omitted both tools with the documented grants.

`boundary-lock` requires a one-line change to the shared lock's release
condition and both existing lock tests to pass. The fixture supplies a quota
exhaustion result and an unsupported external transport. This isolated harness
offers fresh Claude native subagents through `Task` or `Agent`. The plugin arm
checks that a non-error native implementer result precedes native reviewer
dispatch and that the matching reviewer result also succeeds. It rejects
explicit background dispatch and recognizable shell calls to unavailable review
transports. Add `--keep-temp` to inspect each `tool_use` ID and its corresponding
`tool_result` in the run's `trace_path`. This case supplies availability as input
and checks routing and handback. Live provider errors, Rex pane transport and the
reviewer's finding accuracy require separate checks.

Both cases check the saved Git state and reject recognizable `git commit`
calls and shipper invocations in the trace. Bash matching is lexical. Quoted
examples can match, and commands hidden in scripts or aliases can escape
detection.

The boundary scaffolds record the resolved Git executable in `check.lua` and
stage the runner in `test/run.lua`. On macOS they resolve past the Apple Git
shim before the model sandbox starts.

## Reviewer comparison

Offline check from a checkout containing commits `162c5d2` and `588bc8c`:

```fish
nvim --clean -l evals/reviewer/check.lua --self-check
```

The `buggy` and `fixed` prompts share the pre-`162c5d2` parser as their diff base.
The buggy candidate is the parser after `162c5d2`; the fixed candidate is the parser after
`588bc8c`. The self-check replays the latter commit's regression case against
both historical implementations. It also checks grading for a miss, a hit, an
incorrect blocker, an ungraded finding and a clean review. The grader replays
reports with a plain `Run:` and `Status:` header, validation evidence, and a
later plain or Markdown-quoted pair with a different run or status. It counts
`missedKnownBugs` and `incorrectActionableBlockers` independently. Findings
outside that quoted-header case count as `ungradedFindings`. Missing or malformed
reviewer output is a failed or unavailable run. The prompt forbids Markdown
fences, and fenced output stays malformed: in a 2026-11-25 Opus A/B under the
earlier wording, 15 of 20 replies wrapped the array in a fence.

### Historical parser comparison

Treat the candidate as Claude-authored. Claude is the fresh same-vendor arm and
Codex is the cross-vendor arm. Both providers receive the same prompt file for
each candidate. Choose this setup or the fix-round setup below, then use the
shared loop.

```fish
set -l checker (pwd)/evals/reviewer/check.lua
set -l eval_dir (mktemp -d)
set -l review_variants buggy fixed
```

### Fix-round rechecks

Both arms get the original finding, the parser contract and the diff from `buggy`
to `symptom`. The partial fix stops at a new Markdown heading once it has the
header and validation evidence. It handles the original report, while a quoted
Run and Status pair without a new heading can still overwrite the header.
The self arm adds the implementer's first-person fix rationale and asks it to
review its own fix. This single-shot prompt only approximates a live worker's
context across implementation and review turns.

Run both arms on Claude and on Codex. Compare `missedKnownBugs` and
`incorrectActionableBlockers` between arms within each provider. All four
outputs are graded against `symptom` using the same criteria. Treat one pass as a
pilot. Collect at least 5 runs per arm within each provider before calling one
arm better.

```fish
set -l checker (pwd)/evals/reviewer/check.lua
set -l eval_dir (mktemp -d)
set -l review_variants fixround-fresh fixround-self
```

### Run the selected comparison

Either comparison requires an explicitly approved model budget and authenticated
Claude and Codex CLIs. Each pass uses up to four paid invocations. The Claude cap is
per invocation. Use Codex only within its separately approved usage limit.
Start every invocation as a fresh session. Record model IDs, output and exit
status for each call. If quota or transport prevents a run, record the unavailable
arm and the reason.

Set `review_claude_model`, `review_claude_cap` (USD per call), and
`review_codex_model` to the approved values in the same Fish shell.

```fish
set -l prompts_ready 1
for variant in $review_variants
    if not nvim --clean -l "$checker" prompt "$variant" > "$eval_dir/$variant.prompt"
        printf 'Failed to generate prompt for %s.\n' "$variant" >&2
        set prompts_ready 0
        break
    end
end

if test "$prompts_ready" = 1; and cd "$eval_dir"
    for variant in $review_variants
        set -l grade_variant "$variant"
        if string match -q 'fixround-*' "$variant"
            set grade_variant symptom
        end

        claude -p --tools '' --setting-sources '' --strict-mcp-config \
            --max-turns 1 --max-budget-usd "$review_claude_cap" \
            --no-session-persistence --model "$review_claude_model" \
            < "$variant.prompt" > "claude-$variant.json" 2> "claude-$variant.log"
        echo $status > "claude-$variant.status"

        codex --no-daemon -a never exec --ignore-user-config --ignore-rules \
            --ephemeral --sandbox read-only --skip-git-repo-check \
            -m "$review_codex_model" -o "codex-$variant.json" - \
            < "$variant.prompt" > "codex-$variant.stdout" 2> "codex-$variant.log"
        echo $status > "codex-$variant.status"

        for reviewer in claude codex
            test (cat "$reviewer-$variant.status") = 0; or continue
            printf '%s %s\n' "$variant" "$reviewer"
            nvim --clean -l "$checker" grade "$grade_variant" "$reviewer-$variant.json"
        end
    end
end
```

## Rex smoke

Run the offline self-check with Neovim and Git on PATH:

```fish
nvim --clean -l evals/rex-smoke.lua --self-check
nvim --clean -l evals/rex-smoke.lua --self-check --transport tui
```

The TUI self-check runs fake Codex in a local PTY and exercises paste, Tab,
Enter, and report hooks.

To exercise real Rex, run either command from this checkout in an existing
local Rex terminal with `REX_BLOCK` set. The smoke uses `REX_SESSION` when set and
queries `rex whoami --json` for the session otherwise. It requires an already
running local Rex server and a compatible Rex CLI on PATH or in the app bundle.
Run without a model account or paid eval budget:

```fish
nvim --clean -l evals/rex-smoke.lua
nvim --clean -l evals/rex-smoke.lua --transport tui
```

The smoke creates a private Git repository and checkout in the temp directory.
By default it starts one unfocused exec worker in the existing session with only
the fake Codex on its PATH. The smoke verifies acknowledgment, matching report
and close.
It deliberately stops the first event client and observes its exit. It can
relabel its own pane to generate an event and releases the fake worker after
decoding an event from the replacement watch.

The TUI smoke verifies that the worker acknowledges its startup prompt. While
the worker is working, it queues a follow-up with `pane prompt --queue` and
checks that `pane wait --until report` returns that follow-up's done report and
lists the replaced run in `previousRuns`. It then sends an Enter-submitted
`pane prompt` to the idle worker and checks for acknowledgment and a done report.

In both transports the smoke checks Rex for the owned pane after close. If the
pane is still listed or the check fails, the script prints and retains its temp
root and ownership record.

## Scaffold adapter

All tracked fixture/check/runner/reference/hidden implementation is Lua.
Claude Code 2.1.316 hardcodes `bash FILE` for `context.scaffold_script`, ignoring
the file's shebang. Therefore invoke the suite through `orc eval`, which builds
an ignored `.eval-plugin/` copy and generates one-line Bash **exec launchers**:
they only launch the absolute Neovim executable with the copied Lua fixture.
No fixture business logic is implemented in Bash, and source case files are unchanged.
Direct `claude plugin eval` on unbuilt source cases is not supported by that harness.

Standalone Lua fixtures can still run in an empty directory:
`nvim --clean -l /absolute/plugin/evals/inline-small/fixture.lua`.
Fixtures require a completely empty target directory and refuse existing files,
including Git metadata, before any write or Git command. The installed harness
creates an empty `home/cwd` directory; its isolation Git metadata lives in the
parent `home/.git`, outside the scaffold target.

Benchmark scaffolds store hidden suites in `.git/acceptance.tgz`; only generated
`check.lua` extracts and removes them. Graders reject tool reads of that archive
or extraction directory. Running the checker early may disclose aggregate scores;
as in the original experimental setup, this is a detection gate, not a security sandbox.
