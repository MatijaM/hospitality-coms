# Test Design Brief — #66, a display name each worker is given and can change

Issue: #66, "feat: a display name each worker is given and can change". Supersedes the cheap half
of #65 (attribute chat messages by role label).
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` onward, including the
"record revisions rather than applying them silently" section at the end.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began. Recorded here because `AGENTS.md` requires the substitution to be visible in the artifact
rather than inferred from the absence of a review.

## What is being built

`people` has exactly one identifying column, `email`, and no name column anywhere. So a venue room
attributes a message to `author_engagement_id` and the client renders `shortId(...)` — the first
eight characters of a UUID. A chat where you cannot tell who spoke is not a chat.

Every person is **given** a display name at registration — a public-domain fictional character —
and can **change** it. That name is what a room message carries, what the peer list carries, and
what `GET /api/me` carries.

A column on `people` is **person zone**, so `employer_role` can never read it and the existing
privilege sweep already proves that with no new rule. What the unit has to get right is three
things the boundary does *not* give for free: erasure must overwrite it, the name must reach a
message whose author's engagement has closed, and a globally stable readable name is a correlation
key that has to be written down rather than discovered.

## Decision 1 — collisions are allowed, and uniqueness is refused on a privacy argument rather than a cost one

Two people can be given the same character. Three options were open: allow it with the engagement
id alongside as the disambiguator; append a discriminator; enforce uniqueness with an index and a
retry loop at registration.

**Allow it.** The cheap argument is the issue's own — the roll already carries the engagement id,
and a name is not an authorisation. The argument that actually settles it is the opposite of a cost
argument:

> A **unique** readable name is a perfect global identifier. A colliding one is not.

`CLAUDE.md`'s standing disclosure is that `engagements.person_id` is globally stable and two venues
comparing ids out of band can determine that the same human works at both. A globally unique
display name would be a second such key, in plain text, readable by every worker rather than only
by somebody with database access. Collisions are the only thing that stops "Captain Nemo" being as
good as a person id. So uniqueness is refused, and the id stays beside the name wherever attribution
matters: the client renders `Captain Nemo · 4a3f1b2c`, which is #65's `Bartender · 4444…` shape
with a chosen name in place of an employer-authored label.

Sixty-four names, so two people at one small venue colliding is unlikely and two at a large one is
ordinary — and the render is honest about it either way.

## Decision 2 — the name reaches a message from the server, on `RoomChannel.rendered/1`

Two options, both from #65 unchanged. The ended-engagement case decides it and there is no second
consideration worth weighing against it.

A venue room keeps **full history** (R14, KTD14), and `Rooms.list_venue_room_members/2` is the
venue's *active* engagements. So a message whose author's engagement closed last month is normal
rather than rare, and a client-side join against the current roll has nothing to find for it. That
is the same hole `Rosters.list_roster/2` already had to close by preloading the engagement (#60's
"next Monday's starter renders as a bare UUID"), arriving from the other end of the term.

So the server carries it: `room_messages` gains no column — the name lives on `people` and is joined
on the read — and `RoomChannel.rendered/1` gains `author_display_name`. Concretely:

- `RoomMessage` gains a **virtual** field `author_display_name`. No stored column: a stored copy
  would be a denormalised name that a rename does not reach, and there is no read path that cannot
  afford the join.
- `Rooms.Records.with_author_display_name/1` joins `room_messages → engagements → people` and
  `select_merge`s the name. It is applied by the person-side read paths only, as the **last** step,
  outside `most_recent/2`'s subquery.
- The **send** path sets it from the scope, not from a query: the author is the scope's person by
  construction, because the engagement was resolved from that scope. So the hot path pays nothing.

`RoomController.render_message/1` already calls `RoomChannel.rendered/1` rather than restating it,
so both transports and both room kinds move together. That is the whole reason the extraction
exists and this unit is the first to test it.

## Decision 3 — the peer list carries it; the peer *conversation* deliberately does not

`Peers.list_visible_peers/1` carries the counterpart's `person_id`, the shared venue and the
employer-authored `role_label`, and `peers_test.exs:307` asserts it carries no email. **The display
name goes on it.** It is strictly less identifying than the `person_id` already there, it is what
makes that list readable at all, and the audience is exactly the audience the venue room's roll
already discloses to.

**`Peers.Conversation` does not get one, and that is a scope decision with a named remedy.** The
same ended-relationship argument applies — a connection outlives the visibility that produced it
(R13), so a client-side join against `list_peers` has the same hole a room's roll has — but closing
it is a `Peers` shape change rather than a rendering one: `Conversation` is built by
`Conversation.of_connection/2` from a `Connection` struct, and the counterpart is not known until
that function runs, so the name has to arrive either as a second keyed read in `list_conversations/1`
and `fetch_conversation/2`, or by changing what `Records.connections_of/1` and `connection_of/2`
select — which four other callers share. The issue names `list_visible_peers/1` and no other peer
surface. **Residue on the record:** a peer conversation still renders the counterpart as a shortened
`person_id`, and the follow-on is `Conversation` gaining `peer_display_name` resolved by one extra
keyed read rather than by widening the four-caller query.

## Decision 4 — the change control is `PATCH /api/me`, in a new `PersonController`

`/profile` cannot connect: `client/src/features/profile/contract.ts` exists precisely because no
channel on the server answers any profile event, and nothing has changed that. So the control must
go somewhere reachable today. #48 established HTTP for person-side reads and #61 added
`ApiClient.write`, whose `WriteMethod` already includes `PATCH`.

`GET /api/me` already returns the person. `PATCH /api/me` changing that same person is the same
resource, so it is one controller rather than two on one path.

**`GET /api/me` moves from `SessionController` to a new `HospitalityComsWeb.PersonController`**, and
`SessionController` calls `PersonController.rendered/1` for the person it puts in the redemption
reply. That is `RoomChannel.rendered/1`'s and `RoomController.rendered_shift_room/1`'s precedent
exactly — one entity, one shape, public so the second caller calls it rather than copying it. It
also makes the two module names true: `SessionController` is about the session, and what `/api/me`
returns is a person.

⚠️ **POTENTIAL REGRESSION — disclosed before the change.**

- **Current behavior:** `GET /api/me` is served by `SessionController.show/2`.
- **Proposed change:** the same route, same pipeline, same response shape plus one key, served by
  `PersonController.show/2`.
- **What may stop working:** anything asserting the controller module rather than the route.
- **Affected callers or surfaces:** `test/hospitality_coms_web/controllers/session_controller_test.exs`
  reaches it through `~p"/api/me"` and `Phoenix.Router.route_info/4` only; neither names the
  controller. The client reaches it through `ApiClient.currentPerson`, which is a path.
- **Evidence and remaining uncertainty:** none of the existing `/api/me` assertions changes meaning.
  The response gains `display_name`, which the client's `decodePerson` will then *require* — that is
  the intended change and it is row 24 below.
- **Safer alternative:** leave `show` where it is and put `update` in the new controller. **Rejected**
  — one resource split across two controllers on one path is worse than a module boundary that reads
  correctly.
- **Regression coverage needed:** rows 22–27, plus every existing `session_controller_test.exs`
  assertion continuing to hold.

## Decision 5 — erasure overwrites it, and there is **no** parallel check constraint

`Records.pseudonymise/2` sets `email: nil, erased_at, updated_at`. It will also set
`display_name: Lifecycle.erased_display_name()`. A display name left behind is an identifying value
surviving erasure, which breaks KTD15 outright.

The question the issue asks is whether it needs a rule parallel to `people_erased_email_removed`
and `people_present_email_required`. **No**, and three things say so rather than one:

1. **Those two constraints are about presence and absence, coupled to a partial unique index.**
   `people_email_index` is partial on `WHERE erased_at IS NULL`, so an erased row that kept its
   address would keep *occupying* it. The constraints are what make that index coherent.
   `display_name` has no unique index and no such coupling, by Decision 1.
2. **The tree already has this exact case and answers it the same way.** `engagements.role_label` is
   overwritten with `Lifecycle.erased_label()` by `Records.reduce_labels/3` at erasure and carries no
   check constraint. The guard there is `lifecycle_test.exs`, which is the guard here.
3. **A CHECK on this column would have to pin a *value*.** `erased_at IS NULL OR display_name = 'Former colleague'`
   puts a UI string in a migration, which is issue #42's defect class, and buys a guarantee against a
   failure mode — "the erasure forgot to overwrite it" — that a `NOT NULL` column plus the whole-row
   comparison already covers.

**The CHECK was available and its cost was one row in `constant_agreement_test.exs`.** Recorded as
declined rather than not considered.

What the migration *does* carry is `people_display_name_present` and
`people_display_name_within_bound`, `room_messages`' two constraints applied one table over. Those
are not about erasure; they are about the fact that erasure writes this column with `update_all`,
which meets no changeset — the same reason `room_messages_body_within_bound` exists for
`insert_all`. The bound gets a `constant_agreement_test.exs` row.

### How the existing whole-row test catches a miss, and how it is extended deliberately

`test/hospitality_coms/lifecycle_test.exs`, "changes those two columns and leaves every other one
alone":

```elixir
changed = for {field, value} <- before, Map.fetch!(erased, field) != value, do: field
assert Enum.sort(changed) == [:email, :erased_at, :updated_at]
```

Adding the column and overwriting it makes `changed` hold `:display_name` and the assertion fails —
which is the guard working. It is extended rather than patched: the literal grows to
`[:display_name, :email, :erased_at, :updated_at]`, `erased.display_name` is asserted **equal to**
`Lifecycle.erased_display_name()`, and the person's name is **set to a known value first** so that
"changed" is not satisfied by the generator having happened to produce the erased name. That last
part is the same trap the file already documents about `confirmed_at`: a field that was already the
target value is invisible to a diff.

`Lifecycle.erased_display_name/0` is `"Former colleague"` and is a **separate constant** from
`erased_label/0`'s `"Former team member"`. No relation is asserted between them: one is what an
employer wrote about a job, the other is what a person called themselves, and #42's rule is that a
linking sentence between two numbers nothing checks is how they drift.

## Decision 6 — the generated name, and where it is generated

`HospitalityComs.Accounts.DisplayName` holds sixty-four public-domain literary characters —
Captain Nemo, Wendy Darling, Ebenezer Scrooge, Puck. Two properties are required and both are
assertable: **every name must read as unmistakably fictional**, so nobody looking at the demo
believes they are seeing a real person's identity; and none may be a living person's name.
Public domain also means the list cannot become a licensing question.

`Accounts.register_person/2` assigns one through `Person.registration_changeset/3`, so every path
that makes a person gets one — the log-in door, every fixture, and `Demo.seed/0`, none of which
changes. The demo's four people therefore get random names, which is the feature demonstrating
itself; nothing in `demo_test.exs`'s manifest names a person by anything but an address.

The migration backfills existing rows in **one statement**, deterministic on `md5(id)`, with the
name list passed as a bind parameter read from `DisplayName.all/0` — so the list exists once rather
than once in `lib/` and once in a migration. Reading a `lib` value from a migration has a precedent
in this tree (`*_create_employer_login_role.exs` reads `EmployerRepo.config/0`). It is a backfill
source and not a schema literal, so it is not `constant_agreement_test.exs`'s business.

## Decision 7 — the disclosure, stated before it is built

**A globally stable readable name is a correlation key across venues, in the way `person_id` already
is.** It reaches no employer — `people` is person zone, `employer_role` holds nothing on it, and no
employer-facing render carries it — so this is worker-to-worker.

The sharp form, which is more than "it makes an existing disclosure legible":

> `room_messages.author_engagement_id` is **venue-local by construction** (KTD15b). A rendered
> message now carries a **globally stable** name beside it. So a worker engaged at two venues, in
> both venue rooms, can tell from the *messages alone* that the same human speaks in both.

That capability already existed by another route — `Rooms.list_venue_room_members/2` hands every
member the `person_id` of every other member, which `CLAUDE.md` records as a live disclosure — so
what changes is that it no longer needs a join. It is recorded in `Person`'s moduledoc, in
`RoomChannel.rendered/1`'s, and in `CLAUDE.md`'s "disclosures on the record", rather than left to be
discovered.

**And it is why `display_name` must never become an employer render.** No column grant, no view
column, nothing on `EmployerController`. The existing sweep is what enforces it and this unit
verifies rather than assumes that.

## Acceptance criteria

1. Every person created by any path holds a non-null `display_name` drawn from `DisplayName.all/0`.
2. `Accounts.update_display_name/2` changes it, trims it, refuses blank and refuses over-bound, and
   refuses an erased person by an enumerated atom.
3. `people.display_name` is `NOT NULL` with a presence CHECK and a bound CHECK, and the bound agrees
   with `DisplayName.max_length/0` in `constant_agreement_test.exs`.
4. Erasure overwrites it with `Lifecycle.erased_display_name/0`, and the whole-row comparison in
   `lifecycle_test.exs` names exactly `[:display_name, :email, :erased_at, :updated_at]`.
5. `RoomChannel.rendered/1` carries `author_display_name`, on the channel push, the channel reply and
   the HTTP history, for both room kinds, with one key set.
6. A message whose author's engagement has **ended** still carries the author's name.
7. A message whose author has been **erased** carries `Lifecycle.erased_display_name/0`.
8. `Peers.list_visible_peers/1` carries `display_name` and still carries no email.
9. `GET /api/me` carries `display_name`; `PATCH /api/me` changes it and answers the same shape.
10. `employer_role` holds no privilege on `people`, table or column, after the migration.
11. The client renders the name in a venue room, in a shift room and in the peer list, and offers a
    control that changes it.

## Edge cases

- A name of only whitespace — trimmed to empty, refused by the changeset and by the CHECK.
- A name at exactly the bound and one over it.
- A message written by a person who is later erased: the *message* is untouched (KTD15c) and the
  *name* comes off the joined row, so the same message renders differently before and after. That is
  the point of joining rather than storing, and it needs a test in both directions.
- A message whose author's engagement ended — the join is to `engagements` and then `people`, with no
  activeness predicate anywhere, which is what makes this work.
- Two people with the same generated name in one room.
- `PATCH /api/me` with no `display_name` key at all — `400`, not `422`: "you did not name the thing"
  and "the thing you named is not acceptable" are two different mistakes (#60's shape).
- `display_name` is **not** added to `config :phoenix, :filter_parameters`. The list is an allowlist
  since #53, so a name in a request body prints as `[FILTERED]` by default, and `AGENTS.md`'s
  avoid-list names `first_name`/`last_name`/`full_name` explicitly. Adding it would be the bug.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms/lifecycle_test.exs` | the whole-row comparison **will** fail and must be extended, not patched. It is the guard this unit is graded on |
