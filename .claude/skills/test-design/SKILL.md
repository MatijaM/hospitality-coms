---
name: test-design
description: Use before implementing feature, bug-fix, refactor, or ticket work when tests need to be designed before production code changes, especially before /compound-engineering:ce-work, /compound-engineering:ce-debug fix steps, or any implementation after /compound-engineering:ce-plan. Produces a Test Design Brief, writes failing tests only, confirms red for the expected reason, and stops for approval.
---

# Test Design Gate

Use this skill to make the tests better before implementation starts. You are acting as a test architect, not an implementer.

## Hard Rules

- Do not modify production code while this skill is active.
- Create or update tests only after the Test Design Brief is written.
- Test observable behavior, not implementation details.
- Do not weaken, delete, or loosen existing assertions to make a future implementation easier.
- Mock only external API boundaries such as Stripe, Square, Google Calendar, email, or S3. Never mock Ecto repositories.
- **If the change touches `client/`, read "The gate applies to `client/`" in `AGENTS.md` before writing the matrix.** Everything else in this file is phrased for a context, a schema or a migration, and a brief written from it alone will not ask which render state is being claimed, whether the fixture can tell the two compared values apart, whether an already-stored shape still decodes, or whether a faked transport can see the assertion at all. Each of those is a defect this project shipped.
- Run the narrowest relevant test command and confirm at least one new or changed test fails for the expected reason.
- Stop after the red test is confirmed. Ask the user to approve the tests before any production-code changes.

## Workflow

1. Read `AGENTS.md` and `CLAUDE.md`.
2. Read the feature request, bug report, Linear issue, plan, or design artifact.
3. Inspect the existing code and tests enough to identify the observable behavior, boundaries, current test patterns, factories, authorization coverage, and likely regression paths.
4. Write a Test Design Brief before editing tests.
5. Score the planned tests with the rubric below. Revise the plan until every applicable score is at least 4, or state the unresolved gap clearly.
6. Create or update tests only.
7. Run the narrowest test command that exercises the new or changed tests.
8. Confirm the failing test output matches the expected missing behavior.
9. Stop and ask for approval to proceed to implementation.

## Test Design Brief

Use this shape:

```markdown
# Test Design Brief

## Feature behavior
What changes from the user's point of view?

## Non-goals
What should stay unchanged?

## Acceptance criteria
- Given ...
- When ...
- Then ...

## Edge cases
- Empty or missing input
- Invalid permissions
- Duplicate or repeated request
- Race, idempotency, or transaction boundary
- Missing dependency or provider failure
- Rollback or error path

## Regression risks
Which existing behavior could break?

## Test matrix
| Level | Test | Why it matters |
|---|---|---|
| unit | ... | ... |
| context | ... | ... |
| API | ... | ... |
| migration/data | ... | ... |

## Tests to add or change
- `path/to/test_file.exs`

## Implementation constraints
- Do not change public API unless the behavior requires it.
- Do not weaken existing tests.
- Preserve tenant scoping, permissions, and logging rules from `AGENTS.md`.

## Quality scores
| Dimension | Score | Notes |
|---|---:|---|
| Behavior coverage | 1-5 | ... |
| Edge cases | 1-5 | ... |
| Regression protection | 1-5 | ... |
| Failure paths | 1-5 | ... |
| Permission/security coverage | 1-5 | ... |
| Implementation independence | 1-5 | ... |
```

## Test Layers

Choose the smallest layers that prove the change, but consider every relevant row:

- Domain or pure-function tests for deterministic business logic.
- Context tests for tenant-scoped queries, persistence, transactions, logging-sensitive inputs, PubSub, and Ecto changesets.
- Worker tests for Oban args, retry behavior, idempotency, and provider failure handling.
- Controller tests for request boundaries, redirects, auth errors, params, and external webhook surfaces.
- Migration or data tests when schema shape, backfill behavior, constraints, or indexes are part of the change.

## Red Confirmation

When running the focused test, report:

- Command run.
- New or changed test that failed.
- Expected failure reason.
- Whether the failure proves the missing behavior.

If the new test passes immediately, do not implement. First determine whether the behavior already exists, the test is too weak, or the wrong surface was tested.
