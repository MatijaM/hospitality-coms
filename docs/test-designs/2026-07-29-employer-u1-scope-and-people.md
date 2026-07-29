# Test Design Brief — employer U1, the employer scope on a conn and the venue's people

Plan: `docs/plans/2026-07-29-001-feat-crude-employer-view-plan.md`, section `### U1`.
Origin: `docs/brainstorms/2026-07-29-crude-employer-view-requirements.md` (R7, R16, R17, R18;
AE5, AE6, AE10).
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Nearest
precedent: `docs/test-designs/2026-07-29-48-room-lists-and-history.md`.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before
implementation began. Recorded here because `AGENTS.md` requires the substitution to be visible
in the artifact rather than inferred from the absence of a review.

## What is being built

Two HTTP reads and the resolver every later employer route will copy.

```
GET /api/employer/venues                            -> 200 {venues: [{venue_id, name}]}
GET /api/employer/venues/:venue_id/engagements      -> 200 {engagements: [{engagement_id,
                                                                          role_label,
                                                                          starts_at, ends_at}]}
```

Both sit on the existing `:authenticated_person` pipeline. There is no employer pipeline and
there must not be one: the venue is a path parameter, so the authority is per-request and
per-venue, and a pipeline would have to guess which venue before the router had parsed one.

Three pieces are new and one is a move:

- `HospitalityComsWeb.EmployerAuth.employer_scope/2` —
  `(PersonScope, venue_id) -> {:ok, EmployerScope} | {:error, :no_grant}`. New module.
- `HospitalityComsWeb.ChannelAuth.employer_scope/2` keeps its signature and **delegates** to it,
  so there is one spelling of "resolve the acting grant" (KTD-E2). Its private `acting_scope/3`
  moves.
- `HospitalityComs.Engagements.list_managed_venues/1` — the venues this person may act for. New
  capability; nothing in the tree answers this question today.
- `HospitalityComsWeb.EmployerController` — two actions, field-list renders.

The employer *engagements* read is pure transport: `Engagements.list_engagements/1` exists,
takes an `EmployerScope`, resolves its grant against the database on every call, and refuses
correctly.

## Decision 1 — the venue picker is a new context read, and the suspended manager is the test that proves it

OQ1, resolved by the product owner on 2026-07-29 after the plan's adversarial review.

`Rooms.list_venue_rooms/1` already returns `{venue_id, name}` for every venue a person is
engaged at, and reusing it costs zero backend work. It is wrong, and not cosmetically:

- `Rooms.Records.venues_of_person/2` composes `unsuspended/2`;
- `Engagements.fetch_grant_holding_engagement/2` — the resolver *every* employer route runs —
  never consults suspensions, and must not (KTD18).

So a manager who used the person-side venue-room opt-out keeps full employer authority over the
venue and **vanishes from their own picker**, with no other way in. Their authority still works
everywhere else, so nothing fails; the venue simply stops being reachable. That is precisely the
coupling KTD18 exists to prevent, arriving through the back door of a list reused for the wrong
question.

The new read is therefore: **venues where this person holds an engagement active at the scope's
instant carrying a grant the venue has not revoked, suspensions not consulted.** Person-scoped,
through `HospitalityComs.Repo`, exactly as `fetch_grant_holding_engagement/2` is and for the same
reason — it reads a person's own engagements by `person_id` and then asks `employer_grants`
whether the authority is live, and no single session holds the privileges for both halves.

**The test that matters most in this unit is a suspended manager who still appears**, with the
control beside it that `Rooms.list_venue_rooms/1` returns `[]` for that same person at that same
instant. Without the control, a suspension that never took effect satisfies the test. Without the
test, the new endpoint is indistinguishable from the one it was chosen over and the decision
leaves no trace in the tree.

### Where "live" is spelled, and the one file this unit touches that the plan does not list

`EmployerGrant.live_at/2` takes a `venue_id`. The picker asks the same question across every
venue, so it needs the predicate without one.

⚠️ **POTENTIAL REGRESSION — disclosed before the change.**

