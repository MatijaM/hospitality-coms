# Test Design Brief — #48, person-side room lists and message history over HTTP

Issue: #48, "feat: person-side room lists and message history over HTTP".
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` through
`-18-person-zone-scope-first.md`, including the "record revisions rather than applying them
silently" section at the end.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before
implementation began. Recorded here because `AGENTS.md` requires the substitution to be visible in
the artifact rather than inferred from the absence of a review.

## What is being built

Three surfaces a worker already has context functions for and no way to reach: the list of venue
rooms they are in, the list of shift rooms they may read **at a chosen venue**, and the messages a
room already holds. All three arrive as HTTP routes on the existing `:authenticated_person`
pipeline. Two of them are lists you need *before* you have a room to ask through, which is why a
channel event could not carry them — a venue-room list cannot live on `venue_room:<id>`.

Almost none of this is new logic. `Rooms.list_venue_rooms/1`, `list_readable_shift_rooms/1`,
`list_venue_room_messages/2` and `list_shift_room_messages/2` all exist and are all authorised
correctly. What is new is one query parameter (the venue filter on the shift-room list), one
**bound** on the two message reads, and a transport.

The bound is the only part of this unit with a failure mode that is silent, and it is where the
testing weight goes.

## Decision 1 — the bound lives in the context, and it is an *extent*, not a number

Both message functions are `Repo.all/1` over every message the room ever had. A venue room is the
venue's standing conversation with full history by KTD14, so it is the one list here that grows
without limit for a single reader. `AGENTS.md`: *"Paginate every list that grows with tenant
data."*

The decided shape is: **the most recent 50 by default, with an explicit "load all".**

The argument that settles *where* the 50 lives is the issue's: a route that passes `limit: 50`
leaves the unbounded function one forgetful caller away from production, which is exactly how it
got this way. So the caller does not choose a number. It chooses one of two named extents:

```elixir
@type extent() :: :recent | :all
```

`:recent` is the default arity's behaviour, so the shortest, most obvious call is the bounded one.
`:all` is the unbounded read, still reachable, reached only because somebody typed the word. The
50 is `Rooms.recent_message_limit/0` and exists in exactly one place.

### Which means `list_venue_room_messages/2` changes behaviour, and that is disclosed rather than slipped in

⚠️ **POTENTIAL REGRESSION — disclosed before the change.**

- **Current behavior:** `Rooms.list_venue_room_messages/2` and `list_shift_room_messages/2` answer
  `{:ok, [RoomMessage.t()]}` holding the room's entire history, oldest first.
- **Proposed change:** the same arity answers `{:ok, %Rooms.MessagePage{}}` holding at most the 50
  most recent, oldest first within the page, plus `complete:` saying whether that is the lot. A new
  arity-3 takes `:all` and restores the old set.
- **What may stop working:** any caller expecting a bare list, and any caller expecting more than
  50 rows from the default arity.
- **Affected callers or surfaces:** there are **no production callers** —
  `grep -rn 'list_venue_room_messages\|list_shift_room_messages' lib/` finds only the definitions
  and the moduledoc cross-references. Twelve assertions across
  `test/hospitality_coms/rooms_test.exs` and `test/hospitality_coms/lifecycle_test.exs` destructure
  the tuple and change shape mechanically.
- **Evidence and remaining uncertainty:** none of the twelve asserts on more than three messages, so
  none of them is asserting the unbounded property. No assertion is weakened; each gains one struct
  match.
- **Safer alternative:** leave arity-2 unbounded and add `list_recent_*`. **Rejected**, and by the
  issue rather than by preference: the unbounded function would still be the one a forgetful caller
  reaches for, which is the defect this closes.
- **Regression coverage needed:** rows 1–7 below, plus every existing assertion in those two files
  continuing to hold with only its destructuring changed.

### Why a struct rather than a list, and why `complete` is not decoration

The UI needs to know whether to offer "load all", and there are only two honest ways to know: count
the rows, or ask for one more than you will return and notice. The second is one query and an exact
answer, so `MessagePage` carries `messages` and `complete`.

It also buys the property this unit is graded on. `complete` is what makes the bound *observable*:
a test at 51 messages sees `complete: false` and 50 rows, and a test at exactly 50 sees
`complete: true` and 50 rows. Without it the two are indistinguishable from outside, and a bound
nothing can distinguish is a bound nothing certifies.

`MessagePage` is a derived struct with no table, exactly as `Rooms.VenueRoom` is.

### The query has to reverse twice, and the ordering stays SQL's

"The most recent 50, oldest first within the page" is `ORDER BY sent_at DESC, id DESC LIMIT 51` in
a subquery, re-ordered ascending outside it. Not `Enum.reverse/1` over loaded rows: `AGENTS.md`
says push sorting into the database, and the outer ordering is what makes the page's own order a
property of the query rather than of the caller.

**No new index.** `create_rooms.exs` already ships
`index(:room_messages, [:venue_id, :shift_room_id, :sent_at, :id])`. The column combination is
unchanged; only the scan direction is, and a btree serves both.

## Decision 2 — the shift-room label is the shift type's name plus the term, composed on the client

`ShiftRoom` has `starts_at`, `ends_at`, `shift_type_id` and no display name, so a list of them is a
list of UUIDs. The name has to come from `shift_types`, which is one preload away
(`shift_rooms.shift_type_id` is `NOT NULL` — its composite key is `MATCH FULL`, and `CLAUDE.md`'s
rule is MATCH FULL only where no column of the key is nullable).

**A shift type's name alone does not identify a room.** Two Tuesdays of the same shift type are two
rooms with one name, so the term is part of the label whatever else is.

So the rendered shape carries `shift_type_name`, `starts_at`, `ends_at` and `closes_at`, and the
**client** composes the sentence. Two reasons, and the second is the real one:

- every other instant this client renders comes across as ISO-8601 and is formatted there
  (`room-view.tsx` renders `sentAt` verbatim today), so a server-composed string would be the one
  place a date is formatted on the wrong side;
- formatting a shift time means choosing a timezone, and the two candidates disagree. `venues`
  carries one, the worker's device carries another, and the worker is the reader. Composing on the
  device is the only spelling where that choice is made by the party who knows the answer.

`shift_type_name` rather than `name`, because it is the shift type's and a `name` key on a shift
room would claim the room has one.

**`closes_at` ships and the client must not derive open/closed from it.** The instant is the
server's — `HospitalityComs.Clock` is offsettable and the demo moves it — while a browser's clock
is real, so a client-side comparison would answer wrongly during exactly the demo the offset exists
for. It is rendered as a fact, never as a state.

## Decision 3 — the route shapes, and the one that is deliberately not nested under a venue room

```
GET /api/venue-rooms                              -> 200 {venue_rooms: [{venue_id, name}]}
GET /api/venue-rooms/:venue_id/messages           -> 200 {messages: [...], complete: bool}
GET /api/venues/:venue_id/shift-rooms             -> 200 {shift_rooms: [...]}
GET /api/shift-rooms/:shift_room_id/messages      -> 200 {messages: [...], complete: bool}
```

`?extent=all` on the two message routes is the "load all". Absent or `recent` is the bound; any
other value is `400 bad_request` rather than a silent fallback, because a client sending a word the
server does not know is a client bug worth surfacing at the client.

**The shift-room list hangs off `/api/venues/:venue_id`, not off `/api/venue-rooms/:venue_id`, and
that is KTD18 rather than taste.** A suspended person is out of the venue room and still on their
shift rosters — `Records.at_person_venues/3` deliberately does not subtract suspensions, and
`rooms_test.exs` already pins "the suspended person is absent from the venue room next to remaining
in their shift room". A path nested under the venue room would invite a membership gate in front of
it, and that gate would extend suspension to shift rooms. Nesting under the venue names the thing
shift rooms actually belong to (`shift_rooms.venue_id`) and leaves the authorisation where it is:
roster overlap intersected with an active engagement.

There is no `GET /api/venues` and there will not be one from this unit. A nested collection does
not require its parent collection to be routable, and a person's list of venues is precisely the
venue-room list, which is already the first route.

**The venue filter is a path segment, not a query parameter.** The issue asks for filtering in the
query rather than in the browser; a path segment additionally means there is no arity of the route
that spans every venue, so the unfiltered form cannot be reached by omitting something.

### The refusals are 404 and they enumerate nothing

`{:error, :not_a_member}` and `{:error, :not_found}` both become `404` with the same sentence.
That is AE1 applied to the transport: the venue-room refusal already covers an ended engagement, a
suspension in force and a venue that does not exist identically, and the shift-room refusal already
covers a room that does not exist and one this person was never rostered on. A `403` would confirm
the room exists, which is the distinction the contexts decline to make.

**A malformed id in a path is the same input as a malformed topic suffix**, and gets the same
answer. Handed straight to a context it reaches Ecto's query builder uncast and raises
`Ecto.Query.CastError`, which Phoenix renders as a 500 — so a caller could tell a malformed id from
an unknown one by the status, which is AE1 lost at the one place the id comes from outside.
`ChannelAuth.topic_id/1` is the existing spelling of that rule; its own docstring records that the
name is historical and that payload ids go through it for the same reason. The rule moves to
`HospitalityComsWeb.EntityId.cast/1` and `topic_id/1` delegates, so the three channels keep the
function they call and there is still one spelling.

### The rate limiter is not extended, and the reason is the one already in the router

`HospitalityComsWeb.LoginRateLimit` sits in front of `POST /api/log-in` alone, and the router says
why: it is "the only endpoint an anonymous caller can use to write a row and send an email". All
four new routes require a live session and write nothing. Adding them would put a shared ETS
counter in front of reads whose cost is bounded by the bound this unit is adding, and would need
the per-test IP isolation `ConnCase.with_own_remote_ip/1` exists for. Recorded as considered.

## Decision 4 — the client's shape, chosen so the profile surface can copy it

`client/src/features/profile/contract.ts` is waiting on this fork, so the layering matters more
than the four functions.

`ApiClient` gains **one** generic primitive rather than four room methods:

```ts
read<T>(path: string, sessionToken: string, decode: (body: unknown) => T | null): Promise<ApiResult<T>>
```

and the four paths, their query strings and their decoders live in
`client/src/features/rooms/rooms-api.ts`. A feature owns its wire shapes; the client owns "an
authenticated GET that decodes or fails". The profile surface adds `features/profile/profile-api.ts`
and touches `api/client.ts` not at all.

The alternative — four `venueRooms()`/`shiftRooms()`/… methods on `ApiClient` — is easier to fake
and makes `ApiClient` a grab-bag of every feature's reads by the time the profile lands its seven.

Copy for these failures is a **rooms-specific switch**, not `app/failure-message.ts`'s. That file's
`not_found` reads "That address does not exist on this server", which is right for a routing 404
and wrong for a room. It is the same split, for the same reason, that already separates
`features/rooms/refusal-message.ts` from `app/failure-message.ts`.

## Acceptance criteria

1. `GET /api/venue-rooms` answers the venue rooms `Rooms.list_venue_rooms/1` returns, by **name**.
2. `Rooms.list_readable_shift_rooms/2` exists, filters on `venue_id` **in the query**, and answers a
   subset of what `/1` answers.
3. The venue filter does not consult suspension, so a suspended person still lists that venue's
   shift rooms (KTD18).
4. `list_venue_room_messages/2` and `list_shift_room_messages/2` answer at most
   `Rooms.recent_message_limit/0` messages, and those are the **most recent** ones.
5. The page is ordered oldest-first internally, so it renders like the live stream it precedes.
6. `complete` is `false` exactly when the room holds more than the limit.
7. `:all` answers the whole history, in the order the unbounded function used to.
8. The bound is a property of `HospitalityComs.Rooms`; no route, controller or test passes a number.
9. No rendered shape on any of the four routes carries `person_id`, and message rendering is
   `RoomChannel.rendered/1` rather than a second spelling.
10. A malformed id in any path answers `404`, not `500`.
11. A room this person may not reach answers `404`, identically to one that does not exist.
12. An unauthenticated request answers `401` on all four.
13. `?extent=` with an unknown value answers `400`.
14. Shift rooms carry the shift type's name, so no list in the client is UUID prefixes.
15. Every error body is `HospitalityComsWeb.ErrorEnvelope`'s.
16. `@spec` on every public function, `Ecto.UUID.t()` for ids, error atoms enumerated.
17. Client: the room surface browses the two lists and renders history, with a "load all" control.
18. Every behavioural test proved load-bearing by mutation.

## Edge cases

- **Exactly `limit` messages.** `complete` must be `true`. This is the +1 probe's own boundary and
  the single most likely off-by-one in the unit.
- **`limit + 1` messages.** `complete` must be `false` and the *oldest* message must be absent. A
  bound that took the oldest 50 passes every count assertion and is the wrong 50.
- **Zero messages.** `{messages: [], complete: true}`, not a refusal.
- **A suspended person.** Absent from `GET /api/venue-rooms`; `404` on that venue room's messages;
  **present** on `GET /api/venues/:id/shift-rooms` and able to read a shift room's messages. Three
  answers from one state, and getting any of them wrong is KTD18 broken.
- **Two venues.** The filtered arity must answer one venue's rooms; the unfiltered arity is the
  control that proves the fixture actually had two.
- **A venue the person has no engagement at.** `shift-rooms` answers `[]` rather than `404`: the
  list's authorisation is the roster overlap, and an empty list for a venue with no rooms and for a
  venue that is not yours are the same answer, which is AE1 satisfied by construction.
- **A message sent between the history fetch and the join.** The client merges by id, so it appears
  once.
- **`extent=recent` spelled explicitly** must equal the default.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms/rooms_test.exs` | ten assertions destructure `{:ok, messages}`; all must survive with only the struct match added. The suspension and KTD14 history tests are the ones that must not change meaning |
| `test/hospitality_coms/lifecycle_test.exs` | two assertions on venue-room history after retention deletes rows |
| `test/hospitality_coms/rosters_test.exs` | two assertions on `list_readable_shift_rooms/1`; the preload must not change what matches |
| `test/hospitality_coms_web/channels/venue_room_channel_test.exs`, `shift_room_channel_test.exs` | `RoomChannel.rendered/1` is now shared with a controller; its shape is a contract in two places |
| `test/hospitality_coms_web/channels/sockets_test.exs` | `EntityId` extraction must leave `ChannelAuth.topic_id/1` behaving identically |
| `test/hospitality_coms_web/controllers/session_controller_test.exs` | the router gains a scope; the four existing routes must be untouched |
| `test/hospitality_coms/boundary_test.exs` | no schema, table or grant changes here — if this file moves, something was done that this unit did not intend |
| `client/src/features/rooms/rooms.test.tsx`, `room.test.ts`, `decode.test.ts` | the surface gains fetches; every existing behaviour (join, send, revocation, bars) must still pass |
| `client/src/api/client.test.ts` | `ApiClient` gains a member; the four existing endpoints must be untouched |
| `client/src/app/app.test.tsx`, `home-route` tests | the rooms surface now fetches on mount, so its fakes need the new member |

