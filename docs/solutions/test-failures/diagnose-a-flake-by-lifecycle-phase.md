---
title: "A flaky test usually awaits a render-time fact and asserts an effect-time fact"
summary: "Diagnose the flake by asking which lifecycle phase each fact belongs to; the fix is a promise resolved by the event you care about, and it is four times faster than the timeout."
module: client
date: 2026-07-28
problem_type: test_failure
component: testing_framework
severity: medium
source: "PR #30 (U12 rooms)"
root_cause: async_timing
resolution_type: test_fix
tags:
  - flaky-tests
  - react
  - testing-library
  - waitfor
  - act
applies_when:
  - "a UI test fails intermittently"
  - "tempted to raise a timeout or add a retry"
  - "testing code split between render and post-commit effects"
---

# Diagnose a flake by lifecycle phase, not by timeout

One test failed roughly one run in twelve. The cause was not timing sensitivity in the loose
sense — it was a **category error about lifecycle phases**:

- the provider published its object from a `useMemo`, which runs at **render**;
- it opened the connection from a `useEffect`, which runs **after commit**;
- `waitFor`'s MutationObserver fires at **commit**.

So the test waited on a render-time fact and then asserted an effect-time fact. Most of the
time the effect had already run. Sometimes it had not. Three of the four tests in that file had
the same defect; only one of them ever lost the race, which is why it read as one flaky test
rather than as a pattern.

## The fix

Give the fake `opened` / `closed` promises that resolve when `connect()` is actually called,
and have the test await **the fact it asserts**. Not a longer `waitFor`, not a retry.

It was also **four times faster** — 39ms against 160ms — because there is no poll interval to
sit through. That speed difference is a reliable signal that you found the right fix.

## The wrong turn worth recording

`act(async () => await p)` **deadlocks**: `act` awaits its callback before draining its queue,
so the effect that would resolve `p` never runs. This was verified against React's own source
during review rather than worked around.

## What to do differently

- When a test flakes, ask which lifecycle phase the awaited fact belongs to and which phase the
  asserted fact belongs to. If they differ, that is the bug, and no timeout closes it.
- **Do not raise a timeout.** A one-in-ten failure is a coin flip that eventually lands on
  someone with no context — before CI that is whoever runs the suite next; after CI it is
  whichever pull request happens to be open.
- **Check the sibling tests immediately.** The defect is nearly always shared across the file
  and only one instance is unlucky enough to show it.
- The same reasoning gives you positive assertions you could not otherwise write: one test here
  distinguishes "left deliberately in the handler" from "left by the unmount that followed",
  because the store write runs at render and unmount cleanup at commit, so the snapshot is
  provably taken before the unmount could have acted.