- **Current behavior:** `HospitalityComs.Venues.EmployerGrant.live_at/2` builds
  `venue_id == ^venue_id AND granted_at <= ^instant AND (revoked_at IS NULL OR revoked_at >
  ^instant)`.
- **Proposed change:** a new `live_at/1` carrying the two time clauses, and `live_at/2` composed
  from it as `from grant in live_at(instant), where: grant.venue_id == ^venue_id`. Same rows,
  same parameters, predicate order changed.
- **What may stop working:** nothing behavioural. The risk is a test asserting on generated SQL
  or on parameter order.
- **Affected callers or surfaces:** four call sites, all query-level and none inspecting SQL —
  `lib/hospitality_coms/venues.ex:576`, `lib/hospitality_coms/engagements/records.ex:194`,
  `test/hospitality_coms/boundary_test.exs:2606`,
  `test/hospitality_coms/venues_concurrency_test.exs:286`. Evidence line:
  `grep -rn 'EmployerGrant.live_at(' lib/ test/`.
- **Evidence and remaining uncertainty:** no test in the tree calls `to_sql` on a grant query.
  The residue is that `boundary_test.exs` and `venues_concurrency_test.exs` both read grants
  through `EmployerRepo`, where a row-level security policy also applies; a predicate reordering
  cannot change which rows a policy admits.
- **Safer alternative:** spell the two time clauses again inside `Engagements.Records`.
  **Rejected** — `CLAUDE.md` records that `Records.decision_set/4` reuses `EmployerGrant.live_at/2`
  *"so 'live' cannot come to mean two things"*, and a third spelling is exactly what that
  sentence forbids.
- **Regression coverage needed:** rows 20–21 below, plus every existing assertion in
  `venues_test.exs`, `engagements_test.exs`, `lifecycle_test.exs` and `boundary_test.exs`
  continuing to hold unchanged.

**Finding recorded rather than fixed:** `HospitalityComs.Lifecycle.Records.live_grant/1` and
`live_grant_holder/1` already restate the predicate inline, while `orphaned_venues/1`'s docstring
says *"`EmployerGrant.live_at/2`, reused rather than restated, so 'live' cannot come to mean two
things."* It is not reused there; it is correlated on `parent_as(:venue)` and written out. This
unit does not touch that file — composing `live_at/1` into a correlated subquery is a change to
retention behaviour's query plan for no assertion this unit needs — but the claim in that
docstring is currently false and somebody should know.

## Decision 2 — `EmployerAuth` owns the resolution, and its refusal is 404 while the channel's is 401

KTD-E2 and KTD-E3.

`ChannelAuth.employer_scope/2` is `join_scope/1` (socket → session) followed by
`fetch_grant_holding_engagement/2` followed by `EmployerScope.for_grant/3`. The conn side has the
`PersonScope` already — `require_authenticated_person` produced it — so the `:no_session` arm
does not exist there. The shared part is not transport-shaped at all: it is
`(PersonScope, venue_id) -> {:ok, EmployerScope} | {:error, :no_grant}`.

`HospitalityComsWeb.EntityId` is the precedent for extracting rather than duplicating: it moved
out of `ChannelAuth` when a second caller appeared and left `topic_id/1` delegating, and its
moduledoc's justification — *"there is still exactly one spelling"* — is the same one here.

**Two conn-side modules named `*Auth` that do different things is a trap**, so the moduledoc says
it in its first paragraph: `PersonAuth` authenticates and `EmployerAuth` authorises.

**The refusal diverges from the channel's and that is deliberate.** `EmployerVenueChannel`
answers `unauthorized`; the routes answer `404` with one sentence. R17 requires the wire to
preserve `:no_grant`'s flatness — an ended engagement, an engagement holding nothing, a revoked
grant and a venue that does not exist are one answer — and a `403` would confirm the venue
exists. A channel join has no resource to be not-found about and is internally consistent,
answering `unauthorized` for a nonexistent venue too. Recorded in `EmployerAuth`'s moduledoc so a
later reviewer does not read it as drift.

## Decision 3 — the render is a field list, and the control is `__schema__(:fields)`

KTD-E4, and D2/D3 from the origin.

