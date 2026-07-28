---
title: "Twenty-one tests that read as coverage and provided none"
summary: "Assertions that cannot fail have a small number of recurring shapes; the reliable way to find them is to break the code and watch nothing go red."
module: test-suite
date: 2026-07-28
problem_type: test_failure
component: testing_framework
severity: high
source: "U3 through U12, the pull request that added CI, and two follow-up batches (PRs #19, #25, #29, #30, #32, #33, #34, #35, #37, #38, #39, #41)"
root_cause: logic_error
resolution_type: test_fix
tags:
  - mutation-testing
  - vacuous-assertions
  - test-controls
  - coverage
applies_when:
  - "writing a test whose job is to prove a guard, filter, or constant is load-bearing"
  - "writing a control assertion beside a positive one"
  - "reviewing a test suite that has never been mutation-checked"
---

# Twenty-one tests that read as coverage and provided none

Across twelve units, the pull request that first added CI, and two follow-up batches, this
project found twenty-one tests that a reader would call coverage and that could not fail for the
reason they named. Every one was written deliberately, most by someone consciously adding a
*control*.

**The tally, so the number is checkable rather than asserted:** three in #19, one in #25, two in
#29, one each in #30, #32 and #33, three in #34, one in #35, two in #37, three in #38, one in
#39, two in #41. Each shape below carries the same references, and they sum to the same total,
so the headline is a count of something rather than a claim about it.

Most were found by mutation: break the thing under test, run the suite, see what stays green.
The rest name the other disciplines that work — running the suite on a second machine, writing a
new test red before making it pass, and reading a fixture's calendar against the constant it was
meant to pin. Almost none was found by reading the test itself.

## The generative rule: an absence assertion passes by default

This suite's central claim is that one database role holds no privilege on a set of tables.
Every test of that shape was green from the first commit — because Postgres default-denies on
a table owned by another role, so the assertions would have passed with the migration deleted.
The suite could not distinguish *"we revoked it"* from *"nobody ever granted it."*

Generalise it: **whenever a test asserts a negative — no permission, no row, no event, no
header, no field — ask what would have to change for it to fail. If the answer is "nothing in
this diff", it is decoration until you pair it with a control that makes it fail.** Here that
means granting the privilege behind the sweep's back inside a rolled-back transaction and
asserting the sweep reports it; and granting, rolling the migration down and up, and asserting
it is gone — which is the only test proving the `REVOKE` statements execute at all.

## Your controls inherit the blind spot of the thing they control

The privilege sweep used `has_table_privilege`, which is blind to *column*-level grants. So
`GRANT SELECT (email) ON people TO employer_role` — a total defeat of the product's central
promise — produced **zero test failures**. And no control could ever have caught it, because
every control in the suite granted at table level too. The identical shape recurred one unit
later with a dependency canary narrowed to relations, blind to function-level grants, again
controlled only by table-level violations.

**Write at least one control in a different shape from the one your assertion naturally takes.**
If the check is table-scoped, control it with a column-scoped violation. If it is about
relations, control it with a function. If it is about rows, control it with a view.

## The shapes, each one real

