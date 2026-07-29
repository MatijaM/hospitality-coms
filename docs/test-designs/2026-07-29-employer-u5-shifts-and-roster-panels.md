# Test Design Brief — employer U5, shifts and roster on screen

Plan: `docs/plans/2026-07-29-001-feat-crude-employer-view-plan.md`, section `### U5`, plus
KTD-E6, KTD-E7, KTD-E8 and KTD-E10.
Origin: `docs/brainstorms/2026-07-29-crude-employer-view-requirements.md` (R8–R15, R19; F2, F3;
AE7, AE8, AE9).
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Nearest precedent:
`docs/test-designs/2026-07-29-employer-u4-write-verb-and-handshake.md`, whose branch this one is
cut from.

**Approver: the orchestrating agent, in the human's place**, as with employer U1 through U4.

## This one runs as a gate, and that is the point of it

U4's brief is the only file in `docs/test-designs/` written *after* its implementation. It says
so at the top, at length, because the ordering evidence could not be manufactured afterwards —
and issue **#62** was opened to record that the gate has never applied to client work at all.

This brief is committed by itself, as the first commit on
`feat/employer-u5-shifts-and-roster-panels`, ahead of every line of production code and ahead of
every test. So the `Fails without` column below is a **prediction**, not a measurement, which is
what `AGENTS.md` asks it to be: *"the gate's expected-failure prediction … delete or invert the
named mechanism and the named test must fail."* A `## Mutation record` is appended in a later
commit, and a `## Revisions made during implementation` section records every place this
document turned out to be wrong.

Client-only: no Elixir file, no migration, no route, no `config/`. `mix` is not run.

## What is being built

Flows F2 and F3 in a browser, on the page U4 built. Three panels below the venue's people list:

```
Shifts at this venue     the venue's shift rooms, bounded, most recent first, with "load all"
Create a shift           a type off the venue's shift types, a start, an end
Roster                   opened from a shift: who is on it, add somebody, take them off
```

Every route these panels use is U3's and is merged. **Six calls**, all under
`/api/employer/venues/:venue_id/`:

| Call | Success | Body in | Body out |
|---|---|---|---|
| `GET shift-types` | 200 | — | `{shift_types: [{shift_type_id, name, grace_period_minutes}]}` |
| `GET shift-rooms[?extent=all]` | 200 | — | `{shift_rooms: [...], complete}` |
| `POST shift-rooms` | 201 | `{shift_type_id, starts_at, ends_at}` | `{shift_room: {...}}` |
| `GET shift-rooms/:id/roster` | 200 | — | `{roster: [{engagement_id, role_label, joined_at}]}` |
| `POST shift-rooms/:id/roster` | 201 | `{engagement_id}` | `{roster_entry: {...}}` |
| `DELETE shift-rooms/:id/roster/:engagement_id` | **204** | — | **none** |

The last row is the one U4 built `write`'s optional decoder for, and it is this unit's job to be
the caller that proves it.

## Decision 1 — two of the plan's U5 scenarios are unimplementable, and KTD-E7 is why

The plan's U5 approach says *"Shift-type names are joined client-side per KTD-E7"*, and two of
its seven test scenarios follow from that:

> - The shift list labels each room with its type's name.
> - A shift room whose `shift_type_id` is absent from the fetched type list renders the id rather
>   than `undefined`. **Control:** a room whose type *is* present renders the name…

**KTD-E7 does not say that. Its own recommendation is the opposite** — *"Recommended: **preload**,
now that KTD-E6 is rewriting the query anyway"* — and U3 took it. The evidence is in the tree:
`HospitalityComsWeb.RoomController.rendered_shift_room/1` renders
`{shift_room_id, venue_id, shift_type_name, starts_at, ends_at, closes_at}`, it is `public`
specifically so both sides share it, and `EmployerController.shift_rooms/2` calls it.

**There is no `shift_type_id` on a rendered shift room at all.** So the second scenario names a
field that does not exist, its control is the whole of what the first scenario already asserts,
and a client-side join has nothing to join on. Neither is written.

This is the same defect U4 found in the plan's U4 approach — a decisions section settled one way
and an approach paragraph never updated — and it is now the second occurrence, which is worth
saying out loud: **on this plan, read the KTD and the Decisions section, not the unit's Approach
paragraph.**

**What the shift-type list is actually for**, therefore, is R8 and F2 step 1: it is the *create
form's* picker. That is a real requirement and it stays.