| `test/hospitality_coms/accounts/person_zone_test.exs` | `calls/1` is swept against `Accounts.__info__(:functions)`; a new export with no row fails "covers every export but the one that reaches no repo" |
| `test/hospitality_coms/constant_agreement_test.exs` | a new CHECK bound with no row is a bound nothing checks |
| `test/hospitality_coms_web/controllers/room_controller_test.exs` | `@message_keys` is a literal and must gain the key, never relax |
| `test/hospitality_coms_web/channels/peer_channel_test.exs` | exact key sets against literals |
| `test/hospitality_coms_web/channels/venue_room_channel_test.exs`, `shift_room_channel_test.exs` | the rendered message shape on the push and the reply |
| `test/hospitality_coms/peers_test.exs` | the "discloses no email address in the peer list" assertion must survive unchanged and unweakened |
| `test/hospitality_coms/boundary_test.exs` | `people` gains a column; the person-zone sweep must still find nothing, and `Repo.all(Person) == []` still holds |
| `test/hospitality_coms/rooms_test.exs` | every message read gains a join; ordering, bounds and `complete` must be untouched |
| `test/hospitality_coms/demo_test.exs` | `Demo.seed/0` writes people through `Accounts`; the manifest must not move |
| `test/hospitality_coms_web/controllers/session_controller_test.exs` | `/api/me` changes controller and gains a key |
| `client/src/api/decode.test.ts` + every fixture built on `somePerson` | `decodePerson` gains a required field, so every person fixture missing it becomes `malformed_response` |
| `client/src/features/rooms/decode.test.ts`, `rooms.test.tsx` | `decodeRoomMessage` gains a required field |
| `client/src/features/peers/decode.test.ts`, `peers.test.tsx` | `decodePeer` gains a required field |
| `client/src/app/app.test.tsx`, `session-bar` consumers | the session bar gains a control on three screens |