`Engagement` structs carry `person_id` — the globally stable cross-venue key, and a disclosure
`CLAUDE.md` already records under "Five disclosures on the record". `Engagements.list_engagements/1`
still returns whole structs and this unit does not change that; what it must not do is put one on
the wire.

So the rendered engagement is exactly `engagement_id`, `role_label`, `starts_at`, `ends_at`. The
pin is in three places, each catching what the others cannot:

1. a structural `@spec` on the render function naming every key and its type, which Dialyzer
   fails when the function and the spec disagree;
2. an **exact key-set equality** in the test against a literal written out in the test file —
   not `refute Map.has_key?`, because an absence assertion passes by default and that is the
   generative rule in `docs/solutions/test-failures/tests-that-certify-nothing.md`;
3. a **control asserting `Engagement.__schema__(:fields)` contains `:person_id`**, so an empty
   render, a broken fixture or a list that came back `[]` cannot pass for a redacted one.

**And a fourth, which is not optional here:** the list is asserted **non-empty before anything is
asserted about its contents**. KTD-E9 names an environment failure whose entire signature is that
every employer list comes back empty. Without that line every key-set pin in the file is the
"both operands empty" shape.

`engagement_id` rather than `id`, and `venue_id`/`name` on a venue, because
`docs/solutions/conventions/one-entity-one-key-name-and-decoders-that-refuse-the-other.md` says
an entity gets one key name across this API. `RoomController.render_venue_room/1` already spells
a venue `{venue_id, name}`.

Instants ship as `DateTime.to_iso8601/1` strings, #48's convention.

## Decision 4 — R16 is aimed at `EmployerAuth`, and the route-level test is labelled as what it is

This is the sharpest thing in the plan and it must not be lost in implementation.

The obvious test — revoke a grant between two requests, assert the second is refused — **cannot
fail for the mechanism this unit builds.** Every employer context call opens with
`Venues.fetch_acting_grant(scope)`, which resolves the grant live-at-instant inside the
`EmployerRepo` transaction. Hand `EmployerAuth` a stale grant id, cache it on the conn, cache it
in a module attribute: `list_engagements/1` still refuses. The route-level test stays green
against every mutation of the thing it appears to be testing.

So R16's assertion goes against **`EmployerAuth.employer_scope/2` directly** — revoke the grant,
call it, get `{:error, :no_grant}` — and the route-level test is written and commented as
**end-to-end coverage**, not as proof of re-derivation. Both live in the same file so a reader
meets the distinction in one place.

## Decision 5 — no new clock read, and `.credo.exs` is the check

KTD-E1. `PersonAuth.fetch_person_scope/2` already read `Clock.now/0` once for this request and
put the result on `conn.assigns.current_scope`. `EmployerAuth` takes its instant from there;
`EmployerController` takes its instant from there.

`.credo.exs`'s `:boundary_modules` holds **seven** entries today — `PersonAuth`, `ChannelAuth`,
`HospitalityComs.Demo`, and four workers. **This unit adds none**, and a diff that adds one is a
diff that read the clock twice in one unit of work. The check is `mix quality`; the assertion is
that the file is unchanged in the diff.

## Acceptance criteria

1. `HospitalityComs.Engagements.list_managed_venues/1` answers the venues where a person holds an
   engagement active at the scope's instant carrying a grant live at that instant.
2. It **does not** consult suspensions: a suspended manager still appears.
3. It excludes a venue where the person is engaged and holds no grant.
4. It excludes a venue whose grant has been revoked, at the same instant the engagement is still
   active.
5. It excludes a venue whose engagement is not yet active, and includes it once the instant
   passes `starts_at` — with nothing having run.
6. It orders by venue name, with `id` breaking ties.
7. `HospitalityComsWeb.EmployerAuth.employer_scope/2` answers `{:ok, EmployerScope}` carrying the
   venue, the grant and the person scope's instant, or `{:error, :no_grant}`.
8. It resolves against the database on **every** call: a grant revoked between two calls makes
   the second `:no_grant`.
9. `ChannelAuth.employer_scope/2` behaves identically after becoming a delegation.
10. `GET /api/employer/venues` answers `{venues: [{venue_id, name}]}`, exact key set.
11. A person holding no grant anywhere gets `{venues: []}` and `200`, not a refusal (AE10's server
    half).