## Decision 2 — the shift room becomes one shape in one module, because the server made it one

`RoomController.rendered_shift_room/1` is public so that *"a second shape carrying
`shift_type_id` where this one carries `shift_type_name` would be one entity with two spellings
on one API"*. The client's mirror of that decision is that there must be one decoder, and
`features/rooms/` already has it: `ShiftRoomListing`, `decodeShiftRoom` and `shiftRoomLabel`.

Three options, and two are bad:

- **A second `EmployerShiftRoom` type and decoder in `features/employer/`.** Exactly the
  divergence `docs/solutions/conventions/one-entity-one-key-name-and-decoders-that-refuse-the-other.md`
  is about, arriving on the client after the server spent a function-export preventing it.
- **A cross-feature import from `features/employer/` into `features/rooms/`.** This is the debt
  U4 created and paid off one commit later: `src/app/instant.ts` exists precisely because
  `features/employer/` reaching into `features/rooms/room.ts` is *"a cross-feature import into a
  feature directory, which nothing else in `src/features/` production code does"*.
- **Hoist.** `src/app/shift-room.ts` holds the type, the decoder and the label;
  `features/rooms/room.ts` and `features/rooms/decode.ts` re-export under the names the rooms
  surface wrote them with, so **no rooms file changes**. That is `Loaded`'s manoeuvre, and
  `instantLabel`'s, and `isRoomId`'s — and on the Elixir side it is `EntityId`'s and `Extent`'s,
  both of which moved on their second caller with the first delegating.

Taken: the hoist. Disclosed below as this unit's one ⚠️ **POTENTIAL REGRESSION**.

**The envelopes stay in their features and that is not an oversight.** The two routes differ —
`GET /api/venues/:venue_id/shift-rooms` answers `{shift_rooms: [...]}` and
`GET /api/employer/venues/:venue_id/shift-rooms` answers `{shift_rooms: [...], complete}` — so
each feature keeps its own body decoder over the one shared element decoder. A feature owns its
paths and its envelopes; the *entity* is the thing there can only be one of.

`"recent" | "all"` moves the same way and for issue #42's reason — it is the whole of this API's
paging vocabulary, `HospitalityComsWeb.Extent` is one module for both callers on the server, and
two declarations of a two-member union is a pair held together by nothing. It lands in
`src/api/types.ts` as `ListExtent`, because it is a wire word rather than a display one, and
`features/rooms/room.ts` re-exports it as `HistoryExtent`.

## Decision 3 — the bound is the server's, the order is the server's, and the client must not improve on either

`Rooms.list_shift_rooms/2` scans **descending** on `starts_at` with a `limit + 1` probe and
re-orders **ascending in SQL** around it, then answers a `ShiftRoomPage` carrying `complete`.
`recent_shift_room_limit/0` is 30 and this client must never learn that number — the extent is a
word, exactly as it is for a room's history, because *"a route that passes a number leaves the
unbounded read one forgetful caller away"*.

Three consequences, each of which is a test:

- **`complete` is not derivable here.** *"A full page and a full history of the same length are
  the same list"* — `MessagePage`'s own moduledoc. So the decoder requires it and does not
  default it, and the "load all" control is offered **only** when it is `false`. Both directions
  are asserted, because a flag hard-coded either way passes one of them.
- **The page is the venue's *latest* rooms** (R11), and that is what makes the shift a manager
  created a minute ago visible. Asserted by naming the first and last rows of the rendered list
  and asserting a room outside the page is absent — never by counting, which is the assertion
  `MessagePage`'s moduledoc calls *"the one mistake this function can make silently"*.
- **Nothing is sorted client-side.** The server's order is the display order. A `.sort()` here
  would hide exactly the bug the descending-scan-then-re-order split exists to prevent, and it
  would do it while satisfying every count.

**What this client's tests can and cannot pin about the order, stated honestly.** Within one page
the server's order *is* ascending by `starts_at`, so a client re-sorting ascending is
indistinguishable from one that does not sort, and no fixture can catch it without lying about
what the server sends. What is catchable — and what the tests below aim at — is any *other*
client-side ordering: reversed, by id, by the array's own insertion. The full rendered sequence
is asserted against the fixture's, so the list is pinned as a sequence rather than as a set.

## Decision 4 — the removal is the bodiless 204, and it must stay decoder-less

