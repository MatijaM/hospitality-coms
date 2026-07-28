# Test Design Brief — #17, a dedicated login role for `EmployerRepo`; and #20, decided with it

Issue: #17, deferred out of #3 during code review. Decided together with #20, which says so
explicitly: "If that lands, the role model is being revisited anyway, and these two should be
decided together."
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` through
`-u15-login-rate-limit-and-reapers.md`.
Approver: the orchestrating agent, in the human's place. Nobody read this before implementation
began; this line is the substitution `AGENTS.md` requires be recorded, and it is repeated in the
pull request body.

## What is being built

One Postgres role, one migration, one configuration change per environment, and an inversion of
the assertion that currently pins the escape as a known property.

`HospitalityComs.EmployerRepo` connects with the application's own credentials — `postgres`, a
superuser that owns every table and view in the database — and assumes `employer_role` afterwards
with `SET ROLE`. U1's roles migration grants `employer_role TO CURRENT_USER`, which is what makes
that permitted. The consequence is that **`RESET ROLE` puts the superuser back**, and raw
`EmployerRepo.query!/3` reaches Postgres without passing either BEAM guard, so the whole grant
tier is one statement deep from application code.

After this unit, `EmployerRepo` logs in as **`employer_login`**: a role with `LOGIN NOINHERIT`,
granted membership of `employer_role` and nothing else, holding no privilege of its own on any
relation in either zone. `RESET ROLE` then lands on `employer_login`, and the caller is left
holding *less* than it started with.

## The decision that matters most: `NOINHERIT`, not `INHERIT`

Both spellings close the escape. They do not close it equally, and the difference is the whole
argument for picking one.

Measured on PostgreSQL 17.10, in a scratch cluster, with a `people` table the role must not read
and a `venues` table it must:

| login role | after `SET ROLE employer_role` | after `RESET ROLE` |
| --- | --- | --- |
| `INHERIT` | `venues` ok, `people` denied | `venues` **ok**, `people` denied |
| `NOINHERIT` | `venues` ok, `people` denied | `venues` **denied**, `people` denied |

With `INHERIT` the login role *is* `employer_role` at all times, the `after_connect` `SET ROLE`
is decoration, and any privilege a later migration grants the login role directly widens the zone
with nothing in the sweep to notice — because the sweep asks about `employer_role`.

With `NOINHERIT` the login role is a pure credential holder. It carries the right to *become*
`employer_role` and no privilege at all in its own name, so `RESET ROLE` is not merely neutralised
but costs the caller the employer zone as well. That is the version worth asserting, because the
assertion "after `RESET ROLE`, `venues` is denied" fails under `INHERIT` — which makes the
inheritance setting itself a mechanism a test can be load-bearing against.

## The second decision: where the credential lives, and what a migration may mint

**A migration may create a role and grant it membership. It may not mint a secret.**

The password is read from the one place that cannot disagree with what the application connects
with — `HospitalityComs.EmployerRepo.config()`, which resolves whether the environment spells its
credentials as `username:`/`password:` or as a `url:` — and it is written **only when the role
does not already exist**. So:

- **dev, test, CI**: the role is absent, the migration creates it with the literal from
  `config/dev.exs` / `config/test.exs`, and one `mix ecto.setup` bootstraps a working database.
  The literal sits beside the `postgres`/`postgres` already in those files; it is not a secret and
  never was.
- **production**: the operator provisions `employer_login` with a real password out of band
  first. The migration finds it, skips the create, and issues only
  `GRANT employer_role TO employer_login`. **The secret never reaches a migration, and therefore
  never reaches the Postgres statement log.** If the operator does *not* pre-provision, the role
  is created with whatever `EMPLOYER_DATABASE_URL` supplied — still their own secret, but now
  logged under `log_statement = ddl`, which is why pre-provisioning is the documented path.

The attributes that are *not* a secret — `LOGIN`, `NOINHERIT` — are re-asserted with `ALTER ROLE`
on every `up`, so a pre-provisioned role that got them wrong is corrected rather than trusted.

`config/runtime.exs` gains `EMPLOYER_DATABASE_URL`, required in production with a raise, handled
exactly as `MAGIC_LINK_BASE_URL` and `WEBSOCKET_ORIGINS` are. It is a second URL rather than a
second password beside `DATABASE_URL` because **Ecto resolves `url:` over explicit `username:`**
— `Ecto.Repo.Supervisor.init_config/4` is `Keyword.merge(config, url_config)` — so a
`username: "employer_login"` written next to the shared `DATABASE_URL` would be silently
overwritten by that URL's own userinfo. Two variables that must agree about one secret is a
footgun; two URLs that each fully describe one connection is not.

## What must not move, and why the unit is dangerous

- **`HospitalityComs.Repo` keeps connecting as a superuser.** `boundary_test.exs` asserts
  `rolsuper` for `current_user`, and KTD3's entire argument depends on it: a superuser bypasses
  row-level security whether or not a policy is `FORCE`d, which is *why* the employer-visible
  surface is an owner-privileged view rather than a policy. Only `EmployerRepo`'s login identity
  changes.
- **The tables' owner does not change.** `employer_login` creates nothing and owns nothing. The
  views stay owned by the role that owns the base tables and stay non-`security_invoker`; with
  either of those reversed, KTD3 inverts.
- **`employer_login` is granted no object privilege, ever — including `CONNECT`.** A `GRANT` to it
  would write a `pg_shdepend` row and make `DROP ROLE employer_login` fail across the cluster, for
  a privilege `PUBLIC` already confers. Measured: `GRANT employer_role TO employer_login` writes
  **no** `pg_shdepend` row at all — role membership lives in `pg_auth_members` — so the new role
  adds nothing to the cross-database dependency surface that #20 is about.

## `person_role` is deliberately not given the same treatment

The issue asks. The answer is no, and it is not symmetry for its own sake being declined.

Nothing assumes `person_role`. `HospitalityComs.Repo` connects as `postgres` and there is no
`SET ROLE person_role` anywhere in the tree; the role exists as a name the classification can
point at and as the other half of U1's reversibility test. Giving it a login credential would
create a live, authenticating credential for a role no code path uses — strictly more attack
surface for exactly zero boundary. Pinned as a test (`person_role` cannot log in, `employer_login`
can) so the asymmetry is a recorded decision rather than an omission.

## #20 — decided here, and the decision is to keep the current behaviour

> The underlying question is whether a `down` migration should drop cluster-global roles at all.

**It should, and #20 closes as wontfix.** Four reasons, in order of weight:

1. **The condition the ticket itself said would force a change is closed and pinned.** Its own
   words: option 3 is "fine for a POC with one developer and two databases on one cluster; bad
   the moment CI runs parallel test databases." CI now exists, gets one fresh service container
   per job holding exactly one database, and `.github/workflows/ci.yml` carries an explicit
   prohibition on `--partitions` with this reason written out at length. The failure mode that
   was going to force the change does not arrive.
2. **The remaining exposure is one developer's two databases on one cluster, and it is detected,
   named and actionable.** `PostgresRolesTest.assert_no_foreign_dependencies/0` reports the
   offending database by name and says what to do about it. Both times this project was bitten,
   that detection is what turned it into a one-line fix.
3. **Option 1 trades a detected failure for an undetected one, and #17 makes that trade worse.**
   Moving role creation out of the migration sequence means the roles are created by nothing that
   `mix ecto.setup`, the `mix test` alias, or a production deploy is guaranteed to run. Today a
   missing provisioning step would mean "a grant is absent"; after #17 it means **the application
   cannot open a connection at all**, surfacing as a pool crash loop at boot rather than as a
   named assertion in a test. It also costs the property U1 deliberately tests for — that up-then-
   down leaves no role in `pg_roles` — which, in a project whose subject *is* the role model, is
   one of the few things proving the migration is honest about what it did.
4. **Option 2 was measured and rejected for #4 because it moves the landmine**, and #17 adds a
   third role to the model. A fourth whose only job is to absorb `pg_shdepend` rows makes the
   model harder to read for no net reduction in hazard.

**But wontfix is not "no code", and this is the part #20 exists to catch.** #17 creates one new
obligation on the rollback path, measured rather than reasoned:

> `DROP ROLE employer_role` **silently strips `employer_login`'s membership** — memberships are
> removed automatically, so the drop does not fail — and re-applying the roles migration's `up`
> does **not** restore it. The re-created role is a fresh role with no members.

So rolling `create_postgres_roles` down and forward again, with the login migration still applied,
leaves a login role that can no longer assume anything and an `EmployerRepo` that cannot start.
The answer is the mechanism #20's mitigation already uses: the login migration joins
`PostgresRolesTest`'s rollback list, in apply order, so the roles migration is never rolled back
underneath it — and the fragility itself is pinned as a test, so it is a documented property
rather than a discovery.

## A finding this unit surfaces and deliberately does not act on

U1's roles migration sets `statement_timeout = '5s'` and
`idle_in_transaction_session_timeout = '10s'` on `employer_role`, and its moduledoc says they are
"part of the time model, not housekeeping". **They have never taken effect.** Measured: role-level
GUCs from `pg_db_role_setting` are applied at login for the *session user*; `SET ROLE` does not
re-apply them. Logging in as `postgres` and assuming `employer_role` shows `statement_timeout = 0`;
logging in as a role that carries the setting shows the setting.

This unit does not move them to `employer_login`. Making them effective is a behaviour change the
issue did not ask for and carries real risk: a 10s idle-in-transaction cap on a sandbox connection
that holds a transaction open for the length of a test is a flake generator, and the concurrency
files park processes deliberately. The finding is recorded here and in `CLAUDE.md`; acting on it
is its own ticket with its own evidence.

The unit must therefore **not** make them effective by accident, which it would if `employer_login`
were given the settings, and that is an acceptance criterion below rather than a note.

## Acceptance criteria

1. `EmployerRepo`'s connections have `session_user = employer_login` and
   `current_user = employer_role`.
2. `HospitalityComs.Repo`'s `current_user` is still a superuser, and `rolsuper` is still asserted.
3. Every table and view in `public` is still owned by the role that owned it before.
4. `RESET ROLE` on an `EmployerRepo` connection leaves `people` unreadable.
5. `RESET ROLE` on an `EmployerRepo` connection *also* leaves `venues` unreadable — the
   `NOINHERIT` claim, and the one that fails under `INHERIT`.
6. After `RESET ROLE`, `current_user` is `employer_login` — so criteria 4 and 5 cannot pass
   because the `RESET ROLE` silently failed.
7. `SET ROLE` back to `employer_role` restores the employer zone, so the escape attempt is not a
   denial of service against the pool.
8. `employer_login` cannot `SET ROLE` or `SET SESSION AUTHORIZATION` to the owner, is not
   `rolsuper`, and is not `rolbypassrls`.
9. `employer_login`'s memberships are exactly `["employer_role"]`.
10. `employer_login` holds no privilege on any person-zone table, any employer-zone table, or any
    employer view.
11. `employer_login` has no `pg_shdepend` row in this database.
12. `employer_login` carries no role-level `statement_timeout` or
    `idle_in_transaction_session_timeout` — the finding above, pinned so it is not enabled by
    accident.
13. `person_role` cannot log in.
14. The login migration's `down` removes the role, and `PostgresRolesTest`'s full rollback leaves
    neither `employer_role`, `person_role`, nor `employer_login` in `pg_roles`.
15. Dropping `employer_role` out from under a live `employer_login` strips the membership without
    failing, and re-applying `up` does not restore it — the #20 fragility, pinned.
16. `EmployerRepo` is configured to connect as `employer_login` and `Repo` is not.

## The assertion being inverted, named

`boundary_test.exs`, `describe "the escapes neither guard closes"`:

```
test "RESET ROLE gives back every privilege the grants were withholding"
```

becomes

```
test "RESET ROLE lands on the login role, which holds less than employer_role rather than more"
```

**This is not a weakening, and the reason is that the old test was never a claim about the
boundary — it was a claim about a defect.** It existed because #3 chose to pin a known escape as a
test rather than leave it as prose somebody would rediscover as news; its moduledoc says so
("so they are a decision on the record rather than a discovery somebody makes later"). The escape
is now closed, so a test asserting it still works would be asserting a bug back into existence.

The inverted test is strictly stronger than its predecessor in assertion count and in what a
mutation can reach: the old one had one control (`SET ROLE` back, so the connection did not leave
an open door behind it) and the new one has three (`current_user` after the reset, the employer
zone lost as well as the person zone, and the zone restored afterwards). The `describe` block
keeps its name and its other two members: raw SQL still bypasses both guards, and that exemption
is still load-bearing.

## Test matrix

`test/hospitality_coms/boundary_test.exs` — new `describe "the login role"` unless noted.

| # | Scenario | Assertion | Fails without |
| --- | --- | --- | --- |
| 1 | `RESET ROLE` on an employer connection (inverted, in `"the escapes neither guard closes"`) | `people` denied before; `current_user == "employer_login"` after the reset; `people` still denied; `venues` denied too; `SET ROLE employer_role` restores `venues` | `config/*.exs` naming `employer_login` as `EmployerRepo`'s username (reverting to `postgres` re-opens `people`); `NOINHERIT` on the role (with `INHERIT`, `venues` stays readable) |
| 2 | `EmployerRepo`'s session identity | `session_user == "employer_login"`, `current_user == "employer_role"` | the config change; the `after_connect` `SET ROLE` |
| 3 | The login role cannot become the owner | `SET ROLE postgres` raises; `SET SESSION AUTHORIZATION postgres` raises; `rolsuper` false; `rolbypassrls` false | `employer_login` being the superuser (i.e. the config change) |
| 4 | Control for 3 | `SET ROLE employer_role` succeeds on the same connection | `GRANT employer_role TO employer_login` in the migration |
| 5 | Memberships | `memberships_of("employer_login") == ["employer_role"]` | the `GRANT` (empty list); a second membership added later (list grows) |
| 6 | Privileges of its own | `Zones.privileges(Repo, all_relations, "employer_login") == []` | nothing — **absence assertion, needs the control below** |
| 7 | **Control for 6** | `GRANT SELECT ON venues TO employer_login` inside the sandbox; sweep reports `{"venues", "SELECT"}` | the sweep accepting a role parameter at all; a sweep that hardcodes `employer_role` reports `[]` and 6 passes for the wrong reason |
| 8 | Cluster-wide dependency | `dependent_objects("employer_login") == []` | nothing — **absence assertion, needs the control below** |
| 9 | **Control for 8** | grant it something; the same query returns `["table venues"]` | `dependent_objects/1` taking a role parameter |
| 10 | Role-level settings | `role_settings("employer_login") == []` | moving U1's timeouts onto the login role, which is the accident this forbids |
| 11 | **Control for 10** | `role_settings("employer_role")` names both timeouts | nothing in this unit — it is the control that says the query can see a setting at all |
| 12 | `person_role` | `rolcanlogin` false for `person_role` | the decision above being reversed |
| 13 | **Control for 12** | `rolcanlogin` true for `employer_login` | the migration's `LOGIN` |
| 14 | Owner unchanged (extend existing) | every relation in `public` is owned by `Repo`'s `current_user` | `employer_login` ever creating anything |

`test/hospitality_coms/employer_repo_test.exs`

| # | Scenario | Assertion | Fails without |
| --- | --- | --- | --- |
| 15 | Configuration, not behaviour | `EmployerRepo.config()[:username] == "employer_login"`; `Repo.config()[:username] != "employer_login"` | the config change in `config/test.exs` |

`test/hospitality_coms/postgres_roles_test.exs`

| # | Scenario | Assertion | Fails without |
| --- | --- | --- | --- |
| 16 | Full rollback (extend existing) | after `rolled_back_grants/0` and the roles `down`, none of the three roles exists | the login migration's `down`; the login migration's presence in the rollback list |
| 17 | The #20 fragility | roll the *grant* migrations down but leave the login migration applied; roll the roles migration down; `employer_login` still exists and its memberships are `[]`; roll roles back up; memberships are still `[]` | nothing — this pins a property of Postgres, and it is the evidence for the #20 decision. It fails if `DROP ROLE` ever starts refusing on account of membership, which is exactly when the decision would need revisiting |
| 18 | Grants of its own (extend `"grants no table privileges of its own"`) | the login migration grants no table privilege either | a `GRANT ... ON <table> TO employer_login` ever being added |

## Controls, listed explicitly

Six assertions here can pass vacuously, and every one has a control beside it.

- **6 → 7.** "The login role holds no privilege" passes on a sweep that asks about the wrong role,
  and passes on a database where the migration never ran, because Postgres default-denies. The
  control grants the login role a privilege behind the sweep's back and requires it be reported.
  This is the same shape as `"are reported by the sweep when one is granted behind its back"`,
  which the file already calls its load-bearing control.
- **8 → 9.** `pg_shdepend` is empty for a role nobody ever granted anything, which is also what a
  broken query returns. The control makes a row exist.
- **10 → 11.** "No role-level settings" is the default state of every role in the cluster. The
  control asserts the same query finds both of U1's settings on `employer_role`, so an empty
  result cannot mean the query is looking in the wrong column.
- **3 → 4.** "Cannot become the owner" passes on a connection that cannot `SET ROLE` to anything,
  including a broken one. The control requires the *permitted* `SET ROLE` to succeed on the same
  connection in the same test.
- **12 → 13.** "`person_role` cannot log in" is true of most roles. The control requires
  `employer_login` to be able to, so the query is known to distinguish them.
- **1's own controls.** `current_user == "employer_login"` after the reset says the `RESET ROLE`
  executed rather than erroring into a green test; the `venues` denial says privilege was lost
  rather than never held; the restoring `SET ROLE` says the connection is not left poisoned for
  the next checkout.

## Edge cases

- **A pre-existing `employer_login` on the cluster.** Roles are cluster-global, so the migration
  must find one created by another database's run and not fail. Idempotent create; `ALTER` for
  the attributes; `GRANT` is a no-op when already held.
- **A `nil` password.** Production with a URL that carries no password, or a pre-provisioned role.
  The create must omit the `PASSWORD` clause entirely rather than interpolate an empty string.
- **A password containing a quote.** The literal is escaped by Postgres itself
  (`SELECT quote_literal($1)`) rather than by string surgery in Elixir.
- **`RESET ROLE` leaving a connection poisoned.** `after_connect` runs once per connection, not
  per checkout, so a connection that reset its role stays reset for its lifetime. Criterion 7
  requires the test to put it back; the same requirement the existing test already carries.
- **`employer_login` needing `CONNECT` and schema `USAGE`.** Both come from `PUBLIC`. Granting
  either explicitly would spend a cluster-wide dependency for nothing — measured, and the reason
  criterion 11 exists.

## Regression risks, by path

- `test/hospitality_coms/boundary_test.exs` — the whole proof suite runs against `EmployerRepo`.
  Every `permission denied` assertion in it now arrives via a different session user.
- `test/hospitality_coms/boundary_lifetime_test.exs` — takes real, non-sandboxed connections and
  writes a session-level custom GUC. Custom namespaced GUCs need no privilege; asserted by the
  file continuing to pass.
- `test/hospitality_coms/employer_repo_test.exs` — asserts `current_user == "employer_role"`.
  Must stay true; the `after_connect` is unchanged.
- `test/hospitality_coms/postgres_roles_test.exs` — the rollback list and the three-role
  reversibility property.
- `test/hospitality_coms/profiles_test.exs`, `peers_test.exs`, `person_zone_test.exs` — all issue
  raw `EmployerRepo.query!/3` expecting either a view read or a `permission denied`.
- `test/hospitality_coms/venues_concurrency_test.exs`, `engagements_concurrency_test.exs`,
  `rooms_concurrency_test.exs` — non-sandboxed, park real connections on real locks. A role-level
  `idle_in_transaction_session_timeout` would break these, which is criterion 12.
- `.github/workflows/ci.yml` — the postgres service authenticates over TCP with
  `scram-sha-256`, so the new role must have a password there. The local cluster is `trust`, which
  ignores one; the literal satisfies both.

## Implementation constraints

- Migrations only via `mix ecto.gen.migration`; every `up` reversed by a `down`.
- The new migration joins `PostgresRolesTest`'s rollback list **in apply order** — it is applied
  last, so it is unwound first.
- `ALTER DEFAULT PRIVILEGES` must never appear.
- `@spec` on every public function, with enumerated error atoms. `Zones.privileges/3` gains a
  parameter and keeps its spec exact.
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev and
  `MIX_ENV=prod`, `mix quality`, `mix test` three times.
- Never migrate `hospitality_coms_dev`.

## Quality scores, self-assessed

- **Coverage of the stated problem**: 5/5. The escape is asserted closed from both directions —
  the person zone stays shut and the employer zone is *lost* — plus the identity, the membership,
  the privilege set and the dependency surface of the new role.
- **Control discipline**: 5/5. Six vacuous-pass risks, six named controls, each of which fails
  when its assertion passes for the wrong reason.
- **Mutation reachability**: 4/5. Every row names a mechanism whose removal breaks it. The weakest
  is #17, which pins a property of Postgres rather than of this code — deliberately, because it is
  the evidence for the #20 decision and the decision should be revisited if it ever changes.
- **Risk to the existing suite**: 3/5. Changing the session user of one of two repos touches every
  file that uses it. Mitigated by the fact that `current_user` is unchanged, which is what almost
  all of those files actually depend on.

## Revisions made during implementation

_Appended in a later commit. Nothing yet._
