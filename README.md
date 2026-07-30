# hospitality-coms

A proof of concept for **worker-owned identity** in hospitality communications. The person owns
the identity record; an employer holds a fixed-term, revocable *engagement* against it rather
than owning an account.

Hospitality turns over 70–100% of its staff a year and coordinates on WhatsApp groups a manager
assembles by hand. Every purpose-built alternative reproduces the flaw underneath: the account is
provisioned by the employer, so it must be deprovisioned by the employer — a permanent
administrative tax and a permanent data-liability surface. This inverts it. Ending an engagement
removes one venue's rooms and nothing else; the person record, the profile, the peer connections
and every other venue are untouched. Ending *every* engagement leaves a fully functional account,
which is the state no employer-provisioned one can occupy.

Two consequences run through the whole tree:

- **Two zones, one bridge.** `engagements` is the only table outside the person zone that names a
  human, and `employer_role` — the Postgres role every employer read runs as — holds no
  privilege on any person-zone table. The guarantee is a grant, so a forgotten filter surfaces as
  `permission denied for table peer_messages` rather than as a leak.
- **Membership is derived, never stored.** Room rolls, peer visibility and disclosure defaults are
  queries over periods. Nothing maintains a member list, and moving the clock changes every answer
  with nothing having run.

**This is an exercise in agentic POC building, not a commercial product.** It was built to see how
far a structural guarantee can be pushed and proved, not to be deployed. Read it as a
demonstration.