12. `GET /api/employer/venues/:venue_id/engagements` answers the venue's engagements active at the
    request's instant, oldest first, key set exactly
    `{engagement_id, role_label, starts_at, ends_at}` (AE6, R7).
13. No employer-facing payload carries `person_id` or an email address.
14. A session with an engagement but no grant at that venue is refused `404` (AE5); a venue id
    naming nothing and a malformed id produce a **byte-identical** body (R17).
15. A **16-byte** id produces that same body — `EntityId.cast/1`'s byte-size guard.
16. No `Authorization` header is `401` from `require_authenticated_person`, not `404`.
17. Every error body is `HospitalityComsWeb.ErrorEnvelope`'s.
18. `@spec` on every public function, `Ecto.UUID.t()` for ids, error atoms enumerated.
19. `.credo.exs` is unchanged.
20. Every behavioural test proved load-bearing by mutation.

## Edge cases

- **A suspended manager.** Present in `list_managed_venues/1` and in `GET /api/employer/venues`;
  absent from `Rooms.list_venue_rooms/1`. Three answers from one state, and getting any of them
  wrong is KTD18 broken in a new direction.
- **A person with two venues, one managed and one not.** The picker returns one; the engagements
  route returns `200` for that one and `404` for the other, from the same session. This is AE5's
  seed shape (Ana at Harbour and Ana at Kolektiv) and it is the control that makes the refusal
  about the *grant* rather than about the session.
- **A grant revoked while the engagement stays active.** The venue leaves the picker and the
  route starts refusing, with no write to `engagements`.
- **An engagement whose term opens after the instant.** Absent from both; present after the
  clock moves. This is the assumption KTD-E5's `starts_at` default rests on, pinned here so U2
  inherits a checked claim rather than a sentence.
- **An engagement that ended.** Absent, and the venue leaves the picker if it was the only one.
- **A venue with a live grant nobody holds.** Absent from every person's picker — the grant is
  not the authority, holding it is.
- **A person with no engagements at all.** `{venues: []}`, `200`.
- **`GET /api/employer/venues/<uuid>/engagements` where the uuid is another venue entirely.**
  Same body as an id naming nothing.
