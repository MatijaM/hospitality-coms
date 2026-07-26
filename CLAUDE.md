# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is the authoritative standards document — type specs, testing posture, migration rules, git workflow. This file covers only what is specific to the current state of the tree.

## Status

Phoenix 1.8.9 application, scaffolded with `--binary-id --database postgres`. The HTML layer is still present because `mix phx.gen.auth` refuses to run on a `--no-html` app; it is removed in a later unit, not here.

The plan being executed is `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`. Read the unit you are working on plus its Key Technical Decisions before changing anything time- or boundary-related.

## Toolchain: read this before running `mix`

`.tool-versions` pins **the target** toolchain (`elixir 1.20.2`, `erlang 29.0.3`), not the one installed. Under asdf this makes every `mix` invocation in this directory fail with "No version is set for command mix".

Until the target toolchain is installed, prefix commands with the installed versions:

```bash
ASDF_ELIXIR_VERSION=1.19 ASDF_ERLANG_VERSION=28.5 mix test
```

The application compiles and its tests pass on 1.19.5 / OTP 28. The pin records the intended upgrade so that taking it is a deliberate step.

## Commands

Run these with the prefix above.

```bash
mix setup                         # deps, database, assets
mix ecto.setup                    # create, migrate, seed
mix phx.server                    # dev server on 4000
mix test test/path/file_test.exs  # PR-scoped test run (preferred locally)
mix quality                       # credo --strict + dialyzer
mix compile --warnings-as-errors
```

## Layout worth knowing

- `lib/` — the application. Compiled in every environment, including `:prod`.
- `dev_support/` — compiled only in `:dev` and `:test`. Holds `HospitalityComs.Clock.Offset` and the project's Credo checks. Excluding this path from the production build is what makes the offsettable clock structurally absent from production rather than present and guarded; do not move anything from here into `lib/`.
- `credo_checks` does not exist; project checks live under `dev_support/hospitality_coms/credo/`.

## Time

`HospitalityComs.Clock` is the only source of the current instant. `HospitalityComs.Credo.Check.ClockAuthority` enforces it:

- `DateTime.utc_now/*` is flagged anywhere outside the `HospitalityComs.Clock` namespace.
- `Clock.now/0` is flagged outside the modules listed in the check's `:boundary_modules` parameter in `.credo.exs`. That list is **empty** until the unit-of-work boundaries exist. When you build one — a plug, a channel event handler, a job — add it to the list there rather than working around the check.

Everywhere else, the instant arrives on the scope struct.

## Database

Two repos, one database.

- `HospitalityComs.Repo` — the application's own role. The only repo in `:ecto_repos`, so migrations run through it alone.
- `HospitalityComs.EmployerRepo` — assumes the Postgres role `employer_role` via `after_connect`. The zone grants that give the role its asymmetry, and the transaction wrapper that scopes it, are not built yet.

`employer_role` and `person_role` are created by `priv/repo/migrations/*_create_postgres_roles.exs`. Roles are cluster-global, not database-local; a test that drops one must run inside the sandbox transaction so it rolls back.