`write`'s optional decoder is U4's, built for this call and not exercised by it: *"Omitting it
means the response body is never read — which is what makes a bodiless `204` a success rather
than `malformed_response`, and it is exactly what a `read`-shaped implementation gets wrong."*

So `removeFromRoster` calls `api.write({method: "DELETE", path, status: 204}, token)` with **two
arguments**. The test asserts the exact request object *and* that no third argument was passed,
because `writesTo` does not check the status and would answer a `status: 200` request happily —
the failure would only appear against a real server, in front of an audience.

**The failure mode this prevents is specific and bad**: a removal that succeeded, reported as
failed, with the row already closed and `remove_from_roster/3` answering `:not_rostered` to every
retry. The manager would be told the person is still on the shift, then told there is no such
entry.

## Decision 5 — the create form is the only place this client produces an instant, and that is not a clock read

`POST shift-rooms` has **no server-side defaults**: `@term_fields` is `~w(starts_at ends_at)`
with no `Map.put_new`, and `ShiftRoom.changeset/3` validates both as required. That is the
opposite of KTD-E5's invitation, where all three instants default from `scope.now` — and it is
right, because a shift *is* a term somebody chose, while an offer's term is a formality.

So the form takes two `datetime-local` values and converts them. **This is not a second clock.**
`Clock.Offset` moves what the server thinks *now* is; it does not move the mapping from
"18:00 on 9 March" to the instant that names. `instantFromLocal` calls no `Date.now()`, compares
nothing, and the rule U4 wrote — *"every instant is rendered and never compared"* — is untouched.

Two things follow and both are tested:

- **The conversion is timezone-dependent and its test must not spell either side.**
  `new Date("2026-03-09T18:00").toISOString()` differs under `TZ=UTC` and `TZ=Pacific/Kiritimati`,
  so the assertion is the round trip — the produced string parses back to local 18:00 on 9 March —
  plus that it is a UTC instant rather than the local string passed through. Spelling the expected
  ISO string would be `room.test.ts`'s hazard by another route: green on one machine, red on
  another.
- **A value that will not parse must not reach the server.** `new Date("nonsense").toISOString()`
  **throws** `RangeError`, so the guard prevents an exception rather than a bad request.

**Residue, on the record.** A manager creating "tonight's shift" while `Clock.Offset` holds the
server thirty-one days ahead creates a shift in the server's past. That is inherent to a form
taking explicit instants and is not closed here; the alternative is the client computing a term
from its own clock, which is the thing KTD-E5 exists to forbid.

## Decision 6 — the roster's labels come off the server, and the add list is the people list

KTD-E10: `RosterEntry` carries no `role_label`, so R13 had no source until U3 preloaded the
engagement and `render_roster_entry/1` projected it. The hole the client-side join would have had
is the one that makes this testable: `add_to_roster/3` accepts an engagement whose term has **not
opened**, while `list_engagements/1` answers only with engagements active at the instant.

**So the roster fixture carries an entry whose `engagement_id` is absent from the people-list
fixture**, and it renders its role label anyway. A client joining against the people list renders
a bare id or nothing. That is the single assertion that distinguishes the preload from the join,
and without the absent row it cannot be made — the same shape as U4's `person_id`-carrying
fixture.

**Its control is an entry that *is* on the people list**, so the label is not being read out of
the one path that happens to work.

**What the client cannot do, recorded rather than fixed**: the add form offers the venue's people
list, so a future starter — rosterable by the API, absent from that list — cannot be added from
this page. Adding a free-text engagement-id box would fix it and would put a uuid paste box on a
crude form to serve a case the demo does not reach. Not built.

## Decision 7 — the refusal sentence is the server's, and this surface already decided that

`features/employer/refusal-message.ts` is U4's and is unchanged: `employerFailureMessage` renders
`failure.message` for `api_error` and `api_field_error`, and this client's own copy for
`unauthorized`, `network_error` and `malformed_response`. The argument is in that file's
moduledoc and it holds here for a sharper reason than it did there.

R15 makes four conditions into one sentence — *"no such shift room or engagement here, or the
roster already says otherwise"* — and the shift-type refusal is a *different* sentence under the
*same* `404` code: *"no such shift type at this venue"*, beside `EmployerController`'s
`@no_venue`. **Three sentences, one code.** A switch keyed on `not_found` can say one of them and
must be wrong about the other two.