- **The empty term.** `end_engagement/2` can produce `ends_at == starts_at`. Active at no
  instant, so absent from both reads. Not separately tested — `active_at/2` is one predicate and
  row 5 already exercises both of its bounds.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms_web/channels/employer_venue_channel_test.exs` | ten assertions on `ChannelAuth.employer_scope/2`'s behaviour, which becomes a delegation. **This file is the delegation's regression proof and must pass with no assertion changed.** |
| `test/hospitality_coms_web/channels/sockets_test.exs` | `ChannelAuth`'s surface changes shape; the socket routing table must not |
| `test/hospitality_coms/venues_test.exs`, `venues_concurrency_test.exs` | `EmployerGrant.live_at/2` is recomposed; every grant query must return the same rows |
| `test/hospitality_coms/engagements_test.exs` | `Records.live_grant_ids/2` sits on top of `live_at/2`; `fetch_grant_holding_engagement/2` and `end_engagement/2` both read it |
| `test/hospitality_coms/lifecycle_test.exs` | `orphaned_venues/1` restates the predicate rather than reusing it, so it is *not* affected — asserted by running it, not by reasoning |
| `test/hospitality_coms/boundary_test.exs` | no migration, no table, no grant, no view. **If this file moves, something was done that this unit did not intend.** |
| `test/hospitality_coms_web/controllers/room_controller_test.exs`, `session_controller_test.exs` | the router gains a scope; no existing route may be shadowed |
| `test/hospitality_coms/rooms_test.exs` | KTD18's existing pins on `venues_of_person/2` must keep meaning what they mean; this unit adds a read that deliberately differs from it |

## Test matrix

`test/hospitality_coms_web/controllers/employer_controller_test.exs` is **new and non-sandboxed**
(KTD-E9): `use ExUnit.Case, async: false`, `EngagementsFixtures.real_connections/0`,
`Clock.Offset.set/1` in `setup` with `on_exit(&Clock.Offset.reset/0)`, and a local `with_session/2`
minting a token. `HospitalityComsWeb.ConnCase` is the sandboxed alternative and must not be used:
an employer surface reads through `EmployerRepo` by definition and the bridge is written through
`Repo`, so under the sandbox every list comes back empty and **every negative assertion in the
file passes for the wrong reason**.

`test/hospitality_coms/engagements_test.exs` is already `async: false` on real connections.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | `list_managed_venues/1` returns the venue a grant-holding engagement names | engagements | unit | the read |
| 2 | **a suspended manager still appears** | engagements | boundary | `managed_venues/2` *not* composing `unsuspended/2` — the unit's headline |
| 3 | …and `Rooms.list_venue_rooms/1` answers `[]` for that same person at that instant | engagements | boundary | **control for 2** — a suspension that never took effect satisfies 2 |
| 4 | a venue where the person is engaged and holds no grant is absent | engagements | unit | the live-grant subquery |
| 5 | …and the managed venue is present in the same call | engagements | boundary | **control for 4** — a read answering `[]` satisfies 4 |
| 6 | a revoked grant removes the venue, the engagement untouched | engagements | boundary | `live_at`'s revocation clause |
| 7 | …and it was present before the revocation | engagements | boundary | **control for 6** |
| 8 | an engagement starting later is absent; advancing the clock makes it present | engagements | boundary | `active_at/2`'s lower bound, with nothing having run |
| 9 | an ended engagement's venue is absent | engagements | edge | `active_at/2`'s upper bound |
| 10 | two managed venues come back ordered by name | engagements | unit | `order_by` |
| 11 | a person with no engagements gets `[]` | engagements | edge | — (guards the `[]` path against a raise) |
| 12 | `EmployerAuth.employer_scope/2` builds a scope carrying venue, grant and the **scope's** instant | employer_controller | unit | the resolver |
| 13 | **revoke, then call it again → `:no_grant`** | employer_controller | boundary | **R16's only real proof.** Re-derivation per call |
| 14 | a venue this person holds no grant at → `:no_grant` | employer_controller | unit | the grant filter |
| 15 | `GET /api/employer/venues` renders `{venue_id, name}`, exact key set, list non-empty first | employer_controller | integration | the route and the render |
| 16 | a suspended manager still lists their venue over HTTP | employer_controller | boundary | the OQ1 decision reaching the transport |
| 17 | a person with no grant anywhere → `200 {venues: []}` | employer_controller | edge | AE10's server half; a route that refused would fail |
| 18 | `GET …/engagements` returns the venue's active engagements **oldest first**, list non-empty asserted first | employer_controller | integration | `list_engagements/1` reaching the transport |
| 19 | …and the rendered key set equals a literal `[engagement_id, role_label, starts_at, ends_at]` | employer_controller | boundary | the field-list render (AE6) |
| 20 | …with **control**: `Engagement.__schema__(:fields)` contains `:person_id` | employer_controller | boundary | **control for 19** — an empty render passes 19 alone |
| 21 | AE5: engaged at the venue, no grant → `404` | employer_controller | boundary | `EmployerAuth`'s refusal |
| 22 | …with **control**: the *same person* gets `200` at the venue they do manage | employer_controller | boundary | **control for 21** — a route that refused everything passes 21 |
| 23 | a venue id naming nothing and a malformed id produce **byte-identical** bodies | employer_controller | boundary | R17's flatness; equality rather than two matches is what proves it |
| 24 | a **16-byte** id produces that same body | employer_controller | boundary | `EntityId.cast/1`'s `byte_size(id) == 36`. A 35-char id proves nothing — `Ecto.UUID.cast/1` rejects it unaided |
| 25 | R16 end to end: revoke between two requests, second is `404` | employer_controller | integration | **labelled end-to-end coverage, not proof.** Row 13 is the proof |
| 26 | an engagement not yet active is absent from the route; the clock moves and it appears | employer_controller | boundary | `list_engagements/1`'s active-at filter; pins KTD-E5's assumption |
| 27 | both routes without a bearer token → `401`, and both with one → `200` | employer_controller | boundary | the pipeline; the `200` half is the control |
| 28 | every refusal body is the envelope, `code` matching the status | employer_controller | unit | a hand-rolled body |
| 29 | `EmployerVenueChannel`'s existing join tests pass unchanged | employer_venue_channel | regression | the delegation changing behaviour |
| 30 | `venues_test.exs`, `engagements_test.exs`, `lifecycle_test.exs`, `boundary_test.exs` unchanged and green | (four) | regression | `live_at/2`'s recomposition |

## Controls, listed explicitly

- **Row 3 controls row 2.** The whole unit turns on row 2, and row 2 alone is satisfied by a
  fixture whose suspension silently did nothing. Row 3 asserts the suspension is real by watching
  the *other* list drop the venue at the same instant.
- **Row 5 controls row 4** and **row 7 controls row 6.** A read that answers `[]` for everybody
  passes both negatives.
- **Row 20 controls row 19**, and it is the one `AGENTS.md` singles out: without it, "the render
  omits `person_id`" and "there is nothing to render" are the same green. The control asserts the
  *source struct* still carries the field.
- **The non-emptiness assertion controls rows 15, 18 and 19 as a set.** KTD-E9's failure mode is
  every employer list coming back empty; an exact key set over zero elements is vacuous.
- **Row 22 controls row 21.** The same session, two venues, two answers, is the only shape that
  proves the refusal is about the grant.
- **Row 27's control is its own second half.**
- **Row 13 controls row 25**, in the opposite direction from usual: row 25 cannot fail for this
  unit's mechanism, so row 13 is what carries the claim and row 25 is labelled as coverage. A
  file carrying only row 25 would report R16 as proved and prove nothing.
- **Row 8's second half controls its first.** "Absent" alone is satisfied by a read that returns
  nothing; the same engagement appearing after the clock moves, with no write, is what makes it a
  statement about derivation.
- **Row 24 is the mutation-killing case for `EntityId`, and the brief says why the obvious
  alternative is not.** A 35-character id is refused by `Ecto.UUID.cast/1` unaided, so a test
  using one passes with the byte-size guard deleted and must not be described as evidence for it.

## Implementation constraints

- **The instant arrives on the scope.** No new `Clock.now/0` caller anywhere.
  `.credo.exs`'s `:boundary_modules` must not grow (KTD-E1).
- **No `person_id` in any rendered shape**, and no email address. `CLAUDE.md` records
  `list_engagements/1`'s whole-struct return as a live disclosure; this unit stops it reaching a
  client and does not change the context function.
- **Queries live in `Engagements.Records`** (`AGENTS.md`, "Query composition"). The controller
  builds no query and the context builds no `where` at a call site.
- **`Venues.fetch_acting_grant/1` is already public** and is what every employer context call
  uses; nothing here duplicates the check.
- **Every error body through `ErrorEnvelope`**, with the status atom *being* the envelope's code
  (`RoomController.refuse/3`'s shape).
- **`EntityId.cast/1` for every id off the wire**, byte-size guard included.
- **Zero migrations, zero new tables, zero new grants.** `boundary_test.exs` is untouched.
  **Never migrate `hospitality_coms_dev`.**
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev **and**
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline is **1122/1126**, the four
  `PostgresRolesTest` failures being issue #20's documented `hospitality_coms_dev` condition
  and not this branch's.
- **No client work.** U4 owns it.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | the new read, the resolver, both routes, at the context and at the transport |
| Control discipline | 5/5 | every negative has a positive beside it; the two assertions most likely to be vacuous (key set, suspended manager) each carry a named control |
| Regression protection | 4/5 | rests on eight existing files; one existing query function is recomposed and the disclosure names its four call sites by line |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it, and row 25 is explicitly marked as *not* falsifiable by this unit's mechanism |
| Risk of a vacuous pass | 4/5 | the non-emptiness line and the `__schema__` control close the headline ones; the residue is that rows 12–14 assert on a scope struct, so a resolver returning a correct-looking scope for the wrong venue would need row 21's route test to catch it |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.
The sections above are not edited to agree with what shipped.

_(to be appended)_
