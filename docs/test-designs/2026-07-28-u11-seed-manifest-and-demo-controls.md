# Test Design Brief — U11, Seed manifest and demo controls

Issue: #11. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U11.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code; the orchestrator stands in for the human approver (issue #21 tracks the missing
skill). Convention established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md`
through `-u10-erasure-and-retention.md`, including the "record revisions rather than applying them
silently" section at the end.

This is the last unit of the twelve. Everything it needs already exists; nothing it adds is a new
table, a new migration, a new grant, or a new zone. What it adds is the ability to *watch* the
other eleven work, which the plan's own Problem Frame says is the whole difficulty — "the load-bearing
work is a two-zone authorization boundary … the deliverable is a demo that reaches a person holding
zero engagements whose account still works."

## What is being built

**A seed manifest** that reaches every state the origin's success criteria require, and **controls**
that traverse every duration between those states.

Three things about the controls are decided here rather than discovered later, because each of them
is a trap the tree has already documented.

## Decision 1 — the demo modules live in `dev_support/`, and that is what makes the override absent

The issue's file list says `lib/hospitality_coms/demo.ex` and
`lib/hospitality_coms_web/controllers/demo_controller.ex`. **`lib/` compiles in `:prod`.** A module
in `lib/` that names `HospitalityComs.Clock.Offset` does not survive `MIX_ENV=prod mix compile`,
because `mix.exs` excludes `dev_support/` from the production compile path and that exclusion is
KTD5b's whole mechanism: "a demo control that can advance thirty days is also a control that can
trigger irreversible retention deletion; making the override structurally absent from the production
build is cheaper and stronger than guarding it."

U10 shipped the deletion. So the tension is not theoretical any more.

**Resolution: `HospitalityComs.Demo` and `HospitalityComsWeb.DemoController` are compiled from
`dev_support/`, alongside `HospitalityComs.Clock.Offset` and for the same reason.** The issue's path
is overridden, deliberately, and the override is recorded at the end of this brief.

CLAUDE.md forbids moving anything *out* of `dev_support/` into `lib/`. It says nothing about adding
to it, and adding to it is the only placement under which the demo controls inherit the absence the
clock override already has. Every alternative was worse:

- **`lib/` plus a runtime flag** (`if Application.get_env(:hospitality_coms, :demo?)`) — the exact
  shape KTD5b rejects. A flag can be flipped; a module that was never compiled cannot.
- **`lib/` plus dynamic dispatch to the override** (`apply(Module.concat([...]), :advance, [d])`) —
  the module is absent in prod so the call fails, but the *control* is present, routable, and one
  config line away from ending engagements across every employer in a production database.
- **Splitting** — clock controls in `dev_support/`, the rest in `lib/` — leaves
  `end_all_engagements/1` and `run_due_work/0` in production. Those are the two controls that
  destroy and mutate; the clock is only how you reach them quickly.

The router is in `lib/` and must therefore not name the controller in a production build. It mounts
the demo scope behind `Application.compile_env(:hospitality_coms, :demo_routes)`, exactly as it
already mounts the Swoosh mailbox behind `:dev_routes`; the key is set in `config/dev.exs` and
`config/test.exs` and in no other config file, so the block is not executed when the router module
body runs under `:prod` and no route is registered.

**The assertion that this holds is about the build, not about a flag.** Three parts, in the test
matrix below:

1. `HospitalityComs.MixProject.elixirc_paths(:prod)` is `["lib"]` — read from the function Mix
   itself calls, made public for this (it is `defp` today). Not a copy of the rule; the rule.
2. Every module whose compiled source is under `dev_support/` is therefore absent from a production
   build — asserted over the directory, so a fourth demo module added later is covered without
   anybody remembering to add it.
3. **No module compiled from `lib/` references any module compiled from `dev_support/`.** Read out
   of the BEAM `imports` chunk, the manoeuvre `lifecycle_test.exs` uses for deletes and
   `peers_test.exs` for query builders. This is the property that makes `MIX_ENV=prod mix compile`
   succeed, it is total over `lib/`, and its control is that the same detector *does* find
   `Demo → Clock.Offset` when pointed at `dev_support/`.

And `.github/workflows/ci.yml` gains a `MIX_ENV=prod mix compile --warnings-as-errors` step, so the
real build runs on every PR rather than only on the machine that happened to try it. The structural
test is what fails *informatively*; the CI step is what fails *conclusively*. Neither substitutes
for the other: a green prod compile on a branch that never referenced the override proves nothing
about the next branch, and a structural check that nobody ever ran a compiler against is a promise.

## Decision 2 — `run_due_work/0` drives the workers directly and never enqueues

CLAUDE.md states it and the plan states it twice: **Oban's staging query asks
`scheduled_at <= DateTime.utc_now()` inside its own engine, and `HospitalityComs.Clock` does not
reach it.** Advancing `Clock.Offset` thirty days changes every membership query in the application
instantly while a scheduled expiry announcement still waits thirty real days. Skipping that wait is
the entire purpose of the injected clock, so a demo that advanced the clock and waited for the queue
would demonstrate nothing — and three success criteria (expiry announcement, own-copy archiving,
retention deletion) would have no reachable demonstration at all.

`Demo.run_due_work/0` therefore:

1. reads the clock once — it is a unit-of-work boundary, and gains a `.credo.exs`
   `:boundary_modules` entry for that, with a reason, exactly as the three workers and `ChannelAuth`
   did;
2. calls `Engagements.list_expired/3` and hands each result to
   `Workers.ExpireEngagement.perform/1` — the real worker, with no queue between;
3. calls `Workers.RetentionSweeper.perform/1` — likewise.

**It does not call `Workers.EngagementSweeper.perform/1`,** and that is the one place the demo
deliberately parts company with production. That worker's contribution is `Oban.insert/2`; inserting
a job the demo would then have to execute itself is a round trip through a table for no gain, and it
would leave `oban_jobs` rows behind in a database the demo re-seeds. What the demo reuses instead is
the sweeper's *window arithmetic*, through its already-public `lookback_from/1` and `batch_size/0`,
so the two cannot drift.

**One number differs from production and it is on the record.** `EngagementSweeper` looks back one
day (`lookback_from/1`), and CLAUDE.md records the assumption: "a term that closed more than a day
ago is never swept again, which costs nothing because correctness never depended on the
announcement." Under an injected clock that jumps thirty-one days in one control action, *every*
closed term falls outside a one-day window — so the demo's expiry pass would announce nothing, and
`Workers.ExpireEngagement` is what stamps `retained_message_copies.delete_after` (U10). The demo
therefore uses an unbounded lower edge and keeps the batch bound. That is a property of a clock that
jumps rather than a disagreement with the sweeper, and the matrix has a test pinning that a term
closed long ago is still announced by the control (row 14) with the production window as the
control (row 15).

## Decision 3 — the control holds no authority of its own, and borrows one venue's at a time

"Demo controls run under their own scope, not an employer scope, because ending engagements across
employers is something no employer session may do." (Plan, U11.)

`Demo.end_all_engagements/1` takes a **person id and nothing else**. It enumerates that person's
engagements through `HospitalityComs.Repo` — the application acting for itself, the shape
`Lifecycle` and the three workers already have, and precisely what `EmployerRepo` refuses because a
scoped transaction is one venue's and the RLS policy on `engagements` is `venue_id =
app_current_employer_id()`.

For each engagement it then resolves a live grant at *that* venue, builds an `EmployerScope` for it,
and calls `Engagements.end_engagement/2`. **That is reuse rather than a loophole**, and it is what
makes R22 true without restating it: `end_engagement/2` already refuses a venue's last active
grant-holding engagement under `FOR UPDATE` on the locked set, reusing `EmployerGrant.live_at/2` so
that "live" cannot come to mean two things. A demo control with its own copy of that rule would be a
second definition of the invariant KTD17 exists to hold — the defect class CLAUDE.md names three
times.

So the cross-venue half runs as the application; each per-venue write runs as that venue, which is
the only principal entitled to it. The control can do nothing an employer *at that venue* could not,
and the enumeration it does across venues is exactly what no employer session can reach.

Refusal is **all-or-nothing**: if any of the person's engagements is its venue's last grant-holding
one, nothing is ended. A control that ended four of five and reported a failure would leave the
demonstration in a state no single action can explain.

## Decision 4 — the seeds walk the clock, because every context stamps from the scope

`Rosters.add_to_roster/3` writes `joined_at` from `scope.now`. `Rooms.send_venue_room_message/3`
writes `sent_at` from `scope.now`. `Engagements.claim_invitation/2` writes `claimed_at` from
`scope.now`. **No context in this tree accepts a backdated stamp, deliberately** — KTD6b's
non-retroactivity is structural, "there is no write that can withdraw access".

A manifest that needs a *past* roster therefore cannot be written at one instant. `Demo.seed/0`
walks `Clock.Offset` forward through the manifest's own timeline, one step per instant, and restores
the caller's clock state at the end. That is not a workaround: it is the demonstration, performed
once, at seed time. The seeds are the first consumer of the injectable clock and the reason it is
injectable.

`Clock.Offset` gains `restore/1` — the inverse of the `state/0` it already exports — so the restore
puts back the caller's exact control state (fixed instant *and* accumulated advance) rather than
approximating it with `set/1`, which clears the advance.

Every instant in the manifest is **relative to `Clock.now/0` at seed time**, not absolute. Seeding a
development database at 15:40 produces a shift that is live at 15:40; seeding it in a test with the
clock pinned produces the same manifest deterministically. An absolute epoch would make the demo's
"live shift" live only on one day of one year.

## Decision 5 — idempotence is all-or-nothing, and a half-seeded database says so

The manifest resolves by natural key: four people by email, two venues by name. `seed/0` asks for
all six.

- none present → seed, `{:ok, %{status: :created}}`;
- all present → write nothing, `{:ok, %{status: :present}}` carrying the same manifest;
- some present → `{:error, :partial_manifest}`.

The third state is the honest one. A "find or create per step" seed silently completes a run that
died halfway, and the row it did not write is the one nobody notices is missing; a marker on the
first entity skips everything after a crash in the middle. Enumerating the anchors and refusing on a
partial answer is the only shape where a half-seeded database is a message rather than a mystery.

## What the manifest contains, and why each entry is there

Two employers, four people. The origin (R45) asks for "two employers and at least three people, one
of whom holds concurrent engagements at both". The plan says that is insufficient and names the rest:
"watching a peer conversation survive needs a pre-existing accepted connection, which needs a
co-rostered shift, a shift type, a roster, and messages, none of which it names."

All instants relative to `t0`, the clock's instant when `seed/0` runs.

| Entity | Detail | Why it is in the manifest |
|---|---|---|
| Venue A | "Harbour Tavern (demo)", `Europe/Zagreb` | employer one |
| Venue B | "Kolektiv Coffee (demo)", `Europe/London` | employer two, and a second IANA zone so KTD20 is not one venue's setting |
| Mira | manager at A, `t0-200d … t0+200d`, holds A's founding grant | R22's refusal has to have a subject |
| Ana | worker at A `t0-90d … t0+90d`; manager at B `t0-150d … t0+250d`, holds B's founding grant | a manager is a worker too — the one caller holding an employer scope and a person scope at once |
| Tomo | worker at A `t0-60d … t0+120d`; worker at B `t0-40d … t0+140d` | **concurrent engagements at both employers** (S1), and the subject of AE7 |
| Luka | worker at B `t0-70d … t0-10d`, closed | **a person holding zero engagements whose account works**, at t0, without any control having run |
| Shift type "Close" (A) | grace 240 min | **two shift types with differing graces** |
| Shift type "Day" (A) | grace 15 min | the other one — and the pair is what makes "the grace is copied, not referenced" observable |
| Past shift (A, Close) | `t0-20d`, 8h | **a past roster** — Tomo and Ana rostered, Ana's period closed before the shift ended |
| Closed shift (A, Day) | `t0-2d`, 8h, closed at `+15m` | **a closed shift** — readable, unwritable, at t0 |
| Live shift (A, Close) | `t0-1h … t0+7h`, closes `t0+11h` | **a live shift** — S5 advances past the grace boundary |
| Venue-room messages (A) | Mira, Tomo, Ana, at `t0-30d`, `t0-29d`, `t0-1d` | each writes a `retained_message_copies` row — the worker's own copy, which is the payoff |
| Shift-room messages | in the past and closed shifts | carry a stamped `delete_after`; S3's retention deletion |
| Connection | Tomo ↔ Ana, requested `t0-50d`, accepted `t0-49d` | **an accepted connection** (S2) |
| Peer messages | two, `t0-48d` and `t0-47d` | **with at least two messages** (S2) |
| Pending request | Luka → Tomo, `t0-5d` | **a pending request**; and S6 lapses it |
| Hidden concurrent entry | Tomo's venue-B attested entry, hidden from venue A **by the concurrency default** | **a hidden concurrent entry** — derived from the overlap, nothing stored |
| Disclosure row | Tomo hides the venue-B entry from Ana, `{:person, ana_id}, false` | the ledger, non-empty, so the *stored* half of R17 is reachable too |
| Declared entry | Tomo, a job predating the demo | R17's other half: person-authored, published by writing |
| Correction request | Tomo contests his venue-A role label | R16's remedy, so `correction_requests` is not empty in the demo |

**Every stamped retention deadline is in the future at t0.** The past shift closes at
`t0-20d+12h`, so its messages die at `t0+10d`; the closed shift's die at `t0+28d`. That is not
arithmetic for its own sake: if any deadline had already passed, an operator's first
`run_due_work/0` would delete rows before the clock had been advanced at all, and S3's control —
"the advance alone does not" — would be measuring nothing.

## Acceptance criteria

1. **The manifest reaches every state the success criteria require**, from a freshly created
   database, with no row edited by hand.
2. **Seeding twice writes nothing the second time**, and a partially seeded database is refused
   rather than completed.
3. **The clock override, and now the demo controls with it, are absent from a production build** —
   a fact about `mix.exs` and about which modules reference which, not a runtime flag.
4. **`run_due_work/0` invokes the expiry worker and the retention sweeper directly**, and produces
   the retention deletion an advance alone does not.
5. **The controls are unreachable from an employer-scoped session**, and the set they operate on is
   invisible to one.
6. **`end_all_engagements/1` refuses a venue's last grant-holding engagement** (R22, KTD17), by
   reusing `Engagements.end_engagement/2`'s rule rather than restating it, and refuses the whole
   operation rather than half of it.
7. **After it succeeds, the person's profile and conversations still work** (AE7) — which is the
   demonstration the POC exists to produce.
8. **`@spec` on every public function**, enumerated error atoms, `Ecto.UUID.t()` for ids.
9. **KTD5 — one instant per unit of work.** `HospitalityComs.Demo` is a new boundary and gains a
   `.credo.exs` entry with a reason. Nothing else gains a `Clock.now/0` call, and
   `HospitalityComsWeb.DemoController` takes its instants from `Demo`.
10. **Every API refusal is an `ErrorEnvelope`.**
11. **No new table, no new migration, no new grant.** `Zones`, `PostgresRolesTest` and
    `boundary_test.exs` are untouched, and that is asserted by them continuing to pass rather than
    claimed here.

## The test-database guard, and whether these seeds break its argument

`HospitalityComs.TestDatabaseGuard`'s moduledoc justifies cleaning automatically rather than
refusing: "The correct contents of this database before the first test are *empty*:
`priv/repo/seeds.exs` writes nothing, `mix test` creates and migrates it, and no fixture in the tree
is meant to outlive its own test."

**Checked rather than assumed.** `mix.exs` aliases `test:` to `["ecto.create --quiet",
"ecto.migrate --quiet", "test"]` — no `run priv/repo/seeds.exs`. Only `ecto.setup` and `ecto.reset`
seed, and both are dev commands. So `mix test` and the seeds are already disjoint and the guard's
first clause survives on the path that matters.

The path that does not survive is a person typing `MIX_ENV=test mix ecto.setup`, which the recovery
instructions in `EngagementsFixtures.purge/0` come one word away from. Two changes close it:

- **`priv/repo/seeds.exs` refuses to run under `:test`**, saying why, so the guard's premise is
  enforced rather than documented. It also refuses under `:prod` — where `HospitalityComs.Demo` does
  not exist — with a message rather than an `UndefinedFunctionError`.
- **`EngagementsFixtures.purge/0` reaches demo rows.** `demo_test.exs` is not sandboxed and commits
  for real, so a run that dies mid-test leaves the manifest behind. Without this the guard's
  `TRUNCATE` still clears it, but reports it in the *loud* third category — "written by nothing in
  this tree" — which is a false alarm about the one thing the guard exists to make legible. The
  demo's two patterns (`"% (demo)"` on `venues.name`, `"%@demo.invalid"` on `people.email`) are
  exported by `HospitalityComs.Demo` and consumed by the fixtures, so there is one spelling of each.

Both are pinned by tests (rows 30 and 31).

## Edge cases

- Seeding into a database that already holds the manifest writes nothing and returns the same ids.
- Seeding into a database holding *some* of it is `{:error, :partial_manifest}`.
- `run_due_work/0` with nothing due writes a `retention_runs` row of zeroes and announces nothing —
  a recorded zero and no record at all are different facts (U10's rule, inherited).
- `run_due_work/0` twice in a row deletes nothing the second time and re-announces nothing new,
  because `retain_own_messages/2` is idempotent and the rows are gone.
- `end_all_engagements/1` for a person with no engagements succeeds and ends nothing.
- `end_all_engagements/1` for an id naming nobody is `{:error, :not_found}`, so the refusal
  enumerates nothing.
- An engagement whose term has already closed is not re-ended and its `ends_at` does not move.
- Advancing the clock by a negative duration is permitted — `Duration` allows it and the demo needs
  to go back — and the control returns the resulting instant so an operator can see where they are.
- The clock control is the only mutation `state/0` reports that is not a database row.

## Regression risks

- **`EngagementsFixtures.purge/0`** grows two patterns. Every existing non-sandboxed file depends on
  it; all ten must still pass. The `confirm_purged/0` count and the `oban_jobs` delete key off the
  same venue set, so both have to learn the second pattern or the purge silently stops confirming.
- **`.credo.exs`** gains one `:boundary_modules` entry. `clock_authority_test.exs` must still pass.
- **`mix.exs`** makes `elixirc_paths/1` public. Nothing else calls it; Mix calls it through
  `project/0` exactly as before.
- **`config/dev.exs` and `config/test.exs`** gain `demo_routes: true`. `runtime_config_test.exs`
  must still pass, and no production config file may name `:demo_routes` or `Clock.Offset`.
- **`lib/hospitality_coms_web/router.ex`** gains a compile-gated scope. Every existing route must
  still resolve, and the router must still compile under `:prod` with the scope absent.
- **`Clock.Offset`** gains `restore/1`. `clock_test.exs` must still pass, and the new function needs
  its own coverage — including that it restores an accumulated advance, which `set/1` clears.
- **CI** gains a prod-compile step. It compiles the dependency tree for a third environment; the
  `_build` cache absorbs it after the first run.
- **`Workers.ExpireEngagement` and `Workers.RetentionSweeper` gain a second caller.** Neither
  changes. `expire_engagement`'s contract — "writes nothing to `engagements`" — is what makes
  calling it from a control safe, and `retain_own_messages/2`'s guard being *inside* that function
  rather than dispatched on the expiry is, in U10's own words, "the rule U11's demo control needs
  when it drives the worker directly".

## Test matrix

`demo_test.exs` and `demo_controller_test.exs` are **not sandboxed** and take
`EngagementsFixtures.real_connections/0`, for U5's reason: the manifest spans both repos' connections
and under the sandbox those are two transactions that cannot see each other's rows. Both are
`async: false`, additionally because they move the global `Clock.Offset`.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | Seeding produces a person holding concurrent engagements at both employers | demo_test | unit | **issue scenario 1**, R45 |
| 2 | …and the venue-B entry is hidden from venue A by the concurrency default | demo_test | unit | **"a hidden concurrent entry"** |
| 3 | …and venue A's own entry is visible to venue A (control) | demo_test | boundary | a view returning nothing at all satisfies 2 |
| 4 | Seeding produces an accepted peer connection with at least two messages | demo_test | unit | **issue scenario 2** |
| 5 | …and a pending request that is `:pending` at t0 | demo_test | unit | "a pending request" |
| 6 | Seeding produces a past roster with a closed period, a live shift and a closed shift | demo_test | unit | "a past roster, a live shift, a closed shift" |
| 7 | …and the two shift types carry different graces, copied onto their rooms | demo_test | boundary | "two shift types with differing graces" |
| 8 | …and the past shift's roster is readable, which a roster stamped at t0 would not be | demo_test | boundary | decision 4 — the clock walk |
| 9 | Seeding leaves a person holding zero engagements whose account still works | demo_test | unit | R21's second half, before any control runs |
| 10 | Seeds are idempotent: a second run writes no row and returns the same ids | demo_test | unit | **issue scenario 10** |
| 11 | …and a partially seeded database is `{:error, :partial_manifest}` | demo_test | boundary | 10 passing for a seed that never wrote anything |
| 12 | A clock advance alone deletes nothing | demo_test | unit | **issue scenario 3**, the control half |
| 13 | …and the advance followed by `run_due_work/0` deletes exactly the due shift messages | demo_test | unit | **issue scenario 3** |
| 14 | `run_due_work/0` announces a term that closed long before the production sweep window | demo_test | boundary | decision 2's widened lower edge |
| 15 | …and `EngagementSweeper.lookback_from/1` still names the production window (control) | demo_test | boundary | the demo silently redefining the sweeper |
| 16 | `run_due_work/0` stamps the archive deadline through the real worker | demo_test | unit | criterion 4 — a control that re-implements the worker |
| 17 | …with nothing due it writes a `retention_runs` row of zeroes and announces nothing | demo_test | boundary | "no rows, no record" |
| 18 | Advancing past a shift's grace boundary closes that room | demo_test | unit | **issue scenario 5** |
| 19 | …and the room one second before the boundary is still open (control) | demo_test | boundary | a room that was closed all along satisfies 18 |
| 20 | Advancing thirty-one days past an engagement end lapses peer visibility | demo_test | unit | **issue scenario 6** |
| 21 | …and the pending request that depended on it reports `:lapsed` | demo_test | unit | R14's derived state, reached by the control |
| 22 | …and the accepted connection is untouched and still carries its messages | demo_test | boundary | **the payoff** — visibility gating a conversation that already exists |
| 23 | Ending every engagement a person holds leaves their profile readable | demo_test | unit | **issue scenario 7**, AE7 |
| 24 | …and their conversations still send and receive | demo_test | unit | **issue scenario 7**, AE7 |
| 25 | …and their own retained message copies survive | demo_test | unit | AE7 — "the worker keeps their record" |
| 26 | …and they hold zero engagements afterwards (control) | demo_test | boundary | 23–25 passing for a control that ended nothing |
| 27 | The control refuses a venue's last grant-holding engagement | demo_test | unit | **issue scenario 8**, R22, KTD17 |
| 28 | …and ends none of that person's other engagements when it refuses | demo_test | boundary | a partial refusal nobody can undo |
| 29 | The control is refused an `EmployerScope` by function clause | demo_test | boundary | **issue scenario 9** |
| 30 | …and an employer session cannot see the cross-venue set it operates on | demo_test | boundary | **issue scenario 9**, the tier under the clause |
| 31 | `EngagementsFixtures.purge/0` removes a seeded manifest | demo_test | boundary | the guard's loud category filling with false alarms |
| 32 | `priv/repo/seeds.exs` refuses to run under `MIX_ENV=test` | demo_test | boundary | the guard's "nothing seeds this database" premise |
| 33 | `elixirc_paths(:prod)` excludes `dev_support/` | demo_test | boundary | **issue scenario 4**, part 1 |
| 34 | Every module compiled from `dev_support/` is outside the production compile path | demo_test | boundary | **issue scenario 4**, part 2 — total over the directory |
| 35 | No module compiled from `lib/` references a module compiled from `dev_support/` | demo_test | boundary | **issue scenario 4**, part 3 — what makes the prod compile succeed |
| 36 | …and the same detector finds `Demo → Clock.Offset` (control) | demo_test | boundary | a structural check nobody has watched succeed |
| 37 | No production config file names `Clock.Offset` or `:demo_routes` | demo_test | boundary | a build that compiles and then boots the override |
| 38 | `Clock.Offset.restore/1` puts back a fixed instant and an accumulated advance | clock_test | unit | decision 4's restore silently clearing the advance |
| 39 | `POST /api/demo/seed` returns the manifest | demo_controller_test | unit | the surface existing |
| 40 | `POST /api/demo/clock` advances and answers with the new instant | demo_controller_test | unit | R20 reachable without a console |
| 41 | …and a malformed duration is an `ErrorEnvelope` with `code: "bad_request"` | demo_controller_test | boundary | criterion 10 |
| 42 | `POST /api/demo/run-due-work` reports what it did | demo_controller_test | unit | criterion 4 over HTTP |
| 43 | `POST /api/demo/people/:id/end-engagements` refuses the last grant holder as an envelope | demo_controller_test | boundary | R22 over HTTP, and criterion 10 |
| 44 | The demo routes exist in `:test` and are gated by a compile-time key | demo_controller_test | boundary | a route that ships |

Controls, so no assertion can pass for the wrong reason:

- 3 is the control for 2: a view returning nothing satisfies 2 alone.
- 11 is the control for 10: a `seed/0` that never wrote anything is idempotent.
- 12 is the control for 13, and it is the issue's own wording — "the advance alone does not".
- 15 is the control for 14: a demo that quietly rewrote the sweeper's window would satisfy 14.
- 17 is the control for 13 and 16: a sweep that deleted everything, or nothing, satisfies neither.
- 19 is the control for 18: a room closed since seeding satisfies 18.
- 22 is the control for 20: a lapse that also broke the connection satisfies 20 and destroys the
  payoff.
- 26 is the control for 23–25: a control that ended nothing leaves the profile working trivially.
- 28 is the control for 27: a refusal that had already ended three engagements satisfies 27.
- 30 is the tier under 29: a function clause is a convention, and the RLS policy is not.
- 36 is the control for 35: a detector that finds nothing anywhere passes 35.
- 3, 15, 19, 22, 26 and 28 are the six that make the demo's claims claims about behaviour rather
  than about the fixture.

Every behavioural row is proved load-bearing by mutation before this brief is closed out: the
mutation is applied, the named test is watched to fail, and the mutation is reverted. The count is
reported with the unit. Nine tests in this project's history have read as coverage while providing
none — four of them found in U10's review alone — and every one was a check with no control or a
control comparing something to itself.

## Implementation constraints

- `@spec` on every public function; error atoms enumerated, never `{:error, term()}` or `any()`.
  `Ecto.UUID.t()` for entity ids.
- `HospitalityComs.Demo` reaches contexts only. It calls `Repo` for the one thing no context
  exposes — enumerating a person's engagements across venues by id rather than by scope — and never
  `EmployerRepo` directly.
- No `Ecto.Query` in the controller and no `Repo` in it either; the controller's whole job is to
  turn a request into one `Demo` call and one JSON body.
- Every refusal on the HTTP surface goes through `HospitalityComsWeb.ErrorEnvelope`. Nothing
  hand-rolls a body.
- No migration, no schema, no zone change. If the implementation finds it needs one, that is a
  finding to record, not a table to add.
- `mix format`, `mix compile --force --warnings-as-errors` in dev **and** under `MIX_ENV=prod`,
  `mix quality`, and three full `mix test` runs with the counts reported.

## Revisions

Recorded rather than applied silently, per the convention this series established.

- **The issue's file paths are overridden.** `lib/hospitality_coms/demo.ex` and
  `lib/hospitality_coms_web/controllers/demo_controller.ex` become
  `dev_support/hospitality_coms/demo.ex` and
  `dev_support/hospitality_coms_web/controllers/demo_controller.ex`. Reason in decision 1: the
  issue's own next sentence — "The clock override is structurally absent from production builds" —
  is unsatisfiable at the path it names, and `lib/` is where KTD5b's mechanism stops working.
- **`test/hospitality_coms/demo_test.exs` is joined by
  `test/hospitality_coms_web/controllers/demo_controller_test.exs`.** The issue names one file and
  two production modules; `AGENTS.md` allows no untested surface, and an HTTP boundary tested
  through the context it delegates to is not tested.
- **`mix.exs`, `.credo.exs`, `config/dev.exs`, `config/test.exs`,
  `lib/hospitality_coms_web/router.ex`, `test/support/fixtures/engagements_fixtures.ex`,
  `dev_support/hospitality_coms/clock/offset.ex` and `.github/workflows/ci.yml` are also touched.**
  Each for one reason, each named in "Regression risks" above. None of them is a behaviour change to
  an existing unit.
- **`Workers.EngagementSweeper` is not driven by the demo**, only its window arithmetic is reused.
  Decision 2 says why; row 15 keeps the two honest.