## Test matrix

`test/hospitality_coms/rooms_test.exs` is already `async: false` on real connections.
`test/hospitality_coms_web/controllers/room_controller_test.exs` is new and must be the same: it
reads a bridge written through `EmployerRepo` and a venue room through `Repo`, so under the sandbox
every list would come back empty and every negative assertion would pass for the wrong reason —
`profiles_test.exs`'s reason, sharpened. It pins `Clock.Offset` to the fixtures' instant, because a
controller reads the clock through `PersonAuth.fetch_person_scope/2`.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | 51 venue-room messages → 50 returned | rooms | unit | **the bound** |
| 2 | …and they are the **newest** 50: the oldest is absent, the newest present | rooms | boundary | **control for 1** — an oldest-50 bound satisfies 1 |
| 3 | …and `complete` is `false` | rooms | unit | the +1 probe |
| 4 | exactly 50 → 50 returned and `complete` is `true` | rooms | boundary | **control for 3** — `complete: false` always satisfies 3 |
| 5 | `:all` over 51 → 51 returned, `complete` `true` | rooms | boundary | **control for 1** — a bound of 50 everywhere satisfies 1 |
| 6 | the page is oldest-first internally | rooms | unit | the outer re-ordering; a desc page satisfies 1–5 |
| 7 | rows 1–6 again for a **shift** room | rooms | unit | the bound applied to one function only |
| 8 | zero messages → `{[], complete: true}` | rooms | edge | a `complete` derived from a non-empty list |
| 9 | `list_readable_shift_rooms/2` answers one venue's rooms out of two | rooms | unit | **the venue filter** |
| 10 | …and `/1` answers both | rooms | boundary | **control for 9** — a filter returning `[]` satisfies 9 |
| 11 | a suspended person still lists that venue's shift rooms | rooms | boundary | KTD18 — a membership gate on the filtered arity |
| 12 | …next to being absent from `list_venue_rooms/1` | rooms | boundary | **control for 11** — an unsuspended fixture satisfies 11 |
| 13 | every listed shift room carries a non-nil shift type name | rooms | unit | the preload |
| 14 | `GET /api/venue-rooms` renders `{venue_id, name}` and **exactly** those keys | controller | unit | the render shape; an exact key set is what stops `person_id` arriving later |
| 15 | `GET /api/venue-rooms/:id/messages` over 51 → 50 and `complete: false` | controller | integration | the bound reaching the transport |
| 16 | `?extent=all` → 51 and `complete: true` | controller | integration | **control for 15** |
| 17 | a rendered message's key set is exactly `RoomChannel.rendered/1`'s | controller | boundary | the reuse; a second spelling drifts and `person_id` is what drifts in |
| 18 | `GET /api/venues/:id/shift-rooms` renders one venue's rooms with a name, exact key set | controller | unit | the filter and the render shape |
| 19 | `GET /api/shift-rooms/:id/messages` bounded, and `?extent=all` not | controller | integration | the second bound on the transport |
| 20 | a malformed id in each of the three id-bearing paths → `404` | controller | boundary | `EntityId.cast/1`; without it this is a `500` |
| 21 | another person's venue → `404`, and their shift room → `404` | controller | boundary | the context's own authorisation reaching the route |
| 22 | all four routes without a bearer token → `401` | controller | boundary | the `:authenticated_person` pipeline |
| 23 | `?extent=sideways` → `400` | controller | edge | the enumerated parse; a fallback to `:recent` satisfies nothing |
| 24 | every error body is the envelope | controller | unit | a hand-rolled body |
| 25 | `ChannelAuth.topic_id/1` still refuses 16 raw bytes and accepts a uuid | sockets/channels | regression | the `EntityId` extraction changing behaviour |
| 26 | the four existing API routes still answer as before | session_controller | regression | a router scope that shadowed one |
| 27 | client: `read` returns the decoded value on 200 and a failure otherwise | api/client | unit | the primitive |
| 28 | client: each of the four decoders rejects a payload missing one field | rooms/decode | unit | the decoder; `undefined` in a heading is what this prevents |
| 29 | client: the venue-room list renders **names**, not ids | rooms | unit | the whole first sub-item |
| 30 | client: choosing a venue lists its shift rooms with a composed label | rooms | unit | the second sub-item |
| 31 | client: opening a room shows history before the live stream, once | rooms | unit | the third sub-item and the merge |
| 32 | client: "load all" is offered only when `complete` is `false`, and refetches | rooms | boundary | **control for 31** — an always-visible control satisfies 31 |
| 33 | client: every existing rooms behaviour still passes | rooms | regression | a surface rewrite that broke the join/send/revocation paths |