## Test matrix

`rooms_test.exs`, `peers_test.exs`, `lifecycle_test.exs`, `room_controller_test.exs` and the two
room channel files are already non-sandboxed on real connections; nothing about that changes. The
new `person_controller_test.exs` **can** be sandboxed — it touches `people` alone through `Repo` and
no employer read — and is, which is the first controller test in the tree that may be.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | a registered person holds a name from `DisplayName.all/0` | accounts | unit | **the generator in `registration_changeset/3`** |
| 2 | …and it is not the erased name | accounts | boundary | **control for 1** — a generator returning the erased constant satisfies 1 and makes row 12 vacuous |
| 3 | every name in the list is within the bound and the list has no duplicate | display_name | unit | a list edit that breaks the CHECK at registration |
| 4 | `update_display_name/2` changes it and answers the person | accounts | unit | the write |
| 5 | …trims surrounding whitespace | accounts | edge | `update_change(:display_name, &String.trim/1)` |
| 6 | …refuses `"   "` with a changeset | accounts | edge | `validate_required` after the trim |
| 7 | …accepts exactly `max_length` and refuses one over | accounts | boundary | `validate_length` |
| 8 | …refuses an erased person with `{:error, :erased}` | accounts | boundary | the second head; without it erasure's overwrite is reversible |
| 9 | the CHECK refuses a blank written past the changeset (`update_all`) | person | boundary | `people_display_name_present`; the changeset alone satisfies rows 5–6 |
| 10 | the CHECK refuses an over-bound value written past the changeset | person | boundary | `people_display_name_within_bound` |
| 11 | the migration's bound equals `DisplayName.max_length/0` | constant_agreement | unit | the two numbers drifting |
| 12 | erasure sets `display_name` to `erased_display_name/0` | lifecycle | unit | **the overwrite in `pseudonymise/2`** |
| 13 | …and the whole-row diff is exactly the four fields | lifecycle | boundary | **control for 12** — an erasure that also nulled `confirmed_at` passes 12 |
| 14 | …with the name set to a known value first | lifecycle | boundary | **control for 12 and 13** — a person already named the erased name is invisible to a diff |
| 15 | a venue-room message read over HTTP carries the author's name | rooms | unit | **the join** |
| 16 | …whose author's **engagement has ended** | rooms | boundary | **control for 15** — a join through the *active* roll satisfies 15 and is the whole of Decision 2 |
| 17 | …whose author has been **erased** carries the erased name | rooms | boundary | the join being to `people` rather than a stored copy |
| 18 | a shift-room message carries it too | rooms | unit | the join applied to one read only |
| 19 | two people with one name are still told apart by `author_engagement_id` | rooms | edge | **control for Decision 1** — the id being dropped from the render |
| 20 | `GET .../messages` renders exactly `@message_keys` + the new key | room_controller | boundary | an exact key set; the direction `person_id` arrives from |
| 21 | the channel push and the channel reply carry the same key set as the HTTP read | venue/shift channel | boundary | `RoomChannel.rendered/1` being the single spelling |
| 22 | `GET /api/me` carries `display_name` | person_controller | unit | the render |
| 23 | `PATCH /api/me` changes it and answers the same key set | person_controller | unit | the route |
| 24 | …and a later `GET /api/me` shows the new name | person_controller | boundary | **control for 23** — a route answering the body it was handed satisfies 23 |
| 25 | `PATCH` with no `display_name` → `400`; with a blank one → `422` with `fields` | person_controller | edge | the two-mistake split; both are envelope bodies |
| 26 | `PATCH` without a bearer token → `401` | person_controller | boundary | the `:authenticated_person` pipeline |
| 27 | the redemption reply's person carries the same key set as `GET /api/me` | session_controller | boundary | `PersonController.rendered/1` being called rather than copied |
| 28 | `list_visible_peers/1` carries the counterpart's `display_name` | peers | unit | the join in `visible_peers/2` |
| 29 | …and still no email, by value and by key | peers | boundary | **the existing control, unweakened** |
| 30 | …and two stints at one venue merge to one entry carrying it | peers | edge | `merge_stints/1` losing the field |
| 31 | `PeerChannel` `list_peers` renders exactly its key set + the new key | peer_channel | boundary | an exact key set |
| 32 | `employer_role` holds no privilege on `people` after the migration | boundary | boundary | the migration granting something |
| 33 | …and a column grant on `display_name` specifically is caught | boundary | boundary | **control for 32** — `has_table_privilege` alone misses a column grant |
| 34 | client: `decodePerson` refuses a payload with no `display_name` | api/decode | unit | the decoder |
| 35 | client: `decodeRoomMessage` refuses one with no `author_display_name` | rooms/decode | unit | the decoder |
| 36 | client: `decodePeer` refuses one with no `display_name` | peers/decode | unit | the decoder |
| 37 | client: a venue room renders the author's name, not a short id | rooms | unit | the render |
| 38 | …and still renders "You" for your own messages | rooms | boundary | **control for 37** — rendering the name for everybody satisfies 37 |
| 39 | client: the peer list renders the counterpart's name | peers | unit | the render |
| 40 | client: the session bar shows your name and a control that changes it | session-bar | unit | the whole of the change surface |
| 41 | client: saving sends `PATCH /api/me` with exactly `{display_name}` | session-bar | boundary | the request shape; asserted against a literal |
| 42 | client: a refused save shows a failure and keeps the old name | session-bar | boundary | **control for 40** — an optimistic render satisfies 40 |