So the two-test pattern is kept for every panel that can be refused: one test watches a sentence
arrive, and a second sends a **different** sentence under the same code and asserts the first is
**absent**.

## Decision 8 — guards behind guards, declared as pairs rather than discovered later

U4's finding was that four of its guards sat behind a second guard, so removing either alone
killed nothing. This unit adds three such pairs deliberately, and for each one says which is the
**affordance** (what a manager sees) and which is the **rule** (what the hook promises a caller):

| Pair | Affordance | Rule | Why both |
|---|---|---|---|
| create-shift in flight | the submit's `disabled` | `useShiftDesk`'s `creating` check | two clicks are two shift rooms at overlapping times, and nothing deduplicates them |
| roster write in flight | the button's `disabled` | `useRoster`'s `busy` check | a second `DELETE` after a successful one answers `404`, so the manager is told the removal failed |
| the create form's two instants | the submit's `disabled` on **blank** | `onSubmit`'s `null` check on **unparseable** | **these guard different inputs**, unlike U4's pair: blank is what a manager reaches, unparseable is what a non-conforming input produces, and `toISOString()` throws on the second |

The third row is the interesting one. U4's blank-role pair was redundant — neither half was
reachable alone — and the note it left was that *"the pair is what makes row 45 fail at all"*.
Here the two halves answer different inputs, so each is separately mutable and each is predicted
to kill its own test. If that prediction is wrong the mutation record will say so.

## Acceptance criteria

1. `shiftTypeLabel` names the type and the grace that distinguishes it from a similar one.
2. `rosterEntryLabel` names the role and when the entry opened, formatted, never as an ISO string.
3. `instantFromLocal` turns a local wall-clock value into a UTC instant that reads back as that
   same wall clock, and is not the input passed through.
4. `instantFromLocal` answers `null` rather than throwing for a value that is not a date-time.
5. A shift type decodes to exactly `{shiftTypeId, name, gracePeriodMinutes}`, and a
   `grace_period_minutes` of `0` decodes rather than being refused as falsy.
6. A shift type missing any of its three fields is refused, and one bad entry fails the whole
   list.
7. The shift-room page requires `complete` and does not default it.
8. The shift-room page's rooms go through the **shared** `decodeShiftRoom`, so a room missing
   `shift_type_name` fails the whole page.
9. A created shift room is read off the `shift_room` key and nowhere else.
10. A roster entry decodes to exactly `{engagementId, roleLabel, joinedAt}`, and a payload also
    carrying `person_id` decodes without it.
11. A roster entry missing `role_label` is refused — R13's label is required, not optional.
12. The roster list is read off `roster`; a created entry off `roster_entry`.
13. **R8 / F2.1**: the create form offers the venue's shift types by name.
14. **R9 / F2.2**: creating sends `{shift_type_id, starts_at, ends_at}` and nothing else, at
    `201`, on the venue's own path.
15. **F2.3**: the created shift appears in the list, which is asserted **not** to contain it
    first.
16. A form with nothing chosen or nothing typed does not reach the API.
17. Two clicks create one shift.
18. **R10**: every shift room in the list is labelled by its type's name and its term.
19. **R11 / KTD-E6**: the bounded read renders the page the server sent — first row and last row
    named — and a room outside the page is absent.
20. The list renders in the order the server sent, asserted as a whole sequence.
21. The "load all" control is offered when `complete` is `false`.
22. It is **not** offered when `complete` is `true`.
23. "Load all" asks `?extent=all` and renders more rows than the bounded read did, with the
    bounded rows asserted first.
24. **R12 / F3.2**: adding sends `{engagement_id}` at `201` on the shift's roster path, and the
    roster is re-read afterwards.
25. **R13 / KTD-E10**: an entry whose engagement is absent from the people list still renders its
    role label; an entry that is on the list renders too.
26. **R14 / AE9**: removing sends `DELETE … status 204` with **no decoder**, and the roster is
    empty afterwards — having shown the entry first.
27. Two clicks remove once.
28. An add with nobody chosen does not reach the API.
29. Opening a different shift shows that shift's roster and not the first's.
30. **R15**: a refused add renders the envelope's sentence; a **different** sentence under the
    same code renders that one and the first is absent.
31. A refused create renders the envelope's sentence, per-field messages included; the same
    control applies.