## Controls, listed explicitly

- **Row 2 controls row 1.** A bound that took the *oldest* 50 returns 50 rows and passes every count
  assertion. Naming the oldest message as absent and the newest as present is what distinguishes
  them. **This is the row the unit turns on.**
- **Row 4 controls row 3.** `complete: false` hardcoded passes row 3.
- **Row 5 controls row 1** from the other side: a limit applied to `:all` too passes row 1 and makes
  "load all" a lie.
- **Row 6 controls rows 1–5.** All five are satisfied by a page in descending order, which would
  render the room backwards.
- **Row 8 controls row 3** at the other end.
- **Row 10 controls row 9.** A filter that returns `[]` for every venue satisfies row 9.
- **Row 12 controls row 11.** A fixture whose suspension never took effect satisfies row 11.
- **Row 16 controls row 15.**
- **Row 17 controls row 14 and row 15.** Exact key sets are the only assertion that fails when a
  field is *added*, which is the direction `person_id` arrives from.
- **Row 20's control is its own positive half**: the same three paths with well-formed ids must
  answer 200, or a route that 404s unconditionally passes row 20.
- **Row 22's control** is the same four requests with a token, answering 200.
- **Row 32 controls row 31.**
- **The fixture is the control for the entire bound.** A test asserting "50 came back" against a
  fixture holding 12 passes for the wrong reason and certifies nothing —
  `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues the shape. Every bound
  assertion here is written against a fixture of **51 or more**, and the fixture helper takes the
  count so the number is visible at the call site rather than buried.

## Implementation constraints

- **The instant arrives on the scope.** No new `Clock.now/0` caller; the controller's instant comes
  from `PersonAuth.fetch_person_scope/2` on `conn.assigns.current_scope`. `.credo.exs`'s
  `:boundary_modules` must not grow.
- **No `person_id` in any rendered shape.** `CLAUDE.md` records
  `Rooms.list_venue_room_members/2` returning whole `Engagement` structs as a live disclosure; this
  unit must not add a second instance while building a list surface. Nothing here renders an
  engagement at all.
- **`Rooms.list_venue_rooms/1` and `list_readable_shift_rooms/1` apply `unsuspended/2` and
  `at_person_venues/3` respectively.** That asymmetry is KTD18 and deliberate. Do not "fix" it.
- **KTD14 is already in the shift-room query.** A person engaged today sees no room from before
  their engagement. Not redesigned, and row 33's regression set is what says so.
- **Queries live in `Rooms.Records`.** The venue filter is a parameter on the owning function, not a
  `where` rebuilt at the call site (`AGENTS.md`, "Query composition").
- **Every error body through `ErrorEnvelope`.**
- `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev **and**
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline is **1072/1076**, the four
  `PostgresRolesTest` failures being issue #20's documented `hospitality_coms_dev` condition.