## Controls, listed explicitly

- **Row 2 controls row 1 and protects row 12.** A generator that returned the erased constant
  satisfies row 1, and then row 12 is asserting a value the person already had.
- **Row 13 controls row 12.** This is the existing control in `lifecycle_test.exs`, extended rather
  than replaced: without the whole-row diff, an erasure that also destroyed `confirmed_at` passes.
- **Row 14 controls rows 12 and 13 together**, and is the one this unit adds. A diff cannot see a
  field that was already the target value, which is exactly the trap the file documents about
  `confirmed_at` and exactly what a random generator makes possible.
- **Row 16 controls row 15, and it is the row the unit turns on.** A join through the venue room's
  *active* roll satisfies row 15 completely and produces `nil` for every historical message. If row
  16 cannot be made to fail by joining through the roll, the fixture is wrong.
- **Row 19 controls Decision 1.** Dropping the id from the render satisfies rows 15–18.
- **Rows 20, 21 and 31 are exact key sets**, which are the only assertions that fail when a field is
  *added* — the direction `person_id` arrives from.
- **Row 24 controls row 23.** A `PATCH` that echoed its own body would pass row 23.
- **Row 27 controls the "one shape" claim.** Two spellings of a person is the defect class this tree
  has fixed three times.
- **Row 29 is the existing control and must not move.** `peers_test.exs:307` asserts both that no
  value equals the address and that no key is named `email`; a new field beside it is exactly the
  change that would tempt somebody to relax it.
