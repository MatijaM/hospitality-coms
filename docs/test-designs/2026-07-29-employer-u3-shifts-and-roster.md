# Test Design Brief — employer U3, shift types, shifts, and the roster

Plan: `docs/plans/2026-07-29-001-feat-crude-employer-view-plan.md`, section `### U3`, plus
KTD-E4, KTD-E6, KTD-E7, KTD-E9 and KTD-E10.
Origin: `docs/brainstorms/2026-07-29-crude-employer-view-requirements.md` (R8–R15, R16–R18;
AE7, AE8, AE9).
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Committed before any production code,
so the ordering is visible in the history rather than asserted. Nearest precedent:
`docs/test-designs/2026-07-29-employer-u2-the-handshake.md`, whose branch this one is cut from.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before
implementation began. Recorded here because `AGENTS.md` requires the substitution to be visible in
the artifact rather than inferred from the absence of a review.

## What is being built

Six routes, and unlike U1 and U2 this is not transport over finished contexts. Two context
functions change shape, and one of the two changes because a *bounded* read of a list that is
ordered earliest-first returns the wrong end of it.

```
GET    /api/employer/venues/:venue_id/shift-types
POST   /api/employer/venues/:venue_id/shift-rooms
GET    /api/employer/venues/:venue_id/shift-rooms[?extent=all]
POST   /api/employer/venues/:venue_id/shift-rooms/:shift_room_id/roster
GET    /api/employer/venues/:venue_id/shift-rooms/:shift_room_id/roster
DELETE /api/employer/venues/:venue_id/shift-rooms/:shift_room_id/roster/:engagement_id
```

All six sit on `:authenticated_person` and resolve their acting grant per request through
`HospitalityComsWeb.EmployerAuth.employer_scope/2`, which is U1's. **A shift room *is* the shift**
— there is no `shifts` table — so `POST shift-rooms` names a shift type and a term and nothing
else.

Three production changes are behaviour rather than transport, and each gets its own headed
decision below: the shift-room list's bound and ordering, the shift type it now preloads, and the
engagement the roster now preloads.

## Decision 1 — one pull request, not two, and the plan's split line is still the right one

The plan says: *"This unit should split, and here is the line … Cut it at **shift types + shift
rooms + extent** | **roster**."* The reasoning is review load, and it is sound. It is not taken,
for reasons that are about this branch rather than about the work:

- **The stack is already two deep.** U3 sits on `feat/employer-u2-the-handshake`, which is open as
  PR #59 against `main`. Splitting makes it three deep, and a stacked PR is closed by GitHub when
  its base branch disappears — which has already happened once on this plan.
- **The two halves share one controller module, one test file and one moduledoc argument.** The
  roster half's refusal mapping is the *same* R15/R17 flatness argument as the shift half's, and
  the file that carries it would be written twice and reconciled once.
- **The roster half is genuinely small.** Three routes over `Rosters.add_to_roster/3`,
  `list_roster/2` and `remove_from_roster/3`, plus a one-line preload. What makes U3 large is the
  shift-room bound, and that does not split any further.

What is taken from the plan's argument is the **commit** boundary: the shift half and the roster
half land as separate commits behind the brief, so a reviewer can read the branch in the two
halves the plan describes without a second base branch existing.

## Decision 2 — "most recent" is by `starts_at`, and that is a choice with a cost

`Records.earliest_first/1` is `order_by: [asc: room.starts_at, asc: room.id]`, and
`read_shift_rooms/1` applies it to every room the venue has ever had. A `limit` in front of that
returns the venue's **oldest** rooms — every count assertion passes and the shift the manager just
created is missing, which is F2's entire payoff.