32. A refused list read renders the envelope's sentence rather than an empty-list sentence.
33. `unauthorized` renders this client's own words on both panels, and the server's are absent.
34. The rooms surface's files are **unchanged** by the shift-room hoist, and its suite passes.
35. `npm run verify` is clean, and identical under `NODE_OPTIONS="--localstorage-file=…"` and
    under two timezones.

## Edge cases

- **A venue with no shift types.** `200 {shift_types: []}` is a sentence, not a failure —
  `EmployerController` says so — and the seed's Kolektiv is exactly this venue. The create form
  must say why it cannot be used rather than rendering an empty `<select>`.
- **A venue with no shift rooms.** Same shape, and `complete` is `true`, so no "load all"
  control.
- **A shift with an empty roster.** A sentence, and the add form still usable.
- **`complete: true` on a full-looking page.** The control must be absent. This is the direction
  a flag hard-coded to `false` gets wrong.
- **`complete: false` on a short page.** The control must be present. A client deriving the flag
  from the row count gets this wrong, which is why it is not derived.
- **A term that crosses midnight.** The seed's rooms are eight hours anchored on `Clock.now()`,
  so any of them crosses local midnight when seeded after about four in the afternoon. Handled by
  `termLabel`, inherited rather than re-tested here; every fixture reads its expected string back
  out of the renderer.
- **A `datetime-local` that will not parse.** `toISOString()` throws. In a conforming browser the
  value is either empty or valid, so this branch is reachable only through a non-conforming input
  — and it is the difference between a refusal and an unhandled exception.
- **A shift removed and then the same engagement added again.** Not asserted: it is the server's
  question (`roster_entries_no_overlap` plus `Records.rostered_at/2`) and the client re-reads.
- **The people list failing while the roster succeeds.** The add form has nothing to offer and
  must say so rather than rendering an empty picker.

## Regression risks — existing files at risk, by path

| Path | Why | How it is covered |
|---|---|---|
| `client/src/features/rooms/room.ts` | `ShiftRoomListing` and `shiftRoomLabel` move out; `HistoryExtent` becomes an alias | re-exported under the same names; `room.test.ts` and `room-lists.test.tsx` pass **untouched** |
| `client/src/features/rooms/decode.ts` | `decodeShiftRoom` moves out | re-exported; `decodeShiftRooms` stays here and still calls it |
| `client/src/features/rooms/decode.test.ts` | imports `decodeShiftRoom` from its old home | the re-export is what keeps it unchanged, and it is the regression evidence |
| `client/src/features/rooms/room.test.ts` | imports `shiftRoomLabel` and the timezone matrix reaches it through `vi.resetModules()` | unchanged; re-run under two timezones |
| `client/src/features/rooms/rooms-api.ts`, `use-room-history.ts` | import `HistoryExtent` | type alias, no runtime change |
| `client/src/features/employer/employer-route.tsx` | grows three panels below the offer form | `employer-route.test.tsx` passes unchanged; its assertions are scoped with `within` |
| `client/src/features/employer/employer.ts`, `decode.ts`, `employer-api.ts` | grow types, decoders and five calls | additive; every existing export keeps its shape |
| `client/src/api/types.ts` | gains `ListExtent` | additive |
| `client/src/api/client.ts` | **must not change** — U4 gave `write` its method and status | asserted by not changing |
| `client/src/test-support/fake-api.ts` | **must not change** — `writesTo` already keys on method-and-path for this unit's `DELETE` | asserted by not changing; `fake-api.test.ts` passes |
| the Elixir tree | must not move: client-only unit | asserted by not changing |

⚠️ **POTENTIAL REGRESSION** — one, disclosed per `AGENTS.md`'s format.

**`ShiftRoomListing`, `decodeShiftRoom` and `shiftRoomLabel` move from `features/rooms/` to
`src/app/shift-room.ts`; `HistoryExtent` becomes an alias of `src/api/types.ts`'s `ListExtent`.**

- Current behavior: the shift-room wire shape, its decoder and its label live in
  `features/rooms/room.ts` and `features/rooms/decode.ts`, with `HistoryExtent` declared in
  `room.ts`.
- Proposed change: all four move to shared modules; `room.ts` and `decode.ts` re-export under the
  names the rooms surface wrote them with.
- What may stop working: any rooms file importing them from their old homes — `rooms-api.ts`,
  `use-room-history.ts`, `room-view.tsx`, `rooms-route.tsx`, `decode.test.ts`, `room.test.ts`.
