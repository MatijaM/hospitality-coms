---
title: "Correctness reviewers miss liveness bugs: mechanisms that stop making progress while still reporting success"
summary: "A batch sweep ordered oldest-first under a limit pins itself forever once one batch has accumulated, and job uniqueness spanning terminal states suppresses its own backstop."
module: lib/hospitality_coms/workers
date: 2026-07-28
problem_type: logic_error
component: background_job
severity: high
source: "PR #23 (U5)"
root_cause: logic_error
resolution_type: code_fix
tags:
  - background-jobs
  - liveness
  - batching
  - idempotency
  - oban
  - code-review
applies_when:
  - "reviewing a batched sweep, backfill, or reconciliation job"
  - "configuring job uniqueness or deduplication"
  - "asking what a background mechanism looks like after a year of data"
---

# Mechanisms that stop working while reporting success

Three reviewers independently attacked the correctness of a unit's period arithmetic and its
claim race, and all three failed — the logic was right. Every serious defect that landed was a
**liveness** bug instead: a mechanism that keeps running, keeps returning success, and stops
making progress.

## 1. A batch under a limit, ordered oldest-first, pins itself forever

The sweep selected rows whose deadline had passed, ordered ascending, limited to a batch size.
That is the obvious spelling and it is a trap. Once more than one batch's worth of rows have
*ever* accumulated, the query returns the same oldest rows on every tick, for ever. It never
reaches anything that expired this morning. And it reports `:ok` every time.

The fix is a **moving window rather than a floor**: filter `since < deadline <= now`, order
descending, and accept on the record that a row older than the window is never revisited. The
index has to serve that window; an index led by a tenant column cannot, because the sweep is
scoped to no tenant.

## 2. Job uniqueness spanning terminal states suppresses the backstop too

Deduplication was configured over *all* job states, including terminal failure states. So a job
that exhausted its retries suppressed its own re-enqueue — and suppressed the backstop sweeper's
identical insert as well.

The two composed into the worst case available: **the primary mechanism dies, and the backstop
cannot reach it.** Neither is visible from any success metric.

The fix excludes only the terminal failure states. Note that the library's tempting shorthand
for "incomplete" was *also* wrong in the other direction — under it, a completed job stops
suppressing and every event inside the window is re-announced on every tick. There is now a test
for each direction, and three numbers (uniqueness scope, sweep lookback, pruner retention) are
documented as **one set rather than three independent settings**: the lookback must stay
comfortably shorter than the retention, because the completed record is what stops the
re-announcement, and pruning it early reproduces the bug.

## What to do differently

- When reviewing background work, ask: **"what does this look like six months in, after N rows
  have accumulated and one job has exhausted its retries?"** Correctness review answers a
  different question and will not surface this.
- Prefer a **moving window** to a fixed floor in any batched sweep, and write down what falls
  outside it.
- **Deduplication that spans terminal states is a permanent suppression.** Enumerate which states
  your uniqueness scope covers and test both directions — a job that should be replaced, and an
  event that should not be re-announced.
- Treat retention, lookback and deduplication windows as **a coupled set**, and say so where they
  are configured. Each is correct only relative to the others.
- Liveness failures produce no error and no alert. If a mechanism has a backstop, test that the
  backstop still fires when the primary has failed *permanently*, not just when it has not run
  yet.
