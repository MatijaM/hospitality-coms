# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the authoritative standards document — type specs, testing posture, migration rules, git workflow. This file covers only what is specific to the current state of the tree.

## Status

Phoenix 1.8.9 application, scaffolded with `--binary-id --database postgres`, now a JSON API. The HTML layer existed only so `mix phx.gen.auth` would run — it refuses on a `--no-html` app — and U2 removed it: no browser pipeline, no LiveView, no templates, no asset pipeline, and none of the corresponding deps. `Phoenix.Component`, `~H`, and `.heex` are not available; do not reach for them.

The plan being executed is `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`. Read the unit you are working on plus its Key Technical Decisions before changing anything time- or boundary-related.

## Toolchain

`.tool-versions` pins `elixir 1.20.2-otp-28` / `erlang 28.5.0.3`. Both are installed, so `mix` works with no prefix.

Note the asdf naming: the Elixir install is `1.20.2-otp-28`, not `1.20.2` — a bare version never resolves and makes every `mix` invocation fail with "No version is set for command mix".

The plan asked for Elixir 1.20.2 on OTP 29. This is 1.20.2 on OTP 28, which Elixir 1.20 supports (27–29) and which delivers the point of the pin: off the 1.19 branch, which is security-patches-only. Moving to OTP 29 is a separate, deliberate step.

## Commands

```bash
mix setup                         # deps, database
mix ecto.setup                    # create, migrate, seed
mix phx.server                    # dev server on 4000
mix test test/path/file_test.exs  # PR-scoped test run (preferred locally)
mix quality                       # credo --strict + dialyzer
mix compile --warnings-as-errors
```

In dev, `/dev/mailbox` is the only way to read a magic link — nothing renders one.

## Layout worth knowing

- `lib/` — the application. Compiled in every environment, including `:prod`.
- `dev_support/` — compiled only in `:dev` and `:test`. Holds `HospitalityComs.Clock.Offset` and the project's Credo checks. Excluding this path from the production build is what makes the offsettable clock structurally absent from production rather than present and guarded; do not move anything from here into `lib/`.
- `credo_checks` does not exist; project checks live under `dev_support/hospitality_coms/credo/`.

## Time

`HospitalityComs.Clock` is the only source of the current instant. `HospitalityComs.Credo.Check.ClockAuthority` enforces it:

- `DateTime.utc_now/*` is flagged anywhere outside the `HospitalityComs.Clock` namespace.
- `Clock.now/0` is flagged outside the modules listed in the check's `:boundary_modules` parameter in `.credo.exs`. That list currently holds one entry, `HospitalityComsWeb.PersonAuth`, which is the HTTP boundary. When you build another — a channel event handler, a job — add it there rather than working around the check.

Everywhere else, the instant arrives on the scope struct — `%HospitalityComs.Accounts.PersonScope{person: _, now: _}`, assigned as `:current_scope` by `PersonAuth.fetch_person_scope/2`, or `%HospitalityComs.Accounts.EmployerScope{employer_id: _, now: _}`. `EmployerRepo`'s transaction wrapper takes the instant off the scope for the same reason; a repo is not a unit of work, so it is not a boundary module.

`Ecto.Query.ago/2` and `from_now/2` are banned for the same reason `DateTime.utc_now/0` is: they expand to `DateTime.utc_now()` inside the query macro, where the offsettable clock cannot move them. `ClockAuthority` flags the call itself, both imported and fully qualified, because by expansion time it is too late to see. Compare against an instant taken from the scope.

`HospitalityComs.Accounts.Person` stamps `inserted_at`/`updated_at` explicitly too — Ecto's `timestamps()` autogenerate reads the wall clock from inside Ecto, which is also out of the check's reach.

## Database

Two repos, one database.

- `HospitalityComs.Repo` — the application's own role. The only repo in `:ecto_repos`, so migrations run through it alone.
- `HospitalityComs.EmployerRepo` — assumes the Postgres role `employer_role` via `after_connect`. Every read goes through `EmployerRepo.scoped_transaction/2`, which writes `app.employer_id` and `app.now` transaction-locally; an operation outside it raises `EmployerRepo.UnscopedError`, and a query reaching a person-zone table raises `EmployerRepo.ZoneViolationError` before Postgres is asked.

`employer_role` and `person_role` are created by `priv/repo/migrations/*_create_postgres_roles.exs`. Roles are cluster-global, not database-local; a test that drops one must run inside the sandbox transaction so it rolls back.

Grants are database-local while roles are not, so one privilege granted to `employer_role` in *any* database on the cluster makes `DROP ROLE employer_role` fail in every other — including the rollback `PostgresRolesTest` asserts on. `*_grant_zones.exs` deliberately creates no such dependency. The first migration that grants the employer zone real table privileges has to reckon with that test rather than discover it.

## Zones

`HospitalityComs.Zones` classifies every Ecto schema as person zone, employer zone, or shared, and `ZonesTest` fails on any schema in none of them. Adding a table is not finished until it is classified. Table names derive from `__schema__(:source)`; do not write a second list.

The boundary's proof suite is `test/hospitality_coms/boundary_test.exs`, with `boundary_lifetime_test.exs` holding the parts that cannot be asserted inside the sandbox — there, `EmployerRepo`'s transaction is a savepoint inside the test's own, so a `SET LOCAL` survives its commit and the production lifetime is not reproduced. Measured: with the wrapper writing session-level settings instead, the sandboxed file still passes everything and the non-sandboxed one fails.

`employer_role`'s lack of privilege on `people` is Postgres default-denying as much as it is the `REVOKE`. Every assertion in that suite that could pass for that reason carries a control that fails when it does; keep that property when extending it.

## Authentication

Magic link in, bearer token out. `POST /api/log-in` registers the address if it is new and mails a link; `POST /api/log-in/token` redeems it and returns the API token; `GET /api/me` and `DELETE /api/log-out` require it. There is no password anywhere in the tree and no cookie session — the generator's password column, changeset, and `bcrypt_elixir` were removed, because with no HTML layer nothing could ever set one.

The API token *is* the generated session token: a row in `people_tokens`, base64url on the wire and SHA-256 in the column. Every context stores a digest, session included — the column is the bearer credential for this API, so a `SELECT` leak must not yield a working one. Deleting the row ends the session on the next request, which is the point: U7's revocation depends on it, and a signed stateless token could not deliver it.

Every error the API returns is one envelope, built only by `HospitalityComsWeb.ErrorEnvelope`: `{"error": {"code": <status atom>, "message": ..., "fields": {...}}}`, with `fields` present only for per-field validation failures. Controllers, `PersonAuth`, and `ErrorJSON` all go through it; do not hand-roll a body.

Production requires `MAGIC_LINK_BASE_URL` — `config/runtime.exs` raises without it, because the `localhost:4000` default in `config/config.exs` fails silently by mailing links to the wrong host.

`people` is already shaped for U10 erasure: `email` is nullable, its unique index is partial on `WHERE erased_at IS NULL`, and two check constraints hold `erased_at` and `email` in opposition. Erasure nulls the address; nothing else may.