- **Both operands empty** (#19 twice, #38). `assert offenders == []` where `offenders` came from
  a set nobody had asserted was non-empty: replacing the whole source list with `[]` left 53
  tests green. The two earlier ones were a migration's down/up round trip comparing `[] == []`
  for its table component, and a disjointness check between two zones that were both empty.
- **A count comparison over empty tables** (#37, #38). A "nothing else was deleted" bound
  compared row counts table by table — and an empty table compares 0 to 0. It was vacuous over
  14 of 23 tables; four planted `delete_all` calls produced 28 passes and no failures. One unit
  later the same shape bounded "seeds are idempotent" over 4 of 23.
- **A key comparison between two structs of one type** (#34). `Map.keys(a) == Map.keys(b)` where
  both are the same struct: `defstruct` fixes the key list at compile time, so the assertion
  is invariant under every possible difference in content. A real extra field was added to
  the underlying query and the test still passed.
- **A substring filter over names** (#34). "No exported function whose name contains *attested*
  except this one read" is satisfied by `edit_entry/3` and `restate/2` — which are the two
  names a future writer would most plausibly choose. Replaced by pinning the module's whole
  export list against a literal.
- **A matrix that reimplemented half the rule it was checking** (#29). A 5x9 table claimed to
  compare a SQL predicate against its Elixir twin. It called the Elixir function — but that
  function was only the *containment* half of the rule, and the *overlap* half had been
  restated in the test file. Over half its surface the matrix compared the SQL against the
  test's own idea of it. The input shape where the two spellings actually disagree was the one
  shape the matrix never tried.
- **A guard exercised from one side only** (#29, #41). Two independent non-emptiness clauses
  were reported as "drop both, one test fails". One failing test for two clauses was the tell:
  the single test always emptied the same operand and always asked from the same side, so one
  clause was permanently bound to one role. Dropping the other passed the entire suite. The same
  shape reached a pair of statements two units later — a batch bound asserted over one of the
  two statements that carried it, the other's `limit:` removable with nothing failing.
- **A fixture that made the operation under test the identity** (#25, #30, #37). A 90-day
  retention window mutated to 30, and to 2, killed zero tests: the fixture already separated the
  two dates by more than the constant, so the assertion was satisfied by unrelated arithmetic.
  Elsewhere every instant in a unit's tests carried zero microseconds, so truncation was the
  identity and four changesets' sub-second stamping was never exercised; and a normalisation
  test used ids that were all digits, so `toUpperCase()` was a no-op.
- **A wording assertion standing in for a state assertion** (#38). The refusal test asserted the
  response said "Nothing was ended". With the guard removed the endpoint ended one record,
  hit the real refusal on the second, and returned the same message. Green.
- **"Cleared" and "never set" as the same DOM** (#35). A test asserted no record was on screen
  after a refused read — but no record had ever been on screen. The fix was a second test
  that reads *successfully first*, then refuses.
- **An allowlist a sibling walked through** (#34). A structural check that queries live in one
  module carried an eight-entry exemption list; a sibling composing `where/3` matched an
  exempt entry and passed.
- **A privilege assertion that could only pass** (#19). Postgres grants `EXECUTE` to `PUBLIC` on
  every new function, so the test asserting a role held it was true before the grant existed.
- **A setup that satisfied the assertion for a second reason** (#32, #39). A "confers nothing"
  test used a shift room that was closed at both instants, so its assertions passed for the
  closure rather than for the engagement being unstarted; the mutation that should have killed
  it left it green. On the client, a section was hidden by the route *and* cleared by the code
  under test, so removing the clear failed nothing.
- **A branch only one machine could reach** (#33). See
  `a-green-suite-can-be-a-property-of-the-runner.md`.
- **A test whose inputs derived from the constant it was pinning** (#41). Every assertion in a
  rate limiter's suite built its loop from `limit/0`, so raising the limit to a million killed
  nothing. A limit test that can never reach its limit is the purest form of this whole file.

## The common shape

Every one of them compares a value against something that moves with it: the other side of
the same expression, a struct's own compile-time shape, an empty set, a fixture that already
guarantees the answer, the constant under test. **A control is only a control if you can name
the mutation it catches and the mutation is one somebody would plausibly make.**

## What to do instead

- Before you trust an assertion, **mutate the code it names and watch it go red.** Delete the
  filter, invert the comparison, change the constant in both directions. If nothing fails,
  the test is decoration. Record the mutation count in the PR; this project ended up carrying
  "28 mutations, 28 caught" as a routine line.
- **Assert against something written down** — a literal field list, a named enum of expected
  values — rather than against the other side of the comparison.
- **Never derive a test's inputs from the constant it is pinning.** Write the boundary out.
- **Assert the operand set is non-empty before you assert anything about it.** `assert
  tables != []` in front of the sweep is one line and retires a whole class.
- **Pin both directions of a constant.** Test at `bound - 1` and `bound + 1`, not just past it.
- **Prefer a state assertion to a message assertion.** Count the rows around the call.
- **Make the negative test reach the positive state first**, so "removed" is distinguishable
  from "never there".
- **Hold every variable but one constant.** A test whose setup satisfies the assertion for a
  second reason is not a test.
- **Treat a low mutation-kill count as a signal, not a result.** N independent clauses that
  between them kill one test almost certainly means N-1 of them are unexercised.

## One sentence to distrust more than any test

**A claim in the documentation about what a test asserts is the highest-risk sentence in a
repository**, because it is the one that stops anyone going to look. This project shipped a
`CLAUDE.md` paragraph asserting that a credential was re-derived on every use, inside the unit
whose whole design depended on it, while the code derived it once and cached it forever. When
you find one wrong claim of that kind, re-check every count in the same section — the review
that found this one found a second in the same paragraph. This file's own title was wrong for
the same reason: nobody re-counted the list underneath it.