The fix is `list_venue_room_messages/3`'s: select descending with a limit, re-order ascending in
SQL around it (`Records.most_recent/2`'s shape), and probe with `limit + 1` for `complete`.

**The ordering key is `starts_at`, not `inserted_at`, and the two are not the same list.** A
manager who creates next month's rota before tonight's shift gets next month's rooms in the page
and tonight's outside it. `starts_at` is chosen anyway, for one reason: the page must be a
*contiguous suffix* of the ordering the page is displayed in. Selecting on `inserted_at` and
displaying on `starts_at` produces a page that is a scattered subset of the venue's schedule, in
which "there is more" tells the reader nothing about *where* the more is. Every list in this
application that has a bound has this property, and it is what makes `complete` a statement a
client can act on.

The residue is recorded rather than closed: **a backdated shift created today does not appear in
the default read** if the venue has more than the bound's worth of later-starting rooms.
`extent=all` reaches it, which is what that extent is for.

**No new index.** `*_create_rooms.exs` already carries `(venue_id, starts_at, id)`, and a btree is
scanned in either direction.

## Decision 3 — a second page struct, and the two bounds are independent constants

`HospitalityComs.Rooms.ShiftRoomPage` is new and is `MessagePage`'s shape with a different element
type: `rooms` and `complete`, `bounded/2` taking `Enum.take(rows, -limit)` from the end because the
probe is the oldest row, `whole/1` for `:all`.

It is a second struct rather than a generalised one because `@type t()` is what Dialyzer checks,
and a page whose contents are `[RoomMessage.t()] | [ShiftRoom.t()]` checks nothing about either.
Renaming `MessagePage` to a generic `Page` would rewrite #48's merged code and the `messages` key
in an existing response for a saving of eight lines.

**The extent vocabulary is not duplicated.** `MessagePage.extent()` stays the one declaration of
`:recent | :all`, and `Rooms.list_shift_rooms/2`'s spec names it. A second
`@type extent() :: :recent | :all` would be issue #42's shape — two declarations of one word,
held together by prose.

**`recent_shift_room_limit/0` is 30, and no relationship to `recent_message_limit/0`'s 50 is
asserted anywhere.** Thirty is roughly a month of daily shifts at one venue, which is the window a
manager has open when they are building next week's rota. Two lists that happen to share a number
are exactly what issue #42 catalogues, so they deliberately do not share one.

## Decision 4 — the shift type is preloaded, and there is one rendered shift room on this API

KTD-E7 offers a client-side join and then recommends against it. It is right, and the reason is
this tree's own document: `docs/solutions/conventions/one-entity-one-key-name-and-decoders-that-refuse-the-other.md`.
`HospitalityComsWeb.RoomController` already renders a shift room for the person side as
`{shift_room_id, venue_id, shift_type_name, starts_at, ends_at, closes_at}`. An employer render
carrying `shift_type_id` where the person's carries `shift_type_name` is one entity with two
shapes on one API.

So `Rooms.list_shift_rooms/2` preloads `:shift_type` — after the read, in the context function,
which is where `AGENTS.md` asks for a preload and where `list_readable_shift_rooms/2` already does
it — and `RoomController.render_shift_room/1` becomes **public** `rendered_shift_room/1` with an
exported type, exactly as `RoomChannel.rendered/1` was made public for `RoomController` to call.
`EmployerController` calls it. There is one spelling.

## Decision 5 — the roster preloads its engagement, and the row that proves it is a future starter

KTD-E10 is right and the hole it names is real. `Rosters.list_roster/2` returns `RosterEntry`
structs carrying `engagement_id` and no `role_label`, so R13 — *"each entry naming the engagement
and the role label"* — has no source.

The cheap fix is a client-side join against the people list the page already holds, and it has a
hole that only shows up in a demo. `add_to_roster/3` accepts an engagement whose term *"must not
have closed … it need not have opened"*, while `Engagements.list_engagements/1` returns only
engagements **active at the instant**. A hire starting next Monday, legitimately rostered onto next
Tuesday's shift today, is therefore absent from the people list and renders as a bare UUID.

So `list_roster/2` preloads `:engagement` and the render projects `role_label` off it.

**The test that distinguishes the preload from the client join is the future starter, and without
that row in the fixture the hole is unobserved.** Both halves of it are asserted: the roster entry
carries the label, *and* the same engagement is absent from the venue's people list at the same
instant. The second is the control — without it, "the label came from the preload" and "the label
could have come from the people list" are the same green.

## Decision 6 — `extent` moves to a module of its own

`RoomController` owns a private `extent/1` and the sentence `extent must be "recent" or "all"`.
`EmployerController` needs both. This tree has already answered what to do when a second caller
appears: `HospitalityComsWeb.EntityId` was extracted for exactly this and its moduledoc says
*"there is still exactly one spelling."*

`HospitalityComsWeb.Extent.cast/1` and `Extent.refusal/0` are new;
`RoomController` calls them and keeps its behaviour. **`room_controller_test.exs` is the regression
proof and does not change**, which is U1's manoeuvre with `ChannelAuth.employer_scope/2`.

The alternative — five duplicated clauses and a refusal sentence written twice — puts a
user-visible string in two places, which is the same defect class the extraction avoids in the
first place.

## Decision 7 — R15 is flat, and the plan's own scenario is one response short

The plan's AE7 scenario says: *"Rostering onto another venue's shift room, and rostering another
venue's engagement, both produce the same body as an id naming nothing — three responses compared
for equality."*

R15 names **four** conditions, not three: *"Rostering an engagement that is already rostered, or
naming a shift room or engagement that does not belong to this venue, is refused without disclosing
which."* `HospitalityComs.Rosters` distinguishes `:already_rostered` from `:not_found` internally,
so the transport has to decide, and the requirement decides it: all four are one `404` with one
sentence, and the test compares **four** responses for equality.

**The counter-argument is recorded rather than acted on**, because it is a good one and a later
unit may want it. `:already_rostered` is reachable only after both ids have resolved *inside the
caller's own venue* — `add_to_roster/3` checks the grant, then the room at this venue, then a
live engagement at this venue, and only then whether an open entry exists. So it discloses nothing
the same session cannot read from `GET …/roster`, which is R6's argument for the claim route's
three distinguishable refusals. What it costs to flatten is operator feedback: a manager who adds
the same person twice is told *"no such shift room, or no such engagement, or it is not one you can
reach"*, which is true and unhelpful. Flipping it is a one-line change to one clause and a
requirement change, and it should be the second, not the first.

**The changeset arm collapses into the same answer, and that is not sloppiness.**
`RosterEntry.join_changeset/3` casts nothing from user attributes, so the only changeset
`add_to_roster/3` can produce is `roster_entries_no_overlap` — which is `:already_rostered` reached
by losing a race rather than by the friendly check. One condition, one answer. It is unreachable
from this transport without two concurrent callers and is therefore **carried untested here**;
`rosters_test.exs` and `rooms_concurrency_test.exs` own it. Recorded rather than given a test that
appears to reach it, which is what U2 did with the employer route's `:grant_not_live` arm.

## Decision 8 — what each write answers, and where a `bad_request` is honest

`POST shift-rooms` and `POST …/roster` answer `201` with the created thing. `DELETE …/roster/:id`
answers **`204` with no body**: `remove_from_roster/3` closes a period rather than deleting a row,
and returning the closed entry would hand a client a row it must not render. KTD-E8 predicted this
and it is confirmed here, so U4's `write` verb must take a success status rather than assuming
`201`.

`shift_type_id` in the create body and `engagement_id` in the roster body are **required and are
not path parameters**, so there are two distinct failures and they are not the same:

- **absent** → `400`, one sentence naming the field. This is `ClaimController`'s precedent
  exactly: a request with no `claim_code` is `bad_request`, distinct from an unknown code, because
  a client that did not name the thing is a client bug and swallowing it hides the bug at the only
  place that can see it.
- **present and malformed, or present and naming nothing, or present and belonging to another
  venue** → `404`, the flat sentence. `EntityId.cast/1` is what keeps the malformed case out of
  Ecto's query builder, where it would raise and answer `500` — telling a caller malformed from
  unknown by the status.

The test asserts the `400` body is **not equal** to the `404` body, which is the mirror of the
equality assertions R15 needs.

## Decision 9 — nothing rendered here names a human, and the roster is the one that could

The shift-type and shift-room renders withhold nothing sensitive; their key sets are pinned because
R18 asks for it and because U5's decoders are written against them.

**The roster entry is different.** It is rendered off a preloaded `Engagement`, and an `Engagement`
carries `person_id` — the globally stable cross-venue key `CLAUDE.md` records as a live disclosure.
So the render is a field list (`engagement_id`, `role_label`, `joined_at`) and it carries the same
two-pin shape U1 and U2 use: an exact key set against a literal, plus
`Engagement.__schema__(:fields)` beside it containing `:person_id`, so an empty render cannot pass
for a redacted one.

`engagement_id` is a safe key for a client list: `roster_entries_no_overlap` plus
`Records.rostered_at/2` means at most one live entry per engagement per room, so it is unique
within the response.

## Acceptance criteria

1. `GET shift-types` answers the venue's shift types, oldest first, key set equal to a literal.
2. `POST shift-rooms` with a valid type and term answers `201`, and the room's `venue_id` and
   `grace_period_minutes` are the **type's** — a body naming different ones changes neither.
3. `POST shift-rooms` with `ends_at <= starts_at` is `422` naming `ends_at`.
4. `POST shift-rooms` naming another venue's type, an id naming nothing, and a malformed id
   produce byte-identical `404`s; naming no type at all is `400` and a different body.
5. `GET shift-rooms` at the default extent over `bound + 1` rooms answers exactly `bound` rooms,
   **the newest is in them and the oldest is not**, and `complete` is `false`.
6. `GET shift-rooms?extent=all` answers every room, `complete` `true`.
7. `complete` is `true` over `bound - 1` rooms and `false` over `bound + 1`.
8. `GET shift-rooms?extent=nonsense` is `400`, with a body different from the `404`.
9. The rendered shift room carries the shift type's **name**, and its key set equals the person
   side's literal.
10. `POST …/roster` answers `201` and the roster then lists exactly one entry.
11. Every roster entry carries `role_label`, **including one whose engagement has not started**,
    which is absent from the venue's people list at the same instant.
12. Rostering the same engagement twice is refused and the roster still lists one entry.
13. Already-rostered, another venue's shift room, another venue's engagement and an id naming
    nothing produce four byte-identical `404`s.
14. `DELETE …/roster/:engagement_id` answers `204`, the roster is then empty **having been
    non-empty first**, and the `roster_entries` row still exists with `left_at` set.
15. Removing an engagement that is not rostered, and removing from a shift room that does not
    exist, produce the same `404`.
16. All six routes are `401` without a bearer token and answer with one.
17. All six routes are `404` for a session that holds an engagement but no grant at the venue;
    the same session at a venue it does manage is answered.
18. Every response's key set is pinned against a literal written out in the test file.

## Edge cases

- **A venue with no shift types** cannot create a shift. `GET shift-types` answers `200 []` rather
  than a refusal — the venue exists and the session may act for it; having nothing is not an error.
  (The seed's Kolektiv is exactly this, and the plan records it as a demo risk.)
- **A venue with no shift rooms** answers `200 {shift_rooms: [], complete: true}`. A `complete`
  derived from a non-empty list gets this one wrong.
- **Exactly `bound` rooms** is `complete: true` — the probe's own boundary.
- **A future starter** is rosterable and absent from the people list. Decision 5.
- **An engagement whose term has closed** is `:not_found` from `add_to_roster/3`, which lands in
  the same flat `404`.
- **Removing twice** — the second is `:not_rostered`, the same `404` as a room that does not
  exist.
- **`extent` on a route that has no bound** — `GET shift-types` and `GET …/roster` ignore it. Not
  asserted; they take no such parameter and adding one is a route change.

## Regression risks — existing files at risk, by path

| Path | Why | How it is covered |
|---|---|---|
| `test/hospitality_coms/rooms_test.exs` | `list_shift_rooms/1` returns a page, not a list. One existing test destructures it | changed mechanically, and the new bound tests join it |
| `test/hospitality_coms/rosters_test.exs` | `list_roster/2` grows a preload | existing assertions unchanged; new preload tests added |
| `test/hospitality_coms_web/controllers/room_controller_test.exs` | `extent/1` moves out of `RoomController` and `render_shift_room/1` becomes public | **unchanged**, and that is the proof |
| `test/hospitality_coms_web/controllers/employer_controller_test.exs` | six actions join three | existing tests unchanged |
| `test/hospitality_coms/boundary_test.exs` | must not move: zero migrations, zero grants | asserted by not changing |
| `test/hospitality_coms_web/channels/shift_room_channel_test.exs` | reads shift rooms through the same records | unchanged |

⚠️ **POTENTIAL REGRESSION** — three, disclosed per `AGENTS.md`'s format.

**1. `Rooms.list_shift_rooms/1` changes its return type.**

- Current behavior: `{:ok, [ShiftRoom.t()]}` — every shift room the venue has ever had, earliest
  first, shift type not loaded.
- Proposed change: `{:ok, ShiftRoomPage.t()}` — at most `recent_shift_room_limit/0` rooms, the
  **most recent** by `starts_at`, re-ordered earliest first, with `complete`, shift type preloaded.
  A second arity takes `:all`.
- What may stop working: any caller destructuring the list.
- Affected callers or surfaces: **none in production.** `grep -rn 'list_shift_rooms' lib/` finds
  only the definition; `dev_support/` and `client/` name it nowhere. One test destructures it.
- Evidence and remaining uncertainty: the grep above. No uncertainty — the function has had no
  caller since U6 shipped it.
- Safer alternative: leave `/1` unbounded and add `/2`. Rejected: `AGENTS.md` says paginate every
  list that grows with tenant data, and an unbounded default is one forgetful caller from
  production, which is the argument #48 already made for the message reads.
- Regression coverage needed: the bound tests below, plus the existing "lists the venue's rooms
  earliest first and refuses another venue's" test, updated and kept.

**2. `Rosters.list_roster/2` preloads `:engagement`.**

- Current behavior: entries with `engagement` unloaded.
- Proposed change: `EmployerRepo.preload(:engagement)` after the read. One extra query per call,
  not per row.
- What may stop working: nothing structurally; a caller matching `%RosterEntry{engagement: %Ecto
  .Association.NotLoaded{}}` would break, and none exists.
- Affected callers or surfaces: `rosters_test.exs` and `rooms_test.exs` read the list; neither
  matches on the association. `list_engagement_periods/3` is **not** changed — different caller,
  different association set, which is what `AGENTS.md` asks for.
- Evidence and remaining uncertainty: `grep -rn 'list_roster' lib/ test/ client/`. None.
- Safer alternative: a separate `list_roster_with_labels/2`. Rejected — two functions answering
  one question is how one concept comes to have two spellings, and R13 says the label belongs to
  every entry the roster can hold.
- Regression coverage needed: the existing `list_roster/2` describe block, unchanged, plus the
  future-starter test.

**3. `RoomController`'s `extent/1` and `render_shift_room/1` move or become public.**

- Current behavior: both private to `RoomController`.
- Proposed change: `extent/1` becomes `HospitalityComsWeb.Extent.cast/1`;
  `render_shift_room/1` becomes public `rendered_shift_room/1`.
- What may stop working: nothing — behaviour is identical and the caller is unchanged.
- Affected callers or surfaces: `RoomController`'s four actions.
- Evidence and remaining uncertainty: `room_controller_test.exs` passes unchanged, which is the
  whole evidence.
- Safer alternative: duplicate five clauses and a user-visible sentence in `EmployerController`.
  Rejected — `EntityId`'s precedent.
- Regression coverage needed: none new; the existing file not changing is the coverage.

## Test matrix

`test/hospitality_coms_web/controllers/employer_controller_test.exs` is already non-sandboxed
(KTD-E9) and takes `EngagementsFixtures.real_connections/0`. `rooms_test.exs` and
`rosters_test.exs` are non-sandboxed for U5's reason.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | the bounded read over `bound + 1` rooms returns `bound` of them, the newest present and the oldest **absent** | rooms | boundary | the descending selection. **A limit on `earliest_first/1` passes the count and fails this** |
| 2 | the page is ordered earliest first, equal to the last `bound` ids of the fixture | rooms | boundary | the outer re-order; a page in selection order renders the rota backwards and passes row 1 |
| 3 | `:all` returns every room, `complete: true` | rooms | boundary | the extent branch; a limit applied to `:all` too passes rows 1–2 |
| 4 | `complete` is `true` at exactly `bound` rooms | rooms | boundary | the `limit + 1` probe; a hard-coded `false` passes row 1 |
| 5 | an empty venue is `{[], complete: true}` | rooms | boundary | `complete` derived from a non-empty list |
| 6 | every room in the page carries its `%ShiftType{}` | rooms | unit | the preload; without it the render raises |
| 7 | another venue's list is still empty and `fetch_shift_room/2` still refuses | rooms | regression | the venue filter surviving the rewrite |
| 8 | `list_roster/2` entries carry `engagement.role_label` | rosters | unit | the preload |
| 9 | a **future starter** is on the roster with a label, and is **absent** from `list_engagements/1` at the same instant | rosters | boundary | KTD-E10's whole argument. The second assertion is what makes the first mean "preload" rather than "join" |
| 10 | `GET shift-types` answers oldest first; key set equals a literal; **control:** `ShiftType.__schema__(:fields)` has `:venue_id`, which the render omits | employer | integration | the route and the render |
| 11 | `POST shift-rooms` answers `201`; the room's grace and venue are the **type's** though the body names others | employer | boundary | `create_shift_room/3` taking both off the resolved type. **Control:** the body's values are different from the type's, or the assertion is satisfied by coincidence |
| 12 | `ends_at <= starts_at` is `422` naming `ends_at` | employer | unit | `for_changeset/3` reaching the response |
| 13 | another venue's shift type, an unknown id and a malformed id give **byte-identical** `404`s | employer | boundary | R17 flatness; `EntityId.cast/1` for the malformed one, without which it is `500` |
| 14 | a body naming no `shift_type_id` is `400`, body **not equal** to row 13's | employer | boundary | the guard clause; inequality is what proves the two are distinct |
| 15 | `GET shift-rooms` default extent over `bound + 1`: exactly `bound` rows, newest present, oldest absent, `complete: false` | employer | integration | rows 1 and 4 reaching the wire. **The fixture must hold `bound + 1`** |
| 16 | `?extent=all` returns all `bound + 1`, `complete: true` | employer | boundary | the extent parameter reaching the context |
| 17 | `?extent=nonsense` is `400`, body **not equal** to a `404` | employer | boundary | `Extent.cast/1`; a silent fall back to `:recent` passes every other row |
| 18 | the rendered shift room's key set equals a literal and carries `shift_type_name`; **control:** `ShiftRoom.__schema__(:fields)` has `:grace_period_minutes` and `:shift_type_id`, neither rendered | employer | boundary | the preload and the shared render |
| 19 | `POST …/roster` is `201` and `GET …/roster` then lists exactly one entry | employer | integration | the two routes |
| 20 | **R13**: the roster entry's key set equals a literal and carries `role_label`; **control:** `Engagement.__schema__(:fields)` has `:person_id` | employer | boundary | the preload and the field-list render |
| 21 | **the future starter over HTTP**: rostered, labelled in the roster, and **absent** from `GET …/engagements` at the same instant | employer | boundary | row 9 end to end. The second half is the control that rules out the client join |
| 22 | **AE8**: rostering twice — the second is refused and the roster **still lists one** | employer | boundary | `unrostered/3`. The count is AE8's literal requirement; the status is row 23's |
| 23 | **R15**: already-rostered, another venue's room, another venue's engagement and an id naming nothing are **four byte-identical** `404`s | employer | boundary | the flat mapping. **Control:** a good rostering at the same venue is `201`, so a route that refused everything cannot pass |
| 24 | a roster body naming no `engagement_id` is `400`, not equal to row 23 | employer | boundary | the guard clause |
| 25 | **AE9**: `DELETE` is `204`; the roster was non-empty and is then empty; the `roster_entries` row **still exists with `left_at` set** | employer | boundary | KTD6b. The row assertion distinguishes closed from deleted; without it a `DELETE` that deleted passes |
| 26 | removing an unrostered engagement, and removing from an unknown room, give the same `404` | employer | boundary | `remove_from_roster/3` answering `:not_rostered` for both |
| 27 | all six routes are `401` with no token and answered with one | employer | boundary | the pipeline; the answered half is the control |
| 28 | all six routes are `404` for a session engaged but not granted at the venue; **control:** the same session at a venue it manages is answered | employer | boundary | `EmployerAuth` on every action |
| 29 | `room_controller_test.exs` passes **unchanged** | room | regression | the `Extent` extraction and the public render being behaviour-preserving |
| 30 | `boundary_test.exs`, `shift_room_channel_test.exs`, `engagements_test.exs` green and unchanged | (three) | regression | this unit changing a zone, a grant or a context it has no business changing |

## Controls, listed explicitly

- **Row 1 is its own control for row 15's count**, and vice versa. A count alone is satisfied by a
  bound that took the oldest rooms — the exact defect KTD-E6 exists to prevent — so both rows name
  the first and last ids rather than counting. `MessagePage`'s moduledoc calls this *"the one
  mistake this function can make silently"*.
- **The fixture holds `bound + 1` rows.** #48's issue: *"a test that asserts '50 came back'
  against a fixture holding 12 passes for the wrong reason."* Rows 1, 2, 3, 15 and 16 all depend on
  the fixture being over the bound, and row 4 depends on a *second* fixture that is exactly at it.
- **Row 3 controls rows 1–2.** A limit applied to `:all` as well would satisfy the bounded rows and
  make "load all" a lie.
- **Row 4 and row 5 are the two directions of `complete`.** A flag hard-coded either way passes
  one of them.
- **Row 9's second assertion is the control for its first**, and row 21's is the control for its
  first. Without them, "the label came from the preload" and "the label could have come from the
  people list" are the same green — which is the whole of KTD-E10.
- **Rows 10, 18 and 20 each carry a `__schema__(:fields)` control**, because without it "the render
  omits the field" and "there is no field to omit" are the same green — the shape
  `docs/solutions/test-failures/tests-that-certify-nothing.md` calls *"cleared and never set as the
  same DOM"*.
- **Row 11's control is inside the request.** The body carries a `venue_id` and a
  `grace_period_minutes` that **differ from the type's**; against a body echoing the type's values
  the "not castable" claim is untested.
- **Row 23's control is row 23's own last line** — a successful rostering at the same venue in the
  same test, so a route that answered `404` to everything cannot pass it.
- **Rows 14, 17 and 24 assert *inequality*.** They are the mirror of rows 13 and 23's equality:
  two claims that causes are indistinguishable, three that two causes are not the same cause.
- **Row 25's database assertion is the control on its status.** A `DELETE` that actually deleted
  answers `204` and empties the roster, and passes everything except the row check.
- **Row 22's count is AE8's requirement, not its proof.** The proof is the status in row 23, which
  is what a mutation moves.
- **Every list is asserted non-empty before anything is asserted about it**, because KTD-E9's
  environment failure has exactly one signature: every employer list coming back empty.

## Implementation constraints

- **No new clock read.** Every action takes its instant from `conn.assigns.current_scope` and the
  `EmployerScope` U1's resolver builds off it. `.credo.exs`'s `:boundary_modules` must not grow
  (KTD-E1).
- **`EntityId.cast/1` for every id off the wire** — two path ids and two body ids.
- **Every error body through `ErrorEnvelope`**, status atom *being* the envelope's code;
  `for_changeset/3` for field errors.
- **`@spec` on every render function naming every key**, which is what Dialyzer checks.
- **Queries live in `Rooms.Records`.** The new ordering is a records function, not a `where` at a
  call site.
- **Zero migrations, zero new tables, zero new grants, `config/config.exs` untouched, and
  `boundary_test.exs` not touched.** **Never migrate `hospitality_coms_dev`.**
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev **and**
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline on this branch's parent is **1166/1170**, the
  four `PostgresRolesTest` failures being issue #20's documented `hospitality_coms_dev` condition
  and not this branch's.
- **No client work.** U5 owns it.
- **The moduledocs carry the arguments**, not this file: KTD-E6's ordering in
  `Rooms.Records`, R15's flatness in `EmployerController`, KTD-E10's preload in `Rosters`.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | six routes, two context changes, both extents, both directions of `complete`, four-way flatness |
| Control discipline | 5/5 | the three assertions most likely to be vacuous — the bound, the two preloads — each carry a control that fails when they do, and the bound's control is a fixture size rather than an assertion |
| Regression protection | 4/5 | three disclosed regressions, one of which (`room_controller_test.exs`) is proved by a file *not* changing, which is weaker evidence than a new assertion |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it; rows 1 and 15 name the *ordering*, which is the defect the plan says has already been shipped elsewhere |
| Risk of a vacuous pass | 4/5 | closed on the headline rows; the residue is that rows 10–18 assert against a response rather than against the row, so a render echoing its own request would pass some of them — row 11 is what reaches the row |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly. The
sections above are not edited to agree with what shipped.

1. **The brief's own fixture size was wrong, and it is the finding of the unit.** Every "Controls"
   line above says the fixture holds `bound + 1` rows, copying #48. **Measured: at `bound + 1` the
   selection direction is unobservable.** The read selects `limit + 1` rows as its probe, so
   against a venue holding exactly `limit + 1` a descending scan and an ascending one return *the
   same set*; `bounded/2` then takes the same tail from both. Flipping
   `Records.most_recent_rooms/2` to ascending killed **zero** tests.

   **The same hole is in #48's merged message bound**, and it was measured there too: flipping
   `Records.most_recent/2` to ascending killed zero tests in `rooms_test.exs` and
   `room_controller_test.exs`. That is the defect the whole bound exists to prevent — a page taken
   from the wrong end satisfies every count assertion and hides the newest rows — so a fixture that
   cannot see it certifies nothing about it.

   Six fixtures moved to `limit + 2`: this unit's two and #48's four. The flip now kills three
   tests in each family. `room_controller_test.exs` was **not** touched, so its regression role for
   the `Extent` extraction stays clean; its own message fixture is still `limit + 1` and is
   end-to-end coverage rather than a bound proof.

2. **The unit did not split into two pull requests, and the brief's own commit-split promise was
   not kept either.** Decision 1 argued for one PR with two commits, shift half then roster half.
   The two halves share `employer_controller.ex`, `router.ex` and `employer_controller_test.exs`,
   including one interleaved moduledoc, so splitting the commit meant hand-building a
   shift-only variant of three files and restoring it — fiddly, with a real chance of an
   intermediate commit that does not compile, for a reviewability gain a single PR diff already
   provides. One implementation commit, plus a separate commit for revision 1's finding.

3. **The plan's file list omits `lib/hospitality_coms/rosters.ex` and
   `test/hospitality_coms/rosters_test.exs`**, although its own Approach text names
   *"`list_roster/2`'s engagement preload for `role_label` (KTD-E10)"* as one of three context
   changes. KTD-E10 lives in `HospitalityComs.Rosters`, not in `HospitalityComs.Rooms`.

4. **Decision 7 held and is now measured.** Mapping `:already_rostered` to `409` kills two tests —
   AE8's and R15's four-way equality — so the flat mapping is load-bearing rather than incidental.

5. **AE8's count certifies nothing, and the brief predicted the wrong reason.** Row 22 says it
   fails without `unrostered/3`. **Measured: deleting `unrostered/3`'s refusal kills exactly one
   test, the context's**, and not the route's. `roster_entries_no_overlap` refuses the second
   insert, the changeset arm maps to the same flat `404`, and the roster still holds one entry. The
   count is AE8's literal requirement; the **status** is what a mutation moves, and revision 4 is
   what moves it. This is U2's AE3 finding again, in a different context.

6. **Two guards are redundant and are kept anyway.** Widening `@term_fields` to include
   `grace_period_minutes` and `venue_id` kills **zero** tests, because `ShiftRoom.changeset/3`
   casts two fields and `put_change`s the grace and the venue off the resolved shift type. Removing
   `list_shift_rooms/2`'s `is_binary(grant_id)` guard kills **zero**, because
   `Venues.fetch_acting_grant/1` heads on the same guard. Both are
   `docs/solutions/test-failures/what-a-zero-kill-mutation-means.md`'s case (b) — a guard protecting
   a different entry point — not a coverage hole and not a deletion. Row 11's control still
   measures the end-to-end claim (body asks 120, row stores 45), which is what the requirement
   says; it just does not attribute it to the controller.

7. **Row 25's row assertion has a second guard nobody wrote for it.** Replacing the closing
   `update_all` with `delete_all` fails with `42501 insufficient_privilege`:
   `employer_role` holds no `DELETE` on `roster_entries`, so the grant tier refuses the deletion
   before any Elixir does. The test still kills the mutation; the attribution belongs to the
   database.

8. **Refusal sentences are four, not one.** The brief implies one flat sentence per action.
   Shipped: `@no_venue` for the venue (R17), `@no_shift_type` for a type this venue does not run,
   `@no_shift_room` for a roster read, `@no_roster_target` for R15's four conditions and the
   removal's `:not_rostered`. The venue is cast **before** the other ids, in its own `with` step,
   so a malformed venue id answers what an unresolvable venue answers and a malformed room or
   engagement id answers what an id naming nothing answers. One `EntityId.cast/1` inside the `with`
   cannot tell those apart, because both arms are `:error`.

9. **Rows do not map one-to-one onto test bodies**, as every unit since U8 has recorded. Thirty
   rows became **thirty-two** new Elixir bodies — twenty-one in `employer_controller_test.exs`,
   eight in `rooms_test.exs`, three in `rosters_test.exs` — plus one existing `rooms_test.exs` body
   changed mechanically for the new return type. Rows 27 and 28 are one body each looping over six
   routes rather than six bodies; rows 29 and 30 are whole existing files rather than new bodies.

10. **Baseline arithmetic.** **1166/1170** before, **1198/1202** after — thirty-two new bodies, and
    the same four `PostgresRolesTest` failures naming `hospitality_coms_dev` (issue #20), which are
    a developer's local migration rather than this branch's.

## Mutation record

Thirty-four mutations, each applied to a clean tree, measured against the narrowest files that
could answer, then restored. Every new behavioural test is killed by at least one.

| # | Mutation | Tests killed |
|---|----------|--------------|
| 1 | `most_recent_rooms/2` selects ascending | **0** at a `bound + 1` fixture; **3** at `bound + 2` — see revision 1 |
| 1b | `most_recent/2` (messages) selects ascending | **0** at `limit + 1`; **3** at `limit + 2` |
| 2 | the page is not re-ordered ascending (selection order shown) | 4 |
| 3 | `:all` applies the bound too | 2 |
| 4 | `ShiftRoomPage.bounded/2` takes from the front | 3 |
| 5 | `complete` hard-coded `false` | 4 |
| 6 | `complete` hard-coded `true` | 2 |
| 7 | the `:shift_type` preload is dropped from the list | 6 |
| 8 | the created room does not carry the type it was built from | 4 |
| 9 | the roster's `:engagement` preload is dropped | 6 |
| 10 | the written roster entry does not carry its engagement | 8 |
| 11 | `render_shift_type/1` loses `grace_period_minutes` | 1 |
| 12 | `ShiftRoom.changeset/3` also casts `grace_period_minutes` | **0** — `put_change` overwrites it |
| 12b | …and the `put_change` is removed with it | 20 |
| 13 | `create_shift_room/2` skips `EntityId.cast/1` on the type | 1 (`Ecto.Query.CastError` → `500`) |
| 14 | `@term_fields` widened to `grace_period_minutes` and `venue_id` | **0** — see revision 6 |
| 15 | `create_shift_room/2` loses its `bad_request` clause | 1 |
| 16 | the shift type's `:not_found` answers `409` | 2 |
| 17 | the shift changeset arm answers `404` rather than `422` | 1 |
| 18 | `Extent.cast/1` falls back to `:recent` for an unknown word | 2 (one of them `room_controller_test.exs`'s) |
| 19 | `:already_rostered` answers `409` rather than the flat `404` | 2 |
| 20 | `Rosters.unrostered/3`'s refusal deleted | 1, and **not** the route's — see revision 5 |
| 21 | the roster ids skip `EntityId.cast/1` | 1 |
| 22 | `create_roster_entry/2` loses its `bad_request` clause | 1 |
| 23 | removal answers `200` with the closed entry | 3 |
| 24 | removal deletes the row rather than closing the period | 12 — see revision 7 |
| 25 | `render_roster_entry/1` names the entry rather than the engagement | 2 |
| 26 | `render_roster_entry/1` grows `person_id` | 1 |
| 27 | `shift_types/2` refuses a venue with none | 2 |
| 28 | `shift_types/2` answers an ungranted venue with `[]` | 1 |
| 29 | the shift-room response drops `complete` | 3 |
| 30 | `list_shift_rooms/1` defaults to `:all` | 2 |
| 31 | the roster read answers an unknown room with `[]` | 1 |
| 32 | the removal route skips `EntityId.cast/1` | 1 |
| 33 | shift types come back newest first | 1 |
| 34 | `list_shift_rooms/2` loses its grant guard | **0** — see revision 6 |
| 35 | the shift-types route leaves the authenticated pipeline | 4 |
| 36 | `rendered_shift_room/1` grows `shift_type_id` | 3 (one of them `room_controller_test.exs`'s) |

**Mutations 1, 1b, 14, 20 and 34 are the ones worth reading twice.** The first two are the unit's
finding and are a defect in a merged test as much as in this one. The other three are zero-kills
that are *not* coverage holes, and the reasoning for leaving each is in the revisions above.

Two things are deliberately **not** asserted, following U1 and U2. Nothing pins `.credo.exs`'s
contents from a test — the rule is that the file does not change, which a diff shows. And nothing
asserts the *absence* of a `grant_id` or a `venue_id` field on any form, only that a body naming
one changes no row; a test for the absence of a thing passes for ever whether or not anything
prevents it.
