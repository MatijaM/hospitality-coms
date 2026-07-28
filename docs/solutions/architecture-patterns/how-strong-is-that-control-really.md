---
title: "Count your security tiers by asking which of them the attacker's code position can switch off"
summary: "A guard that application code can disable is not a second tier; row-level security under a superuser is no tier at all; and absent-by-construction beats present-and-guarded."
module: lib/hospitality_coms
date: 2026-07-28
problem_type: architecture_pattern
component: database
severity: high
source: "PR #14 (U1), PR #19 (U3), PR #25 (U6), PR #34 (U9)"
root_cause: missing_permission
resolution_type: documentation_update
tags:
  - defense-in-depth
  - row-level-security
  - postgres
  - threat-model
  - build-time-exclusion
applies_when:
  - "claiming defence in depth in a design document"
  - "deploying Postgres row-level security"
  - "shipping a capability that must never be reachable in production"
---

# How strong is that control, really

Three findings from one codebase, all of the same shape: a control that reads as a tier in a
document and provides less than the document claims.

## 1. A guard the application can switch off is not a tier

A repository module assumed a restricted database role via `SET ROLE` on connect, and its
moduledoc positioned the database grants as tier one with an in-process query guard as
best-effort tier two. That was not true as built:

- the connection uses the application's own login credentials, so a single **`RESET ROLE`**
  from application code restores every privilege;
- raw `query/3` dispatches straight to the adapter without going through the wrapper, so the
  in-process guards never see it.

If tier one is defeatable from the same code position as tier two, **there is one tier.** The
response was to correct the documentation, pin all three escapes as *tests* so nobody
rediscovers them as news, and file the real fix (a dedicated login role) rather than claim
depth it did not have.

**Count tiers by asking which of them the attacker's code position can disable.** A boundary can
be strong against *accident* and weak against intent — that is a fine thing to build, as long as
you write down which one you have.

### The fix, and the detail that decides whether it is one

The dedicated login role landed later. Two things about it generalise.

**Make the login role `NOINHERIT`, not `INHERIT`.** Both close the escape and they do not close it
equally. With `INHERIT` the login role carries the restricted role's privileges without assuming
them, so `SET ROLE` is decoration, `RESET ROLE` is *neutral*, and a privilege granted directly to
the login role by some later migration widens the zone with nothing to notice — because the audit
sweep asks about the restricted role. With `NOINHERIT` the login role holds the right to *become*
the restricted role and no privilege in its own name, so `RESET ROLE` lands on strictly less than
it started with. Measured both ways.

That is also what makes the fix testable rather than merely asserted: "after `RESET ROLE`, an
*allowed* table is denied" has `NOINHERIT` as its mechanism and fails when somebody removes it,
where "after `RESET ROLE`, a forbidden table is still denied" passes under either spelling and
passes on a database where nothing was ever granted.

**Grant the login role nothing — not even `CONNECT`.** It needs `CONNECT` on the database and
`USAGE` on the schema, and `PUBLIC` already confers both. Granting either explicitly writes a
`pg_shdepend` row, which is database-local while the role is cluster-global, so it would make
`DROP ROLE` fail from every *other* database on the cluster (see
`../database-issues/postgres-roles-are-cluster-global-grants-are-database-local.md`). Role
*membership* writes no such row — measured — so the grant that makes the login role useful costs
nothing on that axis.

**And invert the test rather than deleting it.** The suite had a test asserting the escape
worked, because the project had decided to record the defect rather than hide it. Once fixed, a
test asserting it still works would assert the bug back into existence. Inverting it in place —
same `describe`, opposite claim, with the controls the original did not need — leaves the history
legible to anyone reading `git log -p` on that file.

## 2. Row-level security under a superuser is theatre

A migration described its RLS policies as belt-and-braces behind hand-written query filters. For
one table the reality was inverted: the restricted role held no privilege on it at all, the
policy was not `FORCE`d, and the only role reaching the table owned it — and owners bypass
non-forced policies.

Then the sharper fact, verified rather than assumed: the application connects as a **superuser**
(`rolsuper = true`), and **a superuser bypasses row-level security whether or not the policy is
forced**. A per-row RLS rule would have read as a database tier in a migration and provided
nothing. What actually held tenancy was composite `MATCH FULL` foreign keys.

The suite now **asserts `rolsuper`** rather than assuming it, because if that ever stops being
true, the reasoning changes.

**If you deploy RLS, verify against the actual connecting role** — is it the owner? a superuser?
does it have `BYPASSRLS`? — and write down what holds when the policy does not.

## 3. Absent-by-construction beats present-and-guarded

The offsettable test clock, and later the demo controls that can end every engagement at a
venue, are things that must never exist in production. They live in a directory excluded from
the compile path in the production environment, so they are **structurally absent from the
production build** rather than compiled and gated by a config flag.

The claim is verified by inspecting the artifact — compile in production mode and list the
emitted modules — and asserted four independent ways, because no single check is sufficient: the
build function itself (made public so the test reads the function the build system calls), each
module's compiled source path, no production module importing a dev-support one, and a CI step
that compiles in production mode with warnings as errors, **because reading the compiled import
table cannot see a struct expansion or a typespec**.

For any capability that is catastrophic if reachable in production — test backdoors, seed and
demo controls, offset clocks, impersonation — **prefer a build-level exclusion you can verify by
inspecting the artifact over a runtime conditional you have to trust.**
