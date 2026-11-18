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
condition and both existing lock tests to pass. The plugin arm requires a
matching non-error `orc:implementer` `Task` result before the `orc:reviewer`
call, then a matching non-error reviewer result. The isolated eval uses the
native reviewer when the active rules call for external model review. Add
`--keep-temp` to retain the trace. To verify each handback, find its `tool_use`
ID in the run's `trace_path` and follow it to the matching `tool_result`.
A non-error result can acknowledge a background launch. In that case inspect
the completion notification and verify the implementer finished before review.

Both cases check the saved Git state and reject recognizable `git commit`
calls and shipper invocations in the trace. Bash matching is lexical. Quoted
examples can match, and commands hidden in scripts or aliases can escape
detection.

The boundary scaffolds record the resolved Git executable in `check.lua` and
stage the runner in `test/run.lua`. On macOS they resolve past the Apple Git
shim before the model sandbox starts.

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
