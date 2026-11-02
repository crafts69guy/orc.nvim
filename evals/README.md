# Lua behavior and benchmark evaluation

Run `orc eval --case inline-small --runs 1 --ablation none` for an explicit paid
model evaluation. The default cap is USD 5; `orc eval --bench` defaults to USD 20.
`ORC_EVAL_MAX_COST` overrides either cap. Ordinary tests never execute model calls.

Five behavior cases exercise inline work, one implementer, batching, approved
lesson capture and substantial parallel dispatch. Two benchmark sizes exercise
four utilities and three parsers/evaluators. Lua specs intentionally replace
JavaScript-specific representation with module tables, structured errors,
UTC epoch milliseconds, Lua patterns and Neovim JSON sentinels.

This is a new benchmark series: establish with/without-plugin baselines on these
Lua tasks. Historical JavaScript time/cost deltas are not directly comparable.
Summarize saved runs with `orc eval summarize [aggregate-result.json]`.
Reports exclude runs failing no-peek guards from means and include mean/median
duration, outcome-only score, agent cost, judge cost and paired deltas.

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