Architecture diagrams live in the design documents rather than here: the
[ownership boundary](docs/brainstorms/2026-07-26-worker-owned-identity-requirements.md#ownership-boundary),
the [zone partition and the single bridge](docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md#zone-partition-and-the-single-bridge),
and the [revocation ordering](docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md#revocation-ordering).
Both documents predate parts of the tree; `CLAUDE.md` is the authority on what is actually there.

## Where the documentation is

| Document | What it is |
| --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | The tree as it stands, subsystem by subsystem, with the reasoning. Read the relevant section before changing anything in it. |
| [`AGENTS.md`](AGENTS.md) | The standards — type specs, testing posture, migration rules, git workflow. |
| [`client/README.md`](client/README.md) | The React client: its stack, its surfaces, and what it deliberately does not cover yet. |
| [`docs/plans/`](docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md) | The implementation units and the Key Technical Decisions (KTD1–KTD21), which the rest of the tree cites by number. |
| [`docs/brainstorms/`](docs/brainstorms/2026-07-26-worker-owned-identity-requirements.md) | What the product is and why, with the numbered requirements. |
| [`docs/solutions/`](docs/solutions/) | Post-mortems worth reusing — mutation testing, Postgres role hazards, clock boundaries. |
| [`docs/test-designs/`](docs/test-designs/) | One brief per unit: what was to be proved, and what was measured. |

## Vocabulary

| Term | One line |
| --- | --- |
| **Person** | The root record. Created only by the person, through a magic link. No employer action creates one. |
| **Venue** | The employer. There is no `employers` table — an employer session is a person session scoped to a venue. |
| **Engagement** | A person's fixed-term post at a venue, half-open `[starts_at, ends_at)`. Activeness is derived, never stored. The single bridge between the zones. |
| **Grant** | Employer authority at one venue, held through an engagement. Revocable, except a venue's last live one. |
| **Invitation / claim** | An offer plus a code. The employer issues it; the person redeems it in their own session, and that is what creates the engagement. |
| **Venue room** | One per venue. Its roll is the venue's active engagements. Full history, readable by everyone currently engaged. |
| **Shift room** | A shift *is* the room. Readable by whoever's roster period overlaps it; closed to new messages after the shift type's grace period. |
| **Roster entry** | A period on a shift room. Removal closes the period; the row is never deleted. |
| **Suspension** | A person's own opt-out from a venue room. Invisible to the employer, and it does not touch the engagement. |
| **Peer** | Somebody whose engagement overlapped yours at one venue. Visibility runs 30 days past the first term to end; a permanent connection takes a request and an acceptance, and outlives both engagements. |
| **Attested entry** | A profile line the employer authored — venue, role label, dates. The worker cannot edit it, only contest it with a correction request. |
| **Declared entry** | A profile line the worker authored, shown as self-declared. |
| **Disclosure** | Who may see an attested entry. Engagements concurrent with the viewing venue's own are hidden by default. |
| **Zones** | `person`, `employer`, `shared`. The shared zone has exactly one member and always will: `engagements`. |
| **Scope** | `PersonScope` or `EmployerScope` — who is asking, and the one instant the whole unit of work uses. |
| **Erasure** | Pseudonymises the person row rather than deleting it: identifiers are overwritten, other people's conversations survive. |
| **Retention** | Four stamped deadlines — own-message copies, shift messages, roster entries, venue-room history — swept on a schedule. |

## Running it locally

Prerequisites:

- Elixir and Erlang exactly as pinned in [`.tool-versions`](.tool-versions) — `elixir
  1.20.2-otp-28`, `erlang 28.5.0.3`. Note the asdf naming: a bare `1.20.2` never resolves and makes
  every `mix` invocation fail with "No version is set for command mix".
- **PostgreSQL 17 or newer**, at `localhost` with a `postgres`/`postgres` superuser (see
  [`config/dev.exs`](config/dev.exs)). 17 is a hard minimum: the boundary's privilege sweep asks
  `has_table_privilege` about `MAINTAIN`, which does not exist before it.
- Node ≥ 20.19 for the client.

```bash
mix setup                     # deps, create hospitality_coms_dev, migrate, seed
mix phx.server                # :4000

cd client && npm install
npm run dev                   # :5173
```

Then open <http://localhost:5173>. Phoenix is API-only — JSON and two websockets, no HTML layer, no
LiveView, no asset pipeline — so port 4000 serves the API and the dev mailbox and nothing you would
call a page.

### The footgun: the dev database and the test database cannot share a cluster

`mix setup` migrates `hospitality_coms_dev`. Postgres roles are cluster-global while grants are
**database-local**, so the grants that database now holds make `DROP ROLE employer_role` fail in
`hospitality_coms_test` — and no connection to the test database can revoke them. Four
`PostgresRolesTest` tests then fail, naming `hospitality_coms_dev` (issue #20). The suite detects
this and prints the remedy rather than raising out of the middle of a migrator, but it reads as
unrelated to whatever you were working on.

Pick one: give the dev database a throwaway cluster of its own (`initdb` on another port —
[`client/README.md`](client/README.md) has the recipe), or drop `hospitality_coms_dev` before
running `mix test`. The same applies to a second checkout, and to `mix test --partitions`, which is
prohibited for this reason. Background:
[`docs/solutions/database-issues/postgres-roles-are-cluster-global-grants-are-database-local.md`](docs/solutions/database-issues/postgres-roles-are-cluster-global-grants-are-database-local.md).

### Logging in

There is no password anywhere in the tree, so a magic link is the only door. `POST /api/log-in`
registers the address if it is new and mails a link; in development no mail leaves the machine and
**<http://localhost:4000/dev/mailbox> is the only place to read one**. The link points at the
client (`:magic_link_base_url` defaults to `http://localhost:5173/log-in/`), so it is clickable and
redeems on arrival. What comes back is a bearer token — the API's only credential, and the same row
a websocket re-checks on every join.

## Seeds

`mix ecto.setup` runs [`priv/repo/seeds.exs`](priv/repo/seeds.exs), which calls
`HospitalityComs.Demo.seed/0`. It writes two venues, four people, two shift types with different
grace periods, a past roster, a live shift, a closed shift, an accepted peer connection with
messages, a pending request, and a hidden concurrent profile entry.

Every instant is **relative to the clock at seed time**, so a database seeded at 15:40 has a shift
live at 15:40. Demo rows are marked so the test fixtures can find them again: venues end in
`" (demo)"` and addresses sit at `@demo.invalid` (`Demo.venue_pattern/0`, `Demo.person_pattern/0`).
The people are `mira@`, `ana@`, `tomo@` and `luka@demo.invalid`; the venues are "Harbour Tavern
(demo)" and "Kolektiv Coffee (demo)".

Seeding is **all-or-nothing over nine anchors** — the two venues, the four people, and three
curated profile rows. All present writes nothing and says so; none present seeds; anything in
between is `{:error, :partial_manifest}`, which is what an interrupted run leaves and which wants
`mix ecto.reset`. The module lives in `dev_support/`, and the seeds script refuses under `:test`
and `:prod`.

## The clock

`HospitalityComs.Clock` is the only source of the current instant. One instant is captured per unit
of work and carried on the scope; a project Credo check fails the build on `DateTime.utc_now/0`
anywhere outside the clock's own namespace. `HospitalityComs.Clock.Offset` is the offsettable
implementation and it compiles only in `:dev` and `:test` — `mix.exs` excludes `dev_support/` from
the production build, so the override is structurally absent rather than guarded (KTD5b).

The controls are under `/api/demo/*`, mounted only where `:demo_routes` is set. They authenticate
nobody, and every state-changing one requires the header `x-demo-control` — not a credential, but a
header a forged cross-origin `fetch` cannot carry without a preflight this application refuses.

```bash
curl localhost:4000/api/demo/clock
curl -X POST localhost:4000/api/demo/clock -H 'x-demo-control: 1' \
     -H 'content-type: application/json' -d '{"advance": {"day": 31}}'
curl -X POST localhost:4000/api/demo/run-due-work -H 'x-demo-control: 1'
curl -X DELETE localhost:4000/api/demo/clock -H 'x-demo-control: 1'
```

`POST /api/demo/seed` and `POST /api/demo/people/:person_id/end-engagements` are the other two.

**Advancing the clock does not make Oban run scheduled jobs.** Oban's staging query asks
`scheduled_at <= DateTime.utc_now()` inside its own engine, where the injected clock does not
reach, so an expiry scheduled for a term's upper bound still waits for real time — and skipping
that wait is the entire point of the clock. `run-due-work` therefore drives the workers directly,
and queues are `testing: :manual` in `:dev` so that cron cannot delete a month of retained messages
unattended after one clock advance. `HospitalityComs.Demo`'s moduledoc carries the rest.

## Tests

```bash
mix test                      # the server suite
mix quality                   # credo --strict + dialyzer
cd client && npm run verify   # typecheck, lint, format check, vitest, build
```

CI runs both halves on every pull request. `mix precommit` bundles compile-with-warnings-as-errors,
unused-deps, format and test.

**Mutation is the primary quality mechanism here, not coverage.** A test earns its place by going
red when the thing it names is broken, and a control assertion earns its place the same way —
twenty-one tests in this project read as coverage and could not fail for the reason they claimed.
[`docs/solutions/test-failures/tests-that-certify-nothing.md`](docs/solutions/test-failures/tests-that-certify-nothing.md)
is the catalogue of shapes, and it explains more about how this suite is written than anything else
would.

Half the test files are **not sandboxed** and commit for real, because a claim spans both repos'
connections and under the sandbox those are two transactions that cannot see each other's rows. An
aborted run therefore leaves rows behind; `HospitalityComs.TestDatabaseGuard` clears them before the
first test and prints what it cleaned. If a purge itself fails, drop, create and migrate
`hospitality_coms_test` — never the dev database. `CLAUDE.md` has the detail.