- Affected callers or surfaces: the rooms surface entirely, and `room.test.ts`'s timezone matrix,
  which re-imports `./room` dynamically after `vi.resetModules()` — so the re-export has to
  survive a module reset, not merely a static import.
- Evidence and remaining uncertainty: no rooms file should appear in the diff, and
  `npm run typecheck` is part of `verify`. The uncertainty is the dynamic re-import above; it is
  closed by running the whole suite under two timezones, which is what reaches that helper.
- Safer alternative: copy the decoder into `features/employer/`. Rejected — it is the exact
  divergence `RoomController.rendered_shift_room/1` was made public to prevent, and
  `docs/solutions/conventions/one-entity-one-key-name-and-decoders-that-refuse-the-other.md`
  records three times this project has shipped it.
- Regression coverage needed: none new. The rooms suite passing **unchanged** is the coverage,
  and a mutation against the hoisted decoder that kills a body in `features/rooms/decode.test.ts`
  is what proves it is not passing vacuously.

## Test matrix

Predicted bodies, in four files. **Files:** `emp` = `src/features/employer/employer.test.ts`
(new); **dec** = `src/features/employer/decode.test.ts` (extended); **shifts** =
`src/features/employer/shifts.test.tsx` (new); **roster** =
`src/features/employer/roster.test.tsx` (new); **rooms** = the existing rooms suite.