- `npm run verify` from `client/` is **338 passed / 15 skipped**, and the same under
  `NODE_OPTIONS="--localstorage-file=$(mktemp)"`.
- **Never migrate `hospitality_coms_dev`.** No migration is needed by this unit at all.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | all three sub-items, at the context and at the transport |
| Control discipline | 5/5 | the bound carries four independent controls (newest-not-oldest, exactly-50, `:all`, ordering), each killing a different false pass |
| Regression protection | 4/5 | rests on ten existing files; one return type changes and is disclosed in advance with the caller count measured |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it |
| Risk of a vacuous pass | 4/5 | the 51-row fixture closes the headline one; the residue is that the client tests run against a fake API, so a path typo is caught by the decoder tests rather than by the surface |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly.
The sections above are not edited to agree with what shipped.

1. **The brief did not say which *end* of the probe batch to drop, and that is the unit's one
   silent mistake.** It said "ask for one more than you will return and notice", which is right,
   and left the page's own order to a later paragraph. Those two interact: because
   `Records.most_recent/2` re-orders **ascending** in SQL around the descending scan, the extra row
   is the **oldest** of the batch, so `MessagePage.bounded/2` has to take from the end.
   `Enum.take(rows, limit)` — the obvious spelling — returns the oldest fifty and satisfies every
   count assertion in the matrix. **Measured: mutation 1 kills five tests**, all of them because
   the first and last bodies are named rather than counted. Row 2 was the right control and the
   brief did not know how close the mistake was to the surface.

