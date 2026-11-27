---
name: no-comments
description: "orc workflow: before any model review of a delegated diff, delete comments through comment-sicko, act on its flags and offer encodings for claimed constraints."
disable-model-invocation: true
---

# No comments

Run `comment-sicko` with fresh context and act on the findings you accept.
Defer to its fresh perspective; it did not write the code.

## Scope

Use the files or diff you were given. Otherwise use the task checkout's diff
against its base, including the working tree and untracked files. In dispatch,
run it after the implementer's `done` report and deterministic checks, and before
`orc pane review` or `orc pane review-begin` fingerprints the checkout. After a fix
round, run it on the paths that round changed. It edits the checkout, so the
worker must be idle or exited first: a `--until report` wait can return while the
worker is still `working`; wait again without `--until report`.

## Steps

0. Search the scope's added lines and untracked files with `rg` for the comment
   syntax of each language in it, for example `git diff -U0 HEAD -- <paths> |
   rg '^\+.*(//|/\*|--)'` for TypeScript and Lua. With no match, skip
   comment-sicko and record the command and the zero count in the task log.
1. Start `orc:comment-sicko` (Codex: the `comment-sicko` agent) in the task
   checkout with the scope. Pick its reasoning effort for the job. Do not restate
   its rules. Save its report to `.scratch/<feature>/<task>-no-comments.md`.
2. Inspect the report and `git diff`. Reject edits to application code, edits
   outside the scope, deleted exceptions, false `MUST KILL` reasons and flags that
   treat kept, intentional code as guilty. Reshape flags on surprises in our code
   stay actionable; do not restore those comments. A kept comment survives only
   with proof that it is about something we cannot change. Check the scope for
   lint and type suppressions it missed; correctness or safety suppressions stay
   actionable `MUST KILL`s. Restore a deletion only with its exact exception and
   proof from the scope. Before accepting a thin `IMPORTANT` or `do not remove`
   deletion or keep, trace its symbol (callers, `git log -S`, `git blame`). An
   ambiguous deletion stays deleted; a refuted or still ambiguous keep is deleted.
   For a rejected report, revert its edits and rerun once with the failure named.
   If the rerun is also rejected, record it as open and fail this pass.
3. Accepted `MUST KILL` flags are findings for the same implementer. Trivial ones
   (delete a dead path, drop a parameter, use the real API) go straight into the
   follow-up. If any fix needs a new shape, sketch the shape once for the whole
   accepted set and the surrounding code, and stop at the sketch; the implementer
   implements it. Hand the flags to the reviewer as known items and merge them with
   the review findings into one follow-up. The fix is the smallest root-cause change
   in scope and removes every named workaround. Never add a symptom guard. If the
   root cause is out of scope, land the smallest in-scope fix and record the rest
   as open work.
4. A constraint comment (`do not remove`, `do not change wording`, `talk to X
   before changing`) about something we cannot change stays. For the others,
   offer the user the cheapest in-scope type, runtime check, test or CI lint that
   encodes the constraint, and wait for approval. Unattended and eval runs need
   approval given beforehand. If approved, the implementer encodes it in the next
   fix round and the comment is deleted. Otherwise delete it, record the
   constraint as open and sketch the out-of-scope work.
5. Record in the task log: deletion count, restored comments, reruns, the sketch,
   fixes, encoding offers, encodings, unenforced constraints and other open work.