Filenames checked against
`docs/solutions/test-failures/a-test-file-the-typechecker-cannot-see.md`: no `.tsx` here shares a
stem with a `.ts`, and `npx tsc --noEmit --listFiles` is run to confirm rather than assumed.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | a shift type is named with the grace that tells it from a similar one | emp | unit | `gracePeriodMinutes` in `shiftTypeLabel`; the server renders it because *"it is what a manager is choosing between"* |
| 2 | a roster entry is named by role and by when it opened, formatted | emp | unit | `instantLabel` on `joinedAt`; the ISO string is asserted absent |
| 3 | **a local wall-clock becomes the instant it names** | emp | boundary | the `toISOString()` conversion. Asserted as a round trip, never as a spelled string — the expected value differs per timezone |
| 4 | …and is not the local string passed through | emp | control | the same conversion. Row 3's control: a passthrough round-trips correctly and is not an instant |
| 5 | a value that is not a date-time answers `null` rather than throwing | emp | boundary | the `Number.isNaN` guard. `new Date("x").toISOString()` throws `RangeError` |
| 6 | a shift type has exactly the three keys the route renders | dec | boundary | the field-by-field object |
| 7 | **a grace of `0` decodes** | dec | control | `typeof … !== "number"` rather than a falsiness check. Row 6's control: `0` is the value a truthiness guard silently refuses |
| 8 | a shift type missing a field is refused, and one bad entry fails the whole list | dec | boundary | the per-field guards and `decodeEach`'s all-or-nothing |
| 9 | **the shift-room page requires `complete`** | dec | boundary | the `typeof body.complete !== "boolean"` guard. Defaulting it silently means "this is the whole list", which is the reading that makes the bound invisible |
| 10 | a room missing `shift_type_name` fails the whole page | dec | boundary | the shared `decodeShiftRoom` being called at all — this is the hoist's own assertion on the employer side |
| 11 | a created shift room is read off `shift_room` and nowhere else | dec | boundary | the envelope key |
| 12 | **a roster entry has exactly three keys, and a `person_id` decodes away** | dec | boundary | the field-by-field object. `render_roster_entry/1` reads off a preloaded `Engagement`, so the struct carrying `person_id` is one field access from the render |
| 13 | a roster entry with no `role_label` is refused | dec | boundary | the `role_label` guard. R13 says every entry names the label; an optional one renders a blank row |
| 14 | the roster list is read off `roster`, a created entry off `roster_entry` | dec | boundary | the two envelope keys |
| 15 | **R8**: the create form offers the venue's shift types by name | shifts | integration | `useShiftTypes` and its path |
| 16 | a venue with no shift types says so rather than offering an empty picker | shifts | boundary | the empty arm. Kolektiv is this venue in the seed |
| 17 | **R9**: creating sends the three fields and nothing else, at 201, on the venue's path | shifts | boundary | the body literal. `venue_id` and `grace_period_minutes` are the type's and are **not castable** — a client sending them would be relying on `Map.take/2` |
| 18 | **F2.3**: the new shift appears in the list, which did not contain it before | shifts | integration | the reload after a successful create. The "before" assertion is what stops this passing against a list that always held it |
| 19 | a form with nothing chosen does not reach the API | shifts | boundary | the submit's `disabled` on blank |
| 20 | an unparseable instant does not reach the API | shifts | boundary | `onSubmit`'s `null` check. Distinct from row 19: different input, different guard |
| 21 | two clicks create one shift | shifts | boundary | the submit's in-flight `disabled` |
| 22 | **R10**: every room is labelled by its type's name and its term | shifts | unit | `shiftRoomLabel`, which is the hoisted one |
| 23 | **R11**: the bounded page's first and last rows are named, and a room outside it is absent | shifts | boundary | the server's descending selection surviving to the screen. Named rather than counted — `MessagePage`'s *"the one mistake this function can make silently"* |
| 24 | **the whole rendered sequence equals the fixture's** | shifts | boundary | the absence of any client-side sort. See Decision 3 for what this can and cannot catch |
| 25 | **the "load all" control is offered when `complete` is `false`** | shifts | boundary | the `complete` branch |
| 26 | **…and is not offered when it is `true`** | shifts | control | the same branch, the other way. Row 25's control: a control rendered unconditionally passes 25 |
| 27 | "load all" asks `?extent=all` and renders more rows, the bounded rows asserted first | shifts | integration | `loadAll` moving the extent into the `ask` memo. The "first" assertion is what stops both reads returning one set |
| 28 | a refused shift-room read renders the envelope's sentence, not an empty-list sentence | shifts | boundary | the `failed` arm reaching `employerFailureMessage` |
| 29 | a refused create renders the envelope's sentence, per-field messages included | shifts | boundary | `failure.message` reaching the alert |
| 30 | **a different sentence under the same code renders that one**, the first absent | shifts | control | the same. Row 29's control |
| 31 | `unauthorized` gets this client's own words, the server's absent | shifts | control | the `unauthorized` branch. The control for 28–30: it proves the panel is not printing every `message` it is handed |
| 32 | **F3**: opening a shift reads its roster and shows who is on it | roster | integration | `useRoster` and its path |
| 33 | **R13 / KTD-E10**: an entry absent from the people list still renders its role label | roster | boundary | the server's preload reaching the render. A client-side join renders a bare id here |
| 34 | …and an entry that **is** on the people list renders too | roster | control | the same. Row 33's control: the absent row must not be the only path exercised |
| 35 | **R12**: adding sends `{engagement_id}` at 201, and the roster is re-read | roster | boundary | the body literal and the reload |
| 36 | **R14 / AE9**: removing sends `DELETE … 204` with **no decoder**, and empties the roster | roster | boundary | the decoder-less `write`. The entry is shown first, or "gone" and "never rendered" are the same DOM |
| 37 | **the removal passes no third argument** | roster | control | the same. Row 36's control: `writesTo` answers `ok(null)` for a decoder-less call *and* for one whose fixture happens to decode, so only the call shape tells them apart |
| 38 | two clicks remove once | roster | boundary | the button's in-flight `disabled` |
| 39 | an add with nobody chosen does not reach the API | roster | boundary | the add submit's `disabled` |
| 40 | opening a second shift shows that shift's roster, not the first's | roster | boundary | the panel's `key={shiftRoomId}` remount — `VenueDesk`'s manoeuvre for the claim code |
| 41 | a refused add renders R15's sentence | roster | boundary | `failure.message` reaching the alert |
| 42 | **a different sentence under the same code renders that one** | roster | control | the same. Row 41's control, and the one Decision 7 exists for: three refusals share `404` here |
| 43 | the rooms suite passes **unchanged** after the hoist | rooms | regression | the re-exports, and the decoder's behaviour surviving the move |

## Controls, listed explicitly

- **Row 4 is row 3's control.** A passthrough of the local string round-trips to the right wall
  clock, so row 3 alone is satisfied by a function that converts nothing.
- **Row 7 is row 6's control**, and it is the one this project keeps re-learning: a
  `grace_period_minutes` of `0` is the value a `!value` guard refuses while every fixture with a
  non-zero grace passes. `docs/solutions/test-failures/tests-that-certify-nothing.md` calls this
  "a fixture that made the operation under test the identity".
