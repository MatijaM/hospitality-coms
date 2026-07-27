# Test Design Brief — U8, Peer graph

Issue: #8. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U8.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written before any production
code; the orchestrator stands in for the human approver (issue #21 tracks the missing
skill). Convention established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md`,
`-u6-rooms-and-derived-membership.md` and `-u7-realtime-transport-and-revocation.md`.

## What is being built

Three person-zone tables — `connection_requests`, `peer_connections`, `peer_messages` —
a derived visibility interval that nothing stores, the full request state machine including
a state that exists only because time moved, 1:1 conversations multiplexed through the one
`"peer"` channel U7 left empty, and a unilateral disconnect that closes the conversation for
both parties while leaving each of them their own words.

**The employer is absent from all of it, and that absence is the unit.** Not one of these
tables carries a venue key, `employer_role` holds no privilege on any of them,
`HospitalityComs.EmployerRepo`'s query backstop refuses any employer query that reaches
one, `EmployerSocket` routes no `"peer"` topic, and no function in
`HospitalityComs.Peers` accepts an `EmployerScope`. AE1 is the acceptance example this unit
is the far end of: "a manager authenticated for one venue and the identifier of a peer
conversation between two of its staff" is precisely the shape asserted below.

## Acceptance criteria

1. **Visibility is a derived interval per pair per venue, and nothing stores it.** Two
   people are visible to each other at a venue when their engagements there overlap; the
   interval runs `[max(starts), min(ends) + 30 days)`, half-open like everything else
   (KTD4). The tail starts at **the first of the two engagements to end**, not the last.
   Advancing the clock lapses visibility with no job having run and no row having changed.
2. **The request state machine is one row per pair, and the row says which state.**
   `pending`, `accepted`, `declined`, and `lapsed` — the last derived from visibility at the
   asking instant rather than stored, which is why "a pending request expires when
   visibility lapses" needs no sweeper and no column.
3. **KTD19's block is directional and survives new co-rostering.** It is a
   `blocked_initiator_id` column on `connection_requests`, so it is a fact about the pair's
   history rather than about anybody's current employment. A decline blocks the requester; a
   disconnect blocks the counterpart of the disconnector. The other party keeps the
   initiative in both cases, which is the whole of the KTD: read symmetrically the phrase
   makes Declined absorbing, and disconnection is the origin's only stated remedy for harm.
4. **Exactly one connection per pair can be live, and the database says so**, not the
   context: a partial unique index on the pair. Crossed simultaneous requests therefore
   cannot produce two.
5. **A connection outlives the visibility that produced it.** Visibility gates discovery and
   requests; it gates nothing about a conversation that already exists. Both engagements
   ending leaves the conversation open.
6. **Disconnect is unilateral and closes the conversation for both**, and afterwards each
   party reads their own messages and only their own. Nothing is deleted — deletion is
   `Lifecycle`'s alone (KTD21).
7. **KTD10 — conversations multiplex.** One `"peer"` channel carries every conversation;
   every event names its conversation in the payload and never in the topic. No
   per-conversation topic exists for a later unit to copy into an employer socket's table.
8. **The three tables are person zone**, because they name people. KTD2 permits exactly one
   crossing and it is `engagements.person_id`; a peer table outside the person zone would be
   a second one. `boundary_test.exs`'s positive form — `engagements` is the *only* table
   outside the person zone with a foreign key to `people` — must still return exactly
   `["engagements"]` with these tables present and populated.
9. **KTD5 — the instant arrives on the scope.** No new module calls `Clock.now/0`;
   `:boundary_modules` is unchanged. Every `Records` predicate takes the instant explicitly,
   and `ago/2`/`from_now/2` stay banned.
10. **No `{:error, term()}`.** Every refusal is an enumerated atom or a changeset, and every
    refusal about an id the caller supplied is `:not_found` — a peer graph that told a
    caller their id named something real would enumerate the application's conversations one
    probe at a time.

## The two things that are derived, and why each has to be

**Visibility.** A stored `visible_until` would be a cached authorization decision, which is
the failure the whole design exists to prevent — the plan's Problem Frame says so in its
second paragraph and U5, U6 and U7 have each declined to store one. It would also be wrong
almost immediately: an engagement's `ends_at` is mutable (renewal moves it forward, ending
moves it back), so a materialised tail would be stale from the first renewal and a job that
refreshed it would inherit KTD6b's whole failure class.

**The `lapsed` request state.** A pending request whose pair has stopped being visible is
lapsed, and the requester is told so. Storing it needs a sweeper that visits every pending
request whenever any engagement ends; deriving it needs the instant the caller already
carries. The same clock advance that lapses the visibility lapses the request, in the same
query, with nothing having run.

## The block, stated precisely

One `connection_requests` row is *current* for a pair at any time — `superseded_at IS NULL`,
guaranteed by a partial unique index on the pair. A new request supersedes the previous
current row in the same `Ecto.Multi` that writes it. So the pair's whole state is one row,
and "who may initiate next" is read off it rather than off an ordering:

| Current row | Who may initiate |
|---|---|
| none | either |
| pending | neither (one is outstanding) |
| pending, lapsed | either — the visibility that carried it is gone |
| declined | anyone who is not its `blocked_initiator_id`, which is the requester |
| accepted, connection live | neither (they are connected) |
| accepted, connection closed | anyone who is not its `blocked_initiator_id`, which is the counterpart of whoever disconnected |

"Without fresh acceptance" is the last row read forwards: the blocked party cannot
*initiate*, and can be connected again the moment the other party asks and they accept — at
which point a new current row exists and the old block is not consulted again. That is why
the block is read off the current row rather than off every row the pair has ever had:
KTD19 governs "the next request", and a rule that accumulated blocks for ever would make a
pair who each declined the other once permanently unreachable to both, which nothing asks
for.

## Edge cases

- Requesting a person id that names nobody, a person who is not visible, and yourself must
  be told apart from each other only where the caller already knows the answer. `:not_visible`
  covers the first two identically; requesting yourself is `:not_visible` too, because a
  person is never co-rostered with themselves.
- Visibility at exactly `max(starts)` is present, at exactly `min(ends) + 30 days` is not.
  Half-open, both ends, matching every other interval in the tree.
- An engagement that was ended before it started — `ends_at == starts_at`, the empty range
  U5's `end_engagement/2` can produce — overlaps nothing and creates no visibility. The
  emptiness clause is the one U6 measured on `overlapping_open_interval/1` and it is needed
  here for the same reason: the endpoint form without it reports an overlap for an empty
  interval.
- Two separate stints at one venue produce two visibility intervals, not one merged one.
  A pair whose first stint ended two years ago and whose second is live is visible; the
  first interval contributes nothing and must not.
- The tail keys on the *first* engagement to end even when the other is still running. A
  worker who left in January is invisible to a colleague still employed there from February
  onwards, and that is the KTD rather than a bug.
- Accepting a lapsed request is refused. Declining one is *not* — the addressee may always
  say no, and refusing the decline would leave a row nobody could clear.
- Accepting a request you sent, declining a request you sent, and accepting one addressed to
  somebody else are all `:not_found`.
- Two concurrent accepts of one request produce one connection; the loser is `:not_found`,
  because by then the request is answered.
- Two concurrent disconnects of one connection close it once; the loser is
  `:already_disconnected`.
- Sending to a closed conversation is refused; reading it is not.
- A message body is bounded and non-empty, with the bound in the database as well as the
  changeset, following `room_messages`.
- `PeerChannel` must answer every event it does not carry rather than crashing —
  `Phoenix.Channel.Server` dispatches to `handle_in/3` unconditionally — and must ignore an
  unmatched `handle_info/2` message for the same reason `RoomChannel` does.
- A peer broadcast reaches both parties' own topics. `PubSub.subscribe/2` pins the person id
  to the scope, so a channel can only ever be subscribed to its own; the broadcast side is
  scope-free, exactly as `Engagements` and `Rooms` already broadcast.

## Regression risks

- **`boundary_test.exs`.** Three new tables that hold foreign keys to `people`. The positive
  crossing test — "`engagements` is the only table outside the person zone that references
  `people`" — fails the moment one of them is classified anywhere but the person zone. That
  test is the reason the classification is not a judgement call. Not one existing assertion
  may be weakened; the person-zone revoked-tables union grows by one migration's list, which
  is the growth U6 already established.
- **`postgres_roles_test.exs`.** Every unit adding a grant migration adds an entry to the
  unwind list. U8's grants nothing — it only revokes, like the person-zone half of
  `grant_room_zone` — so it writes no `pg_shdepend` row, and the entry is added anyway so
  that the list stays "every grant migration" rather than "the ones that mattered".
- **`EngagementsFixtures.purge/0`.** The peer tables reference `people` with `ON DELETE
  RESTRICT` and the purge deletes people by name prefix. Without an addition there, the
  first peer test to commit a message makes every subsequent non-sandboxed test in the suite
  fail on a foreign key. This is the same growth U6 forced on U5's purge.
- **`Zones`.** Three schemas added to `@person_zone`. `ZonesTest`'s totality check fails
  until they are placed, which is the intended tripwire.
- **`PeerChannel`.** It exists and is joined by `sockets_test.exs` as KTD9's control. Its
  join contract — reply `%{person_id: id}` — is asserted in `peer_channel_test.exs` and must
  not change; the events are added in front of the terminal `handle_in/3` clause, which
  stays where it is.
- **`PubSub`.** `{:peer, person_id}` already exists and already pins the id. U8 adds no
  clause and must not: a new topic type would need a new clause, and the peer surface needs
  no topic the person's own is not.
- **U6's disclosure note.** `Rooms.list_venue_room_members/2` hands every member of a room
  the `person_id` of every other member, and its docstring asks U8/U9 to render a field list
  rather than the struct. The peer surface is where that lands: `list_visible_peers/1`
  returns a projection carrying the counterpart's `person_id`, the shared venue, and the
  employer-authored `role_label` the viewer can already see on the room's roll — and no
  email address, which is the only other identifying column `people` has.
- **`venues_test.exs`, `engagements_test.exs`, `rooms_test.exs`, `rosters_test.exs`,
  `revocation_test.exs`.** U8 changes no existing context function. The privilege sweep must
  be re-run and reported, including against the three new tables.

## Test matrix

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | Two people engaged at one venue over overlapping terms are visible to each other | peers_test | unit | **issue scenario 1** — visibility derived from co-engagement |
| 2 | Two people at *different* venues are not visible to each other | peers_test | boundary | the venue join |
| 3 | Two people at one venue whose terms do not overlap are not visible | peers_test | unit | the overlap predicate |
| 4 | Visibility is present at exactly `max(starts)` and absent one microsecond before | peers_test | unit | the half-open lower bound |
| 5 | Visibility persists 29 days after the first engagement ends | peers_test | unit | **issue scenario 2** |
| 6 | …and has lapsed at 31 days | peers_test | unit | **issue scenario 2** |
| 7 | …and lapses at exactly 30 days, not 30 days and an instant | peers_test | unit | the half-open upper bound |
| 8 | The tail keys on the first engagement to end, not the last | peers_test | unit | `min(ends)` rather than `max(ends)` |
| 9 | An empty engagement term (ended before it started) creates no visibility | peers_test | boundary | the non-emptiness clause U6 measured |
| 10 | Two separate stints at one venue give two intervals; the stale one grants nothing | peers_test | unit | intervals being per engagement pair |
| 11 | `list_visible_peers/1` carries the shared venue and the counterpart's role label | peers_test | unit | the projection |
| 12 | …and carries no email address | peers_test | boundary | U6's disclosure note being acted on |
| 13 | The SQL predicate and the `Visibility` struct agree over a matrix of term pairs and instants | peers_test | boundary | two spellings of one interval drifting |
| 14 | A request between visible people is created, pending, and readable by both | peers_test | unit | the request path |
| 15 | A request to somebody not visible is `:not_visible` | peers_test | unit | visibility gating requests |
| 16 | A request to an id that names nobody is the *same* refusal | peers_test | boundary | AE1 — the refusal enumerating nothing |
| 17 | A request to yourself is refused | peers_test | unit | the self check |
| 18 | A second request while one is pending is `:already_requested` | peers_test | unit | the current-row rule |
| 19 | A pending request whose visibility has lapsed reports state `:lapsed` to the requester | peers_test | unit | **issue scenario 3** |
| 20 | …and accepting it is refused | peers_test | unit | **issue scenario 3**, from the addressee's side |
| 21 | …and declining it still works | peers_test | unit | the addressee always being able to say no |
| 22 | …and the requester may request again once it has lapsed | peers_test | unit | lapse clearing the outstanding row |
| 23 | Declining sets the block on the requester | peers_test | unit | **issue scenario 4** |
| 24 | A declined requester cannot re-send | peers_test | unit | **issue scenario 4** |
| 25 | The decliner can themselves initiate | peers_test | unit | **issue scenario 5** |
| 26 | …and the new request supersedes the declined row | peers_test | unit | one current row per pair |
| 27 | The block survives the pair being co-rostered again at a **different venue** | peers_test | unit | **issue scenario 6** — the block being about history, not employment |
| 28 | Accepting creates a connection both parties can read | peers_test | unit | **issue scenario 7** |
| 29 | …and the connection names the request it came from | peers_test | unit | the disconnect path having a row to write the block on |
| 30 | Accepting somebody else's request is `:not_found` | peers_test | boundary | AE1 |
| 31 | Accepting your own request is `:not_found` | peers_test | unit | the addressee check |
| 32 | Accepting twice is `:not_found` | peers_test | unit | the answered check |
| 33 | The connection survives both engagements ending | peers_test | unit | **issue scenario 8** |
| 34 | …and messages still send and read afterwards | peers_test | unit | **issue scenario 8** as a behaviour, not a row |
| 35 | Either party can send; both read the whole conversation in order | peers_test | unit | the conversation |
| 36 | A message to a connection you are not party to is `:not_found` | peers_test | boundary | AE1 |
| 37 | An empty or over-long body is refused as a changeset error | peers_test | unit | the body constraints |
| 38 | Either party can disconnect, and the conversation closes for both | peers_test | unit | **issue scenario 9** |
| 39 | …the *other* party's disconnect closes it identically | peers_test | unit | **issue scenario 9**, unilateral in both directions |
| 40 | After disconnect each party reads their own messages and only their own | peers_test | unit | **issue scenario 10** |
| 41 | …and nothing was deleted (the rows are all still there) | peers_test | boundary | KTD21 — deletion is `Lifecycle`'s |
| 42 | Sending after disconnect is refused for both parties | peers_test | unit | the closed conversation |
| 43 | Disconnecting blocks the counterpart, not the disconnector | peers_test | unit | **issue scenario 11**, KTD19's direction |
| 44 | The disconnected party cannot re-request | peers_test | unit | **issue scenario 11** |
| 45 | The disconnector can re-request, and acceptance reconnects them | peers_test | unit | "without fresh acceptance" read forwards |
| 46 | …and after that fresh acceptance the old block is not consulted | peers_test | unit | the current-row rule |
| 47 | Disconnecting twice is `:already_disconnected` | peers_test | unit | the conditional close |
| 48 | Disconnecting a connection you are not party to is `:not_found` | peers_test | boundary | AE1 |
| 49 | A person with no engagements at all can still read and send in an existing conversation | peers_test | unit | the plan's demo payoff, from the peer side |
| 50 | Two crossed requests, raced on one barrier, produce exactly one request row | peers_concurrency_test | unit | **issue scenario 12**, the partial unique index |
| 51 | …and accepting it produces exactly one connection | peers_concurrency_test | unit | **issue scenario 12** |
| 52 | Two concurrent accepts of one request produce one connection; the loser is `:not_found` | peers_concurrency_test | unit | the conditional answer |
| 53 | Two concurrent disconnects close once; the loser is `:already_disconnected` | peers_concurrency_test | unit | the conditional close |
| 54 | The sequential case is told apart from each race (controls) | peers_concurrency_test | unit | a friendly check standing in for a constraint |
| 55 | `employer_role` holds no privilege on any of the three peer tables | boundary_test | boundary | **issue scenario 13**, the grant tier |
| 56 | …and the sweep catches `GRANT SELECT (body) ON peer_messages` (control) | boundary_test | boundary | an audit that cannot answer true |
| 57 | The three tables are in the person zone and carry no venue key | boundary_test | boundary | KTD2 |
| 58 | `engagements` is *still* the only table outside the person zone referencing `people` | boundary_test | boundary | criterion 8; already present, now load-bearing again |
| 59 | The peer migration's list of revoked tables equals the classification, unioned with U3's and U6's | boundary_test | boundary | a person-zone table nobody revoked on |
| 60 | `create_peer_graph` rolls down and back up, tables and constraints intact | boundary_test | unit | a `down` nobody ran |
| 61 | An `EmployerRepo` query reaching `peer_messages` raises `ZoneViolationError` naming it | peers_test | boundary | **issue scenario 13**, the backstop |
| 62 | …and a raw `EmployerRepo.query!` on it is refused by Postgres for want of privilege | peers_test | boundary | **issue scenario 13**, the tier below the backstop |
| 63 | Every `Peers` function refuses an `EmployerScope` by `FunctionClauseError` | peers_test | boundary | **issue scenario 13**, the scope split |
| 64 | The whole boundary suite passes with the peer tables populated | peers_test | boundary | the issue's stated verification |
| 65 | `PeerChannel` lists conversations, opens history, sends, and disconnects on one topic | peer_channel_test | unit | **KTD10** — the multiplexing |
| 66 | A message sent by one party arrives on the other party's peer channel | peer_channel_test | unit | the broadcast reaching both topics |
| 67 | …naming its conversation in the payload, never in the topic | peer_channel_test | boundary | KTD10's actual content |
| 68 | A disconnect pushes a terminal notice to both parties' channels | peer_channel_test | unit | the nudge |
| 69 | …and the channel stays alive, because the person's other conversations are on it | peer_channel_test | boundary | multiplexing meaning one conversation cannot stop the topic |
| 70 | A send naming a connection the joiner is not party to is refused | peer_channel_test | boundary | AE1 at the transport |
| 71 | A send is authorised at the instant it arrives, not at join | peer_channel_test | unit | **KTD5** — a request sent after a disconnect on a channel joined before it |
| 72 | An event `PeerChannel` does not carry is answered, not crashed on (already present) | peer_channel_test | unit | the terminal clause |
| 73 | An unmatched `handle_info/2` message does not crash the channel | peer_channel_test | unit | the peer topic being shared by every conversation |

Controls, so no assertion can pass for the wrong reason:

- 1 is the control for 2, 3, 9 and 10 — a visibility function that answered `false` for
  everything satisfies all four alone.
- 5 is the control for 6 and 7: a tail of zero days would satisfy the lapse assertions.
- 4 and 7 are each other's controls on the two open ends.
- 14 is the control for 15–18; 25 for 24; 45 for 44; 21 for 20.
- 12 is a *negative* assertion with 11 as its control: a projection that returned nothing at
  all would satisfy "carries no email".
- 13 is the control for the whole of 1–10: it is the only test that would catch the SQL
  predicate and the rendered interval drifting apart, which is the shape U6 found on
  `overlapping_open_interval/1`.
- 41 is the control for 40: a `list_messages/2` that returned `[]` after a disconnect would
  satisfy "only their own".
- 54 is the control for 50–53: run sequentially, every one of those refusals comes from the
  friendly check rather than from the constraint under test.
- 56 is the control for 55; 58 is the control that 57's classification is the *only* one
  that passes.
- 69 is the control for 68: a channel that stopped on the first disconnect would satisfy
  "pushes a terminal notice" and break every other conversation.

## Implementation constraints

- `@spec` on every public function; error atoms enumerated, never `{:error, term()}`.
- `Ecto.UUID.t()` for entity ids.
- Migrations only through `mix ecto.gen.migration`, with a reversible `down`. U1–U7's are on
  `main` and off-limits. No composite foreign key is added — every key U8 writes is one
  column — so U5's `confmatchtype` inventory is unchanged and must stay unchanged.
- Multi-step writes use `Ecto.Multi` with named steps and the failing step in the error
  tuple. `mode: :savepoint` explicit on each constrained insert.
- No new `Clock.now/0` caller and no change to `.credo.exs`. Every predicate takes the
  instant; `ago/2` and `from_now/2` stay banned.
- Queries live in `HospitalityComs.Peers.Records` and nowhere else. The channel calls the
  context; the context calls `Records`.
- Nothing in the peer graph reads or writes through `EmployerRepo`. Everything runs through
  `HospitalityComs.Repo` under a `PersonScope`.
- `peers_test.exs` and `peers_concurrency_test.exs` are `async: false` with real connections,
  through `EngagementsFixtures.real_connections/0`, for the reason U5 gives — visibility is
  derived from engagements, and an engagement needs a venue written through the other repo.
- The concurrency file follows `rooms_concurrency_test.exs`: barriers released in an
  `after`, racers built inside the barrier's closure, and `await_blocked/1` waiting on the
  racers' own backend pids rather than on a count.
- `import Phoenix.ChannelTest`, not `use`.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from
explicitly.

1. **"Co-rostered" is read as concurrent engagement at one venue, not as a shared shift.**
   The plan fixes this in two places and both point the same way: the interval is "per pair
   per **venue**", and its tail starts at "the first of the two **engagements** to end". A
   shift-level reading would make the interval per shift and would leave the engagement
   endpoints doing nothing. It also lands where U6 already is: the venue room's roll is the
   venue's active engagements, so the set of people a worker can see is the set they are
   already in a room with, extended thirty days past the end. A shared-shift rule would be a
   strict subset of this one and is the narrower choice available later.

2. **`Visibility` and `Conversation` are plain structs with no table**, following
   `HospitalityComs.Rooms.VenueRoom`. A visibility row would be the stored flag the plan
   forbids; a conversation row would be a second place for a connection to be. `Conversation`
   is a connection seen from one side — it names the counterpart, which is the only thing the
   two parties do not agree about.

3. **`connection_requests` carries `superseded_at` and a partial unique index on the pair.**
   The plan asks for a `blocked_initiator_id` column and says nothing about how the pair's
   *current* row is identified. Reading "the latest row" by `(requested_at, id)` is not safe
   under an injected clock: a decline and the counterpart's new request can share an instant
   exactly, and `id` is random on a `binary_id` schema, so "latest" would be a coin toss in
   precisely the test that matters. `superseded_at` with a partial unique index makes the
   current row a database guarantee instead of an ordering convention.

4. **The pair key is two generated columns**, `pair_low_id` and `pair_high_id`, from `LEAST`
   and `GREATEST` of the two person ids. A unique index needs a canonical spelling of an
   unordered pair, and generating it is what stops "A→B" and "B→A" being two pairs. Measured
   against Postgres before relying on it: `LEAST` over `uuid` is immutable enough for a
   generated column.

5. **`peer_connections` stores the pair canonically too**, with a check constraint
   `person_a_id < person_b_id`, so the live-connection uniqueness is a partial unique index
   on `(person_a_id, person_b_id)` and cannot be defeated by argument order.

6. **The interval's endpoints are compared without `LEAST`/`GREATEST` in the `where`.**
   `GREATEST(a1,a2) <= t` is `a1 <= t AND a2 <= t`, and `LEAST(b1,b2) + 30d > t` is
   `b1 > t-30d AND b2 > t-30d`. Writing it that way keeps the predicate in plain Ecto with no
   fragment, and the thirty days live in one Elixir function — `Visibility.cutoff/1` — which
   both the SQL predicate and the rendered struct call. Scenario 13 is what stops the two
   composing differently.

7. **`EngagementsFixtures.purge/0` grew three deletes**, ahead of `people`, for the reason
   U6's four were added ahead of the bridge.

8. **Every claim in this brief about what a test would catch was checked by breaking the
   code.** Recorded in the final report.

## Quality scores (self-assessed)

- Coverage of stated scenarios: all 13 from the issue, plus the issue's stated verification,
  plus 60 more.
- Assertion strength: the lapse tests assert both open ends rather than a midpoint; the
  disconnect tests assert what each party can still read rather than that a row changed; the
  boundary tests assert privilege bits with controls that make them fail.
- Control coverage: 14 controls for the 14 assertions that could pass vacuously.
- Isolation: two new non-sandboxed files with prefix purges; the channel file uses
  `ChannelCase`, which already pins the clock and shares the connections.
- Regression: three new tables, one new migration pair, no existing assertion weakened.
