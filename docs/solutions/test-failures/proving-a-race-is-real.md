---
title: "A green concurrency test can be a sequential run wearing a costume"
summary: "Four ways a race harness passed while testing nothing, and the barrier discipline that fixes all four."
module: test-suite
date: 2026-07-28
problem_type: test_failure
component: testing_framework
severity: high
source: "PR #22 (U4), PR #23 (U5), PR #25 (U6), PR #29 (U8)"
root_cause: async_timing
resolution_type: test_fix
tags:
  - concurrency
  - race-conditions
  - postgres
  - exclusion-constraints
  - test-barriers
applies_when:
  - "writing a test that proves a lock, unique index, or exclusion constraint is load-bearing"
  - "a concurrency test flakes intermittently"
  - "relying on a database constraint as a race guard"
---

# Proving a race is real

A test that starts two workers and asserts one of them lost is the easiest kind of test to
write and the easiest kind to get wrong. Four separate failures here, each producing exactly
the green tick an implementation with no guard at all would produce.

## 1. The barrier counted the wrong waiters

The harness waited for "some backend blocked on a lock in this database" before releasing the
racers. Any unrelated waiter satisfied it, the racers then ran sequentially, and the test
passed. The fix: each racer reports the specific backend id its connection is pinned to, and
the barrier waits for **those**.

**Assert that the racers are demonstrably parked on the specific resource**, not that
something somewhere is waiting.

## 2. The racers started before the barrier existed

`Task.async/1` starts a process the moment it is called, so a list of tasks built at the call
site is already running while the barrier is still acquiring the lock they are supposed to park
on. Measured at roughly one flake in three, always with one racer idle having already
committed. The fix is to pass a zero-arity closure and construct the tasks **inside** the
barrier, after the lock is held.

Any eagerly-starting concurrency primitive has this problem. Check whether yours starts on
construction or on await.

## 3. A failed barrier hung the whole suite, permanently

The barrier wait had no `try/after`, so when its five-second budget flunked, the release never
ran. The holder sat forever inside an open transaction holding `FOR UPDATE` — and process links
did **not** reclaim it, because the test framework catches the assertion failure in the test
process, which therefore exits `:normal` and leaves its linked children alive. Cleanup then
issued a plain delete against the locked rows with no statement timeout, so cleanup hung too,
and every later test sharing that fixture hung behind it.

**Put barrier releases in `after`/`finally`. Give cleanup paths a statement timeout. Do not
assume your runtime's supervision reclaims children after a *caught* failure.**

## 4. The constraint does not raise the error you documented

Two moduledocs promised that a concurrent overlapping insert arrives as a changeset error.
Measured with two live racers, it arrives as **`40P01 deadlock_detected`**: each backend
inserts its index tuple, then waits on the other's transaction. This is inherent to Postgres
`EXCLUDE` constraints, and an already-merged exclusion constraint one unit earlier had the same
property that nobody had noticed.

A **unique index** behaves differently — the second inserter waits, then raises a uniqueness
violation — which is why a unique index can carry two real racers and an `EXCLUDE` cannot. If
you rely on a constraint as your race guard, find out which error your callers actually receive
under simultaneity, and build the test around the case the docs describe: a caller that
demonstrably passed its friendly pre-check against an empty table, then meets a **committed**
conflict.

## Two more things worth knowing

- **Some races are defeated by one interleaving and not the other.** Where the bug depends on
  *arrival order* rather than collision, racing symmetrically passes half the time against the
  bug it names — which is worse than having no test. Start the racers one at a time and wait
  for each to park before starting the next; the database serves waiters on one row in arrival
  order.
- **Assert the returned value, not only the stored row.** Two concurrent "close this once"
  calls both did read-then-`update` by primary key. Both succeeded, the later commit won, and
  the earlier caller was handed a struct whose field did not match the row. The end state was
  correct, so a suite asserting only persisted state passed. The fix is one conditional
  `UPDATE ... WHERE closed_at IS NULL`, so the loser gets the refusal it would have got a
  moment later. An optimistic lock is the wrong shape here: `:stale` is only honest for a
  *repeatable* mutation, and closing a period happens once.
