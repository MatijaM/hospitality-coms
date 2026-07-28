---
title: "Worktree isolation isolates the filesystem, not the database"
summary: "Two agents working in separate git worktrees on one Postgres cluster corrupt each other's committed rows; a second database is not the fix, a second cluster is."
module: test-suite
date: 2026-07-28
problem_type: developer_experience
component: development_workflow
severity: high
source: "PR #33"
root_cause: test_isolation
resolution_type: environment_setup
tags:
  - git-worktree
  - parallel-agents
  - postgres
  - test-isolation
  - ci
applies_when:
  - "running two agents or two checkouts of one repo concurrently"
  - "any test that commits for real rather than rolling back"
  - "deciding how to isolate parallel test runs"
---

# Worktree isolation isolates the filesystem, not the database

A git worktree gives each concurrent worker its own files, its own branch, and its own build
directory. It gives them **the same Postgres cluster and the same test database**. Everything
in the suite that commits for real is therefore shared:

- one worktree's `ecto.migrate` puts the other's schema ahead of its own migrations;
- one worktree's fixture teardown, which deletes every row matching a prefix, deletes the other
  run's rows mid-test;
- an aborted run in either leaves committed residue that fails the other with foreign-key
  violations *inside the cleanup*, which reads like a regression in whatever was last merged.

Measured here: leftover rows from one interrupted run produced ~150 errors across 19 modules,
and in the worst case 371 failures across 20 modules, twice in a row, from one stray row plus
two hand-typed ones. Two reviewers lost significant time before bisecting to a `DELETE`.

## A second *database* is not the fix

The obvious remedy — give each worker its own database on the same cluster — breaks something
else. Database roles are cluster-global while grants are database-local, so each extra database
running the grant migrations makes `DROP ROLE` fail in *both*. See
`../database-issues/postgres-roles-are-cluster-global-grants-are-database-local.md`.

**Give the second checkout its own cluster.** A throwaway `initdb` into a temp directory on
another port is enough and needs no daemon — what matters is a separate role namespace, and a
role that merely shares a name is a different role.

## Two habits that follow

- **Write a guard that runs before the first test and reports what it cleaned.** Survey the
  catalogue for non-empty tables, reuse the fixtures' own teardown ordering, and fall back to
  one `TRUNCATE ... CASCADE` over every table at once — one statement, so there is no
  foreign-key order to get wrong. Clean automatically *only when you can argue the correct prior
  state is empty*; here nothing seeds the database and the test task creates it, so any row is
  residue by construction. Wrap the reuse in a rescue, because the teardown raising is itself
  one of the failure modes, and raise if residue survives so it never reports a success it did
  not achieve.
- **Know your accidental cleaners.** Two unrelated non-sandboxed tests here happened to delete
  broad swathes of rows, which is why *some* residue appeared to self-heal and why the residue
  that actually sticks is the kind that makes teardown raise. Worth finding before anyone
  tightens them.
