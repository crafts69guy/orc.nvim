# Coverage contract

The test-only instrumenter is Lua and uses Neovim's Lua Tree-sitter syntax tree.
It instruments copies/in-memory chunks, never rewrites production files, and
registers the source inventory before executing tests. An unloaded module and an
uncalled nested function remain visible as uncovered.

The three thresholds are independent and are each at least 98%:

- **Lines:** original source lines containing executable statement sites. Several
  sites on the same line count as one line. Structural delimiters, comments and
  continuation-only expression lines are not executable statement sites. This is
  source-statement coverage, not VM instruction coverage or V8's definition.
- **Branches:** independently observed outcomes of conditions, short-circuit
  evaluation and loop entry. A line hit is never substituted for a branch hit.
- **Functions:** each Lua function body is a static site, including anonymous
  callbacks and functions whose containing module was never loaded.

The report retains original file/line identities. It must report missing source,
parse errors and unsupported constructs as failures, not omit them. Production
modules, entrypoints and scripts are included; test infrastructure is outside the
product inventory. Coverage data from concurrent child processes must be merged
without accepting counters from different source versions.

Before testing product code, a golden corpus verifies partial/complete outcomes,
same-line conditions, short-circuit side effects, nested functions, varargs,
multiple returns, coroutine behavior, zero-iteration loops, break and early return.
Counters must not alter the behavior of the source. Intentional missing-coverage
examples prove that each threshold can independently reject a passing test suite.

Instrumentation changes require their corpus tests as well as the full product
suite. Percentages from this tool are not claimed to be numerically equivalent to
the former Node implementation's coverage.
