---
title: "A mutation that kills nothing has three possible causes and only one is a coverage hole"
summary: "Before writing a test for an unkilled mutant, rule out a redundant guard covering it and an equivalent mutant that cannot diverge."
module: test-suite
date: 2026-07-28
problem_type: test_failure
component: testing_framework
severity: medium
source: "PR #37 (U10) and PR #38 (U11)"
root_cause: logic_error
resolution_type: test_fix
tags:
  - mutation-testing
  - equivalent-mutant
  - redundant-guards
  - code-review
applies_when:
  - "a mutation-testing run reports an unkilled mutant"
  - "a reviewer asks for a test covering a branch that seems untestable"
---

# What a zero-kill mutation means

Mutation testing gives you one number and three possible stories behind it. Writing a test is
the right response to only one of them, and this project got each of the other two wrong once
before learning to tell them apart.

## (a) A genuine coverage hole — write the test

The ordinary case, and the one most zero-kills are. Example: three person-scoping filters
could each be deleted with the whole suite green; unfiltered, the first returned every
person's private ledger to any caller, which its own docstring said must not happen.

## (b) A redundant guard elsewhere is covering it — delete one, do not test both

Two guards enforced the same invariant from different modules: a worker dispatched an archive
write on a status, *and* the function it called refused the same case itself. **Deleting either
one killed no test, because the other covered it.** No test could distinguish them, and adding
one would have pinned an accident.

The fix is not a test. It is to delete one guard and make the survivor authoritative. Redundant
guards and dead guards are indistinguishable under mutation, and the redundant pair is worse
than either alone: nobody can tell which one the invariant actually rests on.

## (c) An equivalent mutant — fix the documentation, not the suite

A reviewer measured that changing a comparison to a constant `true` killed zero tests, and
asked for a test making the difference observable. **That test could not exist.** The window
query selected `ends_at <= instant` and the worker broadcast unless `ends_at > instant`, both
from one clock — so the two branches are the same branch, and no input separates them. The
zero was not a hole; it was the two conditions being provably identical.

A different mutation of the same line (to a third value, rather than to `true`) killed four
tests, which is what confirmed the branch was covered at all.

The right responses were:

1. **Rewrite the documentation that claimed they could diverge** — a typedoc had described two
   outcomes where only one was reachable, which is what made the reviewer's request look
   reasonable.
2. **Add the equality assertion** that would fail if the two ever *stopped* agreeing. That is
   the real risk, and it is a different test from the one asked for.

## The rule

When a mutation kills nothing, ask in this order: *is another piece of code compensating?*
(then delete one), *can any input separate the two branches?* (if not, fix the prose and pin
the equivalence), *and only then* write the missing test. And note the converse signal: **N
independent clauses that between them kill only one test is a low number, not a passing one** —
it usually means N-1 of them are unexercised.