2. **The shift type could not be a `preload:` in the query.** The brief assumed it would be one.
   `Records.distinct_rooms/1` is `SELECT DISTINCT` over the joined `:room` binding rather than over
   the query's `from` source (`RosterEntry`), and Ecto refuses a preload on a query whose `from`
   binding it does not select. It is `Repo.preload/2` in `Rooms.list_readable_shift_rooms/2`
   instead — which is where `AGENTS.md` asks for preloads anyway ("in the context function"), so
   the correction lands on the standard rather than beside it. Restructuring the query so
   `ShiftRoom` were the source was the alternative and was refused: it would delete
   `distinct_rooms/1`, which exists for the rostered-removed-rostered case U6 measured.

3. **Two React hooks derive `idle` and `loading` rather than storing them**, which the brief did
   not anticipate and which is `use-room.ts`'s recorded rule arriving from the linter:
   `react-hooks/set-state-in-effect` refuses a synchronous `setState` in an effect body. The only
   write in either hook now happens in the promise's callback and carries the request it answers;
   anything else is derived. That is strictly better than what the brief implied — a stale answer
   is now *unrenderable* rather than merely discarded, because the stamp will not match.

4. **The browse panel's status lines are `aria-live="polite"`, not `role="status"`.** Two reasons
   and both are stated because only the first is a design argument: this screen already has exactly
   one thing whose state a worker is waiting on — the open room — and two competing `status`
   regions make the important one harder to find. The second is mechanical: `app.test.tsx` and
   `rooms.test.tsx` both call `findByRole("status")` **singularly**, so a second `status` region
   would have broken six existing tests for a reason that has nothing to do with what they assert.
   `aria-live` without the role announces identically and matches neither query.

