---
title: "An injected clock reaches only the code you compile"
summary: "Your ORM's time macros and your job queue's staging query read the real wall clock from inside the library, where no test clock can move them."
module: lib/hospitality_coms/clock
date: 2026-07-28
problem_type: architecture_pattern
component: background_job
severity: high
source: "PR #16 (U2) for the query macros, PR #23 (U5) and PR #38 (U11) for the queue"
root_cause: wrong_api
resolution_type: config_change
tags:
  - clock-injection
  - time-travel-testing
  - oban
  - ecto
  - job-queue
applies_when:
  - "introducing an injectable clock or time-travel testing"
  - "writing a demo or test control that advances time"
  - "a scheduled job does not fire when the clock is moved"
---

# An injected clock stops at your compilation boundary

Making one module the single source of "now" is a good discipline, and it is enforceable — a
lint rule can flag every other call to the system clock in your own source. What the rule
cannot reach is every library that reads the wall clock **inside its own code**. Two of them
mattered here, and both were found the hard way.

## Your query DSL's time helpers

Ecto's `ago/2` and `from_now/2` expand to `DateTime.utc_now()` *inside the query macro*, where
the lint rule cannot see them and the test clock cannot move them. They are now banned outright,
and the static check flags **the call site** — imported and fully qualified — because by
expansion time it is too late to see. Compare against an instant taken from the caller instead.

## Your job queue's staging query

Oban's engine asks `scheduled_at <= DateTime.utc_now()` in its own code. So advancing the
injected clock changes **every membership query in the application instantly**, while a
scheduled job still waits for real time to arrive — and skipping that wait is the entire point
of having an injectable clock.

Two consequences, both real here:

- **Tests must invoke workers directly** (`Oban.Testing.perform_job/2`) rather than advancing the
  clock and waiting for a queue that will not tick.
- **A demo control must drive the sweep and the worker directly too.** Trying to make the queue
  clock-aware is the wrong fix; the boundary is real and the honest move is to name it.

## The worst version: an environment where only half the system time-travels

The queue was set to manual in the test environment and **left running in dev**. So the cron
plugin staged jobs at *real* wall-clock time while the workers they ran read the *injected*
clock. One request advancing the clock by thirty days deleted a month of retained data within
the hour, unattended, in the one environment the time controls exist for.

The test that was meant to prevent this asserted "a clock advance alone deletes nothing" — and
was true only because the test config set the flag. **A test asserting a property that depends
on configuration has to read the configuration of every environment it claims to cover.** The
fix reads both config files through the config reader, with the merged cron plugin as the
control.

## What to do differently

- When you inject a clock, **enumerate the boundaries it does not cross**: your ORM's time
  helpers, your queue's staging query, database `now()` and `CURRENT_TIMESTAMP`, any library
  scheduler, any TTL implemented by an external store. Write the list down where the next person
  will look for it.
- Drive time-dependent background work by **direct invocation** in tests and demo controls.
- Watch for serialisation at the same boundary: a job struct built in-process carries
  atom-keyed args while the queue round-trips them through JSON, so a worker matching string
  keys refuses the in-process one. Do the JSON round trip the queue does.