- **Row 26 is row 25's control.** Both directions of `complete`, because a control rendered
  unconditionally passes one and a control never rendered passes the other.
- **Row 27's bounded assertion comes first.** Without it, a fixture where both extents answer the
  same rows passes "load all renders more" by returning the same list twice — the shape #48
  shipped and U3 found.
- **Row 23 names rows rather than counting them.** A count is satisfied by the venue's *oldest*
  N rooms, which is precisely the defect KTD-E6 exists to prevent.
- **Row 34 is row 33's control**, and the fixture carries both rows in one roster. Without the
  present-in-the-list row, "the label came off the server" and "the label came off the people
  list" are the same green whenever the two agree.
- **Row 36 reaches the positive state first.** The entry is asserted on screen before the
  removal, or "the roster is empty" is satisfied by a roster that never rendered.
- **Row 37 is row 36's control**, and it is the only assertion that can tell a decoder-less
  `write` from one whose fixture happens to decode: `writesTo` answers `ok(null)` for both.
- **Row 31 is the control for rows 28–30**, and row 42's sibling for the roster panel: without
  it, "renders the envelope's sentence" is satisfied by a surface that prints every `message` it
  is ever handed, `PersonAuth`'s log-facing one included.
- **Row 18's "before" assertion is its own control.** A list fixture that already contained the
  created shift would pass the "after" assertion with no reload at all.
- **Every list assertion names a value the fixture carries, and every negative assertion sits
  beside a positive one in the same body.**
- **No fixture spells a formatted instant.** Every expected string is read back out of
  `termLabel`, `instantLabel` or `shiftRoomLabel`, because each resolves the runner's timezone.

## Implementation constraints

- **Client only.** No Elixir file, no migration, no route, no `config/`. `mix` is not run, and no
  other worktree is touched.
- **No new endpoint.** All six routes are U3's, merged at `86af435`.
- **`api/client.ts` and `test-support/fake-api.ts` do not change.** U4 built `write` with a
  method, a status and an optional decoder for this unit, and `writesTo` already keys on
  `"<METHOD> <path>"`. If either has to change, the plan's KTD-E8 was wrong and this brief gets a
  revision entry saying so.
- **No number for the bound anywhere in this client.** The extent is a word. A `limit` parameter
  is what put `Rooms`' unbounded reads one forgetful caller from production.
- **No client-side sorting of any server list.**
- **`complete` is required, never defaulted.**
- **Every decoder builds its object field by field.** No spread, no `Object.assign`.
- **No clock comparison.** `instantFromLocal` converts a value a manager typed; nothing reads
  `Date.now()`, and no open/closed badge is derived from `closes_at`.
- **The test filenames must not collide** with a same-stem `.ts`, verified with
  `npx tsc --noEmit --listFiles`.
- `npm run verify` — typecheck, lint, format check, test, build — clean, and identically under
  `NODE_OPTIONS="--localstorage-file=…"` and under `TZ=UTC` and `TZ=Pacific/Kiritimati`.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 4/5 | six calls, both directions of the bound, the bodiless 204 with a control that can tell it apart, and R13 asserted through the row a client-side join cannot label. The gap is F3 step 4 — the claimant reading the room they were rostered onto — which is a second session and is browser work |
| Control discipline | 5/5 | ten controls, each named with the mutation it catches, and four of them (`0` grace, `complete` both ways, the decoder-less call, the absent-from-the-people-list row) aimed at assertions that would otherwise be vacuous |
| Regression protection | 4/5 | one disclosed regression, covered by rooms files not changing plus a mutation that must kill a body inside the rooms suite. The dynamic re-import in `room.test.ts` is the residual risk and is answered by two timezone runs rather than by a new assertion |
| Falsifiability | 4/5 | every row names a mechanism; the honest weakness is row 24, whose "no client-side sort" claim cannot catch an *ascending* re-sort and says so |
| Risk of a vacuous pass | 3/5 | named rather than argued away: row 24 above; row 20's guard is reachable only through a non-conforming input; and `writesTo` answers an unstubbed path with a `404`, so a path mutation will over-kill the way U4's mutation 10 did |

## What is not verified

**Two real browser windows.** R19 asks for the surface to be reachable in a browser without a
console and F3 step 4 asks for the claimant to read the shift room they were rostered onto. Both
need `mix phx.server` and the Postgres cluster, which this unit does not touch. Everything above
is jsdom against a fake transport.