5. **One existing test's text sentinel changed.** `app.test.tsx` identifies the rooms surface by
   `/no rooms yet\. add one by its id/i`, and the empty local list now points at the browse list
   above it ("Open one from the list above, or add one by its id"). The regex moved and gained a
   comment saying why. No assertion is added, removed or weakened; six tests use it and all six
   assert the same things.

6. **Rows do not map one-to-one onto test bodies**, as U8, U9, U10 and #18 all recorded. Thirty-three
   rows became **twenty-six** new Elixir bodies (twelve in `rooms_test.exs`, fifteen in the new
   `room_controller_test.exs`, minus overlap) and **twenty-nine** new client bodies across five
   files, one of them new (`room-lists.test.tsx`).

7. **Row 20's malformed-id claim splits across two files and the brief only named one.** Measured:
   dropping `byte_size(id) == 36` from `EntityId.cast/1` kills **one** test in
   `room_controller_test.exs` (the sixteen-raw-bytes path) and **one** in
   `test/hospitality_coms_web/channels/`. Row 25 predicted the second and the brief filed it as a
   regression risk rather than as coverage; it is coverage, and the delegation is what makes both
   true at once.

8. **Baseline arithmetic.** Elixir: **1072/1076** before, **1098/1102** after — twenty-six new
   bodies, and the same four `PostgresRolesTest` failures naming `hospitality_coms_dev`
   (issue #20). Client: **338 passed / 15 skipped** before, **367 / 15** after, identical under
   `NODE_OPTIONS="--localstorage-file=$(mktemp)"`.

## Mutation record

Twenty-seven mutations, each applied to a clean tree, measured against the narrowest file that
could answer, then restored. Every new behavioural test is killed by at least one.

| # | Mutation | Tests killed |
|---|----------|--------------|
| 1 | `MessagePage.bounded/2` takes the page from the **front** | 5 |
| 2 | `MessagePage.bounded/2` hardcodes `complete: false` | 2 |
| 3 | `Records.most_recent/2` drops the outer ascending order | 5 |
| 4 | `Rooms.page/2` bounds `:all` as well | 2 |
| 5 | `Rooms.page/2` asks for `limit` rather than `limit + 1` | 2 |
| 6 | `Records.readable_shift_rooms/3` ignores the venue | 1 |
| 7 | `Rooms` drops the shift-type preload | 4 |
| 8 | `list_readable_shift_rooms/2` gates on venue-room membership (KTD18 broken) | 2 |
| 9 | `EntityId.cast/1` drops the byte-size guard | 2 (one controller, one channel) |
| 10 | `RoomController.extent/1` falls back to `:recent` for an unknown word | 1 |
| 11 | `RoomController` answers a refusal `403` rather than `404` | 4 |
| 12 | `render_message/1` grows a field | 1 |
| 13 | `render_venue_room/1` loses the name | 1 |
| 14 | `venues_of_person/2` stops applying `unsuspended/2` (KTD18, other side) | 3 |
| 15 | the venue-room list renders the id instead of the name | 1 |
| 16 | `shiftRoomLabel` drops the shift type's name | 3 |
| 17 | `shiftRoomLabel` drops the term | 2 |
| 18 | the shift-room panel fetches on mount rather than on choosing | 2 |
| 19 | the history control is offered whatever `complete` says | 2 |
| 20 | `loadAll` keeps asking for the recent extent | 1 |
| 21 | the room renders only the live stream, never the fetched history | 4 |
| 22 | `mergeMessages` concatenates without keying on the id | 1 |
| 23 | a failed list renders as an empty list rather than as a failure | 1 |
| 24 | `decodeMessagePage` defaults `complete` to `true` when absent | 1 |
| 25 | `decodeEach` drops entries it cannot read instead of failing the body | 3 |
| 26 | `ApiClient.read` accepts a status other than 200 | 2 |
| 27 | `rooms-api` asks an unfiltered shift-room path | 2 |

**Mutations 1, 3 and 21 are the ones worth reading twice.** The first two are the bound's two
silent failure modes — the wrong fifty, and the right fifty in the wrong order — and both leave
every count assertion green. The third is the whole third sub-item: rendering only the live stream
is what the surface did before this branch, and it is a change a refactor could undo without any
test noticing unless one asserts on a message nobody sent during the test.

Two things are deliberately **not** asserted. Nothing pins the number fifty from the client side —
`recent_message_limit/0` is the server's and a client that knew it would be a second place for it
to be wrong. And no test asserts that `?limit=` is refused, because there is no such parameter to
refuse: its absence is the design, and a test for the absence of a feature would pass for ever
whether or not anything guarded it.