- **Row 33 controls row 32.** `has_table_privilege` answers false for a column grant, and the sweep
  asks both; this unit adds the first new column to `people` since U2, so the pair is worth
  exercising once rather than assumed.
- **Row 38 controls row 37**, and **row 42 controls row 40**.
- **Row 9 and row 10 control rows 5–7.** A changeset-only bound is satisfied by every row in the
  matrix and is defeated by the one write in the tree that meets no changeset — erasure's own.

## Implementation constraints

- **The clock rule.** No new `Clock.now/0` caller. `.credo.exs`'s `:boundary_modules` must not grow.
  `Person.registration_changeset/3` and `display_name_changeset/3` take the unit of work's instant
  and stamp `updated_at` from it, as every other `Person` changeset does.
- **`@spec` on every public function, with enumerated error atoms**, never `{:error, term()}`.
- **Migrations only via `mix ecto.gen.migration`, with a reversible `down`.** The `down` drops the
  column and the two CHECKs; a rollback loses every name, which the migration's moduledoc must say.
- **Every refusal through `ErrorEnvelope`.**
- **Queries live in `Records`.** `Rooms.Records` owns the message join; `Peers.Records` owns the peer
  join and `peers_test.exs` pins that structurally out of the compiled `imports` chunk.
- **`RoomChannel.rendered/1` is the single spelling of a message.** The change happens there and
  nowhere else.
- **Never migrate `hospitality_coms_dev`.**
- Gates: `mix format --check-formatted`, `mix compile --force --warnings-as-errors` in dev **and**
  `MIX_ENV=prod`, `mix quality`, `mix test`. Baseline is **1199/1203**, the four `PostgresRolesTest`
  failures being issue #20's documented `hospitality_coms_dev` condition.
- Client: `npm run verify`, and the same run under `NODE_OPTIONS="--localstorage-file=$(mktemp)"`
  with an identical count.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | column, generator, change control, erasure, both chats' lists, both transports, client |
| Control discipline | 5/5 | the erasure claim carries three stacked controls (whole-row, known-value-first, generator-is-not-the-erased-name), and the message join carries the ended-engagement row that a wrong implementation passes without |
| Regression protection | 4/5 | fifteen existing files named; two will fail by design and are extended rather than patched |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it |
| Risk of a vacuous pass | 4/5 | the residue is row 3 — a list-content assertion is a property of a literal, so it certifies the list is well-formed and cannot certify that the names read as fictional. That last property is a human judgement and is stated as one |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly. The
sections above are not edited to agree with what shipped.
