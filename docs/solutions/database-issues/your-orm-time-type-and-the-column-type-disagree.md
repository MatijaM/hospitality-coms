---
title: "timestamp compared to timestamptz converts via the session TimeZone, and timestamp(0) rounds where the ORM truncates"
summary: "Two silent time-type mismatches that a UTC server and whole-second fixtures will hide from you forever."
module: priv/repo/migrations
date: 2026-07-28
problem_type: database_issue
component: database
severity: high
source: "PR #34 (U9) for the time-zone half, PR #25 (U6) for the precision half"
root_cause: wrong_api
resolution_type: code_fix
tags:
  - postgres
  - timestamptz
  - ecto
  - timezone
  - precision
  - truncation
applies_when:
  - "comparing a stored timestamp against a database function returning timestamptz"
  - "choosing a timestamp precision for a column that bounds a period"
  - "all your test fixtures use whole-second instants"
---

# Your ORM's time type and the column type disagree

## `timestamp` against `timestamptz` converts using the session's TimeZone

Ecto's `:utc_datetime` maps to `timestamp` **without** time zone. A database function such as
`now()` or a custom `app_current_instant()` returns `timestamptz`. Comparing the two makes
Postgres convert one of them **using the session's `TimeZone` setting**, which most
applications never set.

Measured here: the same comparison, over the same rows, answered `false` unconverted and `true`
converted under `America/New_York`. The server's default is `Etc/UTC`, and CI's is too — so
**nothing would ever have caught it**. It surfaced only because someone went looking.

The fix is to write the conversion explicitly at every comparison:

```sql
... WHERE stored_instant <= (app_current_instant() AT TIME ZONE 'UTC')
```

and the regression test pins one read under `SET LOCAL TimeZone = 'America/New_York'`.

**Know which of your time columns are `timestamptz` and which are `timestamp`.** A mixed
comparison is silent, correct on your machine, and wrong for a user in another zone. Write the
regression test under a non-UTC session, or a UTC server and a UTC runner will agree with the
bug forever.

## `timestamp(0)` rounds; the ORM truncates

Postgres `timestamp(0)` **rounds** to the nearest second. Ecto's `:utc_datetime` **truncates**.
So the column and the cast disagree by up to half a second in opposite directions, and the
consequences are asymmetric for a period's two bounds:

- flooring an **upper** bound closes a period *before* the event happened, shortening an
  overlap that has already elapsed;
- flooring a **lower** bound backdates the event;
- and dropping the truncation without changing the column would have moved a removal at
  `12:00:01.8` to `12:00:02` — **into the future of the call that made it.**

Where sub-second precision is load-bearing, the **column type and the changeset cast have to
move together** (`timestamp(6)` with `:utc_datetime_usec`). Where it is not, whole seconds are
fine — but say which, and why, in the migration.

## Why neither was visible

Every instant in the original tests was a whole second, so truncation was the identity
everywhere and four changesets' sub-second stamping was never exercised. Every server was UTC,
so the conversion was the identity too.

**Put at least one non-round value and one non-UTC session in your fixtures.** Rounding and
conversion logic that is never handed a value it could change is logic nothing tests.
