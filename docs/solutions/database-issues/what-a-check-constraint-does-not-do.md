---
title: "A CHECK constraint is satisfied by NULL, and runs before ON CONFLICT arbitration"
summary: "Two ways a CHECK fails to hold the invariant you wrote it for: NULL makes the predicate NULL, and ON CONFLICT DO NOTHING does not rescue a candidate row that violates one."
module: priv/repo/migrations
date: 2026-07-28
problem_type: database_issue
component: database
severity: high
source: "PR #29 (U8) for the NULL half, PR #38 (U11) for the ON CONFLICT half"
root_cause: missing_validation
resolution_type: migration
tags:
  - postgres
  - check-constraints
  - null
  - upsert
  - on-conflict
  - three-valued-logic
applies_when:
  - "writing a CHECK constraint over a nullable column"
  - "using ON CONFLICT DO NOTHING as an idempotency guard"
  - "an invariant is enforced by a constraint you have not tried to violate"
---

# What a CHECK constraint does not do

## It is satisfied by NULL

A `CHECK` passes when its predicate evaluates to **true or NULL**, and it only fails on false.
So over a nullable column:

```sql
CHECK (declined_at IS NULL OR blocked_initiator_id = requester_id)
```

is satisfied by a declined row carrying **no block at all** — because `NULL = requester_id` is
NULL, not false. That is precisely the one row the constraint exists to refuse. The invariant
was in fact being held by the application code that wrote both columns in one statement; the
constraint below it was decoration.

The fix is `IS NOT DISTINCT FROM`, which is a genuine two-valued equality:

```sql
CHECK (declined_at IS NULL OR blocked_initiator_id IS NOT DISTINCT FROM requester_id)
```

A sibling constraint in the same migration was NULL-proof from the start, via paired `IS NULL`
comparisons — so the two spellings sat side by side and only one of them worked.

The same three-valued trap bites catalogue queries: `has_table_privilege(role, NULL, ...)`
returns **NULL, not false**, so a nil table name made an entire table silently skip a privilege
audit. Raise on the nil rather than handing Postgres a NULL.

## It runs before `ON CONFLICT` arbitration

`ON CONFLICT DO NOTHING` protects you from *uniqueness* violations and nothing else. Postgres
still builds the candidate row and still evaluates its `CHECK` constraints **before** it looks
for a conflicting row.

Here, an operation rewrote a period's end so that it preceded a message already sent. The
insert was written as an idempotent upsert, so the author expected the already-present row to
make it a no-op. Instead the candidate row failed a CHECK comparing the two instants, the whole
transaction aborted, and — because the sweep's lower bound was unbounded — it re-reached the
same poisoned row on every subsequent run. Only a database reset cleared it.

**If your upsert's candidate row can be invalid, the guard has to be in the query that
produces it.** `ON CONFLICT` will not save you.

## The rule underneath both

**Try to violate the constraint before you trust it.** Both of these were written by people who
believed they had a database-level invariant, and in both cases the invariant was actually held
somewhere else — or not at all. One `INSERT` of the row the constraint exists to refuse settles
it in a few seconds.

A related shape worth knowing: a `CHECK` on a range column can be unreachable because the range
type raises `SQLSTATE 22000` on construction first, so the constraint you declared can never
fire. Test the refusal, not the declaration.
