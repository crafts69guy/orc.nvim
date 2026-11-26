---
name: test-discipline
description: "orc workflow: write few tests that catch real bugs and edge cases. Use when adding, changing or reviewing tests."
disable-model-invocation: true
---

# Test discipline

Coverage shows which code ran, not what was checked. Optimize for evidence that a
test fails when the behavior it names breaks, with as few tests as that takes.

## Rules

| Rule | Summary |
| --- | --- |
| Protect existing tests | Never delete, skip or weaken an existing test or assertion, or change an expected value, to pass a check. If a test contradicts the brief, stop and report it as blocked. |
| Red before green | A test for a bug or new behavior must fail on the code before the change, for the reason it names, not a syntax or setup error. A test that already passes proves nothing. |
| Every test earns its place | Each new test guards a reproduced bug, an edge case from the brief, or a property. Drop tests that only execute code or restate the implementation. |
| Spec, not current behavior | Derive expected values from the brief, docs, types or a simpler oracle. Never run the code and copy its output into the assertion. When the spec is ambiguous, such as `>=` against `>`, ask instead of encoding a guess. |
| Edge cases first | Cover the brief's edge cases before more happy paths: empty or nil, boundaries and off-by-one, invalid input at trust boundaries, errors and partial failure, retried, late or duplicate events, concurrent writers, cancellation, unicode and paths with spaces. |
| Mutation probe | Before reporting, break up to five of the riskiest changed decisions one at a time: flip a comparison, swap `and`/`or`, drop a return or call, invert a branch. Run the targeted tests, then restore the code and confirm the diff is unchanged. Report killed and surviving mutants. |
| Deterministic | No fixed sleeps: wait on the condition with a timeout and a clear error. Seed randomness, fake time and stub the network. Run each new test file three times; a test that ever fails is flaky and must be fixed. |
| Coverage is a diagnostic | Use coverage reports to find untested modules and branches, never as a target. Do not add tests only to raise a percentage. |

A surviving mutant is a question, not a task. If the brief specifies the mutated
behavior, add the missing test. If it does not, report the survivor and ask; never
write a test that asserts whatever the code does today.

## Property tests

Use a property when a test name says "always" or "never", or the code has a
round trip, invariant, idempotence or a simpler reference implementation.

- Strength, weakest first: no crash, type or shape preserved, invariant,
  idempotence, round trip or comparison with an oracle. Push past "no crash".
- Build inputs whose outcome you know, such as `a .. b .. c` always containing
  `b`. Do not reimplement the code under test inside the test.
- Constrain generators only where the spec does. No arbitrary maximum lengths or
  ranges. Generate valid values directly instead of filtering.
- Assert characteristics of the result, not the whole value.
- Keep a few example tests as documentation. Properties find edge cases; examples
  show usage. Turn each shrunk counterexample into a regression example.

| Stack | Library |
| --- | --- |
| JavaScript, TypeScript | `fast-check`, with `@fast-check/vitest` or `@fast-check/jest` |
| Python | Hypothesis |
| Rust | proptest |
| Go | rapid |
| Lua | a seeded generator in the test helpers; print the seed on failure |

## JavaScript and TypeScript

If the project lacks `fast-check`, recommend once that the user add it as a
devDependency. Install only with their approval; until then write example tests
and name the properties fast-check would check.

- Always `await fc.assert(...)` inside an `async` test. fast-check v4 needs
  `fc.asyncProperty` for async predicates; v5 uses `fc.property` for both.
- With `@fast-check/vitest`, pass the arbitrary function to `g`: `g(fc.string)`,
  not `g(fc.string())`.
- Drive time and randomness through fast-check, such as
  `vi.setSystemTime(g(fc.date, { noInvalidDate: true }))`, so a failure reports
  the exact value.
- For code that takes async callbacks, use `fc.scheduler()` to explore
  resolution orders and catch races.
- Prefer stubs over call-count mocks, stub the network with `msw`, and query the
  DOM by role, label or text before test IDs.
- Snapshot only when the expected content is clear; warn when the code under
  test needs more than ten parameters, stubs or mocks to set up.

## Reviewing tests

- Treat removed, skipped or loosened assertions and changed expected values as
  defects unless the brief asked for them.
- Check that each new test guards a bug, a brief edge case or a property, and
  that the red evidence fails for the named reason.
- Triage reported survivors: specified behavior means a missing test;
  unspecified behavior is a question for the user.
- Rerun at least one reported red or mutation result yourself when your limits
  allow; agent-reported scores are often wrong.
