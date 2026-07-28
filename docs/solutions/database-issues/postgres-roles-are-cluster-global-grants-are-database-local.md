---
title: "Postgres roles are cluster-global while grants are database-local"
summary: "One privilege granted in any database on the cluster makes DROP ROLE fail in every other, and no connection to the failing database can revoke it."
module: priv/repo/migrations
date: 2026-07-28
problem_type: database_issue
component: database
severity: high
source: "U1 (#14) forecast it, U3 (#19) documented it, U4 (#22) hit it, PR #33 met it again"
root_cause: config_error
resolution_type: migration
tags:
  - postgres
  - roles
  - grants
  - pg-shdepend
  - migrations
  - rollback
applies_when:
  - "creating database roles in a migration"
  - "a DROP ROLE fails with dependent objects still exist"
  - "running dev, test and CI databases on one Postgres cluster"
---

# Postgres roles are cluster-global; grants are database-local

`CREATE ROLE` acts on the whole cluster. `GRANT` writes a `pg_shdepend` row **in the database
where it was issued**. The consequence is asymmetric and catches people:

> One privilege granted to a role in *any* database on the cluster makes `DROP ROLE` fail in
> *every* other database on that cluster — and no connection to the failing database can revoke
> it, because the dependency does not live there.

So a developer who runs `mix ecto.migrate` (or the equivalent) against their **dev** database
breaks the role-rollback migration in their **test** database, with an error that names neither
the offending database nor the offending grant.

## What it looks like

`ERROR: role "x" cannot be dropped because some objects depend on it`, raised from the middle
of a migrator, in a database whose own grants are all clean. Diagnosing it from that message
alone is very hard.

## What to do differently

- **Diagnose to the database name, not to the Postgres error.** Query `pg_shdepend` across
  `pg_database` and have the rollback test *name the databases still holding grants* and tell
  the reader to roll those back or drop them. This turned an opaque migrator crash into a
  one-line instruction.
- **Roll every grant migration down before the roles migration**, in the real order the
  migrator uses, and make the list "every grant migration" with no judgement call in it —
  including a grant migration that currently grants nothing. A list with an exception in it is a
  list somebody gets wrong later.
- **Any test that drops a role must run inside a transaction that rolls back**, since the role
  is cluster-wide and a committed drop reaches every other database and every parallel job.
- **Never run test partitions that interpolate a partition id into the database name** against a
  shared cluster: each partition database runs the grant migrations, and their grants then break
  the rollback test in the primary one. A reviewer hit exactly this.
- **Give each concurrent checkout its own cluster** (a throwaway `initdb` on another port), not
  its own database on the shared one. See
  `../developer-experience/worktree-isolation-does-not-isolate-the-database.md`.

## Membership is the exception, and it fails in the opposite direction

`GRANT <role> TO <role>` writes **no** `pg_shdepend` row — role membership lives in the shared
`pg_auth_members` catalog. Measured. Two consequences, and they point opposite ways:

- **Good.** A login role granted membership of a restricted role costs nothing on the
  cross-database axis. It stays droppable from anywhere, which is why such a role should be
  granted membership and no object privilege at all.
- **Bad, and silent.** `DROP ROLE restricted_role` therefore does **not** fail while a login role
  is a member of it. It removes the membership without complaint, and re-creating the role does
  not restore it — the role that comes back is a fresh one with no members. So rolling a roles
  migration back underneath a live login role leaves a credential that can still authenticate and
  can no longer assume anything, and the application cannot open a connection until somebody
  re-runs the migration that granted the membership.

The mitigation is the same list already described above, extended: the migration that grants
membership is rolled back **before** the migration that creates the role it points at, and the
property is pinned as its own test — because unlike a `pg_shdepend` conflict, nothing about this
one is loud.

## Whether `down` should drop cluster-global roles at all

Asked and answered on this project, in the direction of keeping it. The reasoning is worth
copying because the deciding facts are environmental rather than architectural:

- **A fresh cluster per CI job removes the hazard from CI entirely.** One service container, one
  database, nothing to collide with — provided partitioned test runs that interpolate a partition
  id into the database name are prohibited, since each partition database runs the grant
  migrations.
- **What is left is one developer's two databases, which the detection above already names.**
- **Moving role creation to a provisioning step outside migrations trades a detected failure for
  an undetected one**, and it gets worse once a repo *logs in* as one of the roles: a missing
  provisioning step stops being "a grant is absent" and becomes "the application cannot boot".
- **The reversibility property is worth keeping** — migrating up then down leaving no role behind
  is one of the few things that proves the migration is honest about what it did.

## The related trap in the same family

`ALTER DEFAULT PRIVILEGES` must never be used where a role is meant to be denied by default. It
**survives `REVOKE ALL ON TABLE`** and is inherited by every table created afterwards — so it
silently hands the role tables that do not exist yet. Verified directly, and then swept: assert
`pg_default_acl` names no role at all, with a control that grants one and watches the check
catch it. Grant explicitly, per table, per privilege.
