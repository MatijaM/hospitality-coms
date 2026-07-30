# Test Design Brief — #73, names instead of uuids on the peer surface

Issue: #73, "feat: names instead of uuids across the person-facing UI". Raised from running the app.
This brief covers the **server half** only: `lib/` and `test/`. A second agent builds the client
against the shapes written down here, and nothing under `client/` is edited by this unit.

Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Committed alone, first, ahead of every line
of production code, so the ordering is visible in `git log` rather than asserted. Nearest precedent
read before writing: `docs/test-designs/2026-07-30-70-profile-channel.md`.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began. Recorded here because `AGENTS.md` requires the substitution to be visible in the artifact
rather than inferred from the absence of a review.

## What is being built

Two things, and they share one mechanism.

**Part A.** `HospitalityComs.Peers.Records` carries `display_name` in exactly one place —
`visible_peers/2`, added by #66 — and the rest of the peer surface renders a bare uuid with no name
at all. The counterpart's display name has to reach three more shapes: the **conversation** (the list
and one conversation), the **connection request** (both directions), and the **peer message**. The
mechanism is `HospitalityComs.Rooms.Records.with_author/1`'s exactly: a join to `people` filling a
**virtual** field, with **no activeness predicate anywhere**, plus a write path that reads the row it
just wrote back through that same join rather than assembling a name from what it holds.

**Part B.** The disclosure control on the profile surface makes the worker type a raw uuid for an
audience, which is a venue **or** a person. `HospitalityComsWeb.ProfileChannel` gains one event
answering the two lists it cannot currently see: the venues the worker holds an engagement at, and
the people who can see them.

Neither part changes a table. Five virtual fields, no migration, `Zones` untouched.

## Decision 1 — the name is joined and never stored, which is #66's argument reaching four more rows

`room_messages` has `author_display_name` as a virtual field and `RoomMessage`'s moduledoc gives
three reasons it is not a column: a stored copy never learns about a rename, a stored *name* in an
employer-zone row is KTD2 broken, and erasure would then rewrite a number of rows proportional to
messages. Only the first two transfer here — `connection_requests`, `peer_connections` and
`peer_messages` are all **person zone**, so a name column would break nothing about the bridge — but
the first is decisive on its own and the third arrives in a different shape: `Lifecycle.erase_person/1`
overwrites `people.display_name` with `erased_display_name/0` in one statement, and a stored copy on
every message, request and connection would make that statement unbounded.

So: `Connection` gains `person_a_display_name` / `person_b_display_name`, `ConnectionRequest` gains
`requester_display_name` / `addressee_display_name`, `PeerMessage` gains `author_display_name` — all
`virtual: true`, filled by three composables in `Records`. `state` on `ConnectionRequest` is the
existing precedent for a virtual field in this namespace.

**The association is deliberately not preloaded.** `Connection` already has `belongs_to :person_a` and
`belongs_to :person_b`, so `preload: [:person_a, :person_b]` is one word and it is the wrong word: it
loads whole `%Person{}` structs, and the only other identifying column `people` has is `email`.
`peers_test.exs:307` asserts the peer list discloses no email address by value **and** by key name;
putting a `Person` struct inside a `Conversation` is exactly the direction that assertion exists to
catch. The join selects `display_name` and nothing else.

## Decision 2 — no activeness predicate on any of the three joins, and this is R15 rather than a copy of #66

`with_author/1` joins `room_messages → engagements → people` with no activeness predicate because a
venue room keeps full history and a message whose author's term closed is ordinary. The peer surface
reaches the same rule from a different direction and it is stronger here: **a connection is
permanent.** It outlives the visibility that produced it and every engagement either party holds
(R13), which is why `Profiles.fetch_peer_profile/2` gates on visible-**or**-connected. A name that
vanished when co-rostering lapsed would blank the heading of a conversation two people are still
having, thirty days after they stopped working together.

The same applies to a request: an outgoing request whose pair has stopped being visible reports
`:lapsed` and is still in the requester's list, and a lapsed request with no name on it is the state
this issue is about.

**An erased counterpart already has a name** and needs no special case: `erase_person/1` writes
`erased_display_name/0` (`"Former colleague"`) in the statement that nulls the address. That is
asserted rather than assumed, because the alternative reading — filter erased people out of the join
— is a one-line mutation that produces `nil` on the wire and reads like tidiness.

## Decision 3 — `connections_of/1` and `connection_of/2` are **not** widened, and that is a finding

`CLAUDE.md` records #66's deferral: *"the counterpart is not known until `Conversation.of_connection/2`
runs, so closing it means either a second keyed read … or widening what `Records.connections_of/1` and
`connection_of/2` select, which four callers share."* The widening was the expected answer. Checking
the callers refuses it:

| Caller | Through | What a join in `connection_of/2` would do |
|---|---|---|
| `Peers.list_conversations/1` | `connections_of/1` | fine — this is the read that wants it |
| `Peers.fetch_conversation/2` | `fetch_connection/2` → `connection_of/2` | fine |
| `Peers.list_messages/2`, `send_message/3` | `fetch_connection/2` → `connection_of/2` | harmless but pointless |
| `Peers.close/4` (`disconnect/2`) | `connection_of/2` + `select` + **`update_all`** | **breaks**: `UPDATE … RETURNING` cannot reference a joined table |
| `Peers.send_message/3`'s `:open` step | `locked_open_connection_of/2` = `connection_of/2` + **`lock("FOR SHARE")`** | **changes lock semantics**: `FOR SHARE` over a join locks the joined `people` rows too, and the tree already refuses that trade — `EngagementRecords.decision_set/4` uses a subquery in `where` rather than a join precisely so `FOR UPDATE` does not reach a second table |

So the join is a **separate composable applied at the reads that render a conversation**, and the two
statement-shaped callers keep the query they have. `Records.with_pair/1` is the connection's (the
schema's own word for its two people is *the pair* — `pair_low_id`, `pair/2`, "the pair is stored in
one order"), `Records.with_parties/1` is the request's (a requester and an addressee are two parties
to an approach and neither is canonically ordered), and `Records.with_author/1` is the message's, U6's
name unchanged.

## Decision 4 — every write reads its row back through the same join

Four write paths answer with a shape that now carries a name, and none of them can produce one:
`Multi.insert` cannot join, and `update_all … RETURNING` cannot reference a joined table (Decision 3).
Taking the name off the scope is refused for #66's measured reason: `ChannelAuth.person_scope/1`
builds `%Person{id: person_id}` and nothing else, so a scope-derived name is correct over HTTP and
`nil` on both channels — and the counterpart's name is not on the scope at all.

So `request_connection/2`, `decline_request/2`, `accept_request/2` and `send_message/3` each read the
row back through the composable that a list read would have used. That is `Rooms.naming/1`'s shape
verbatim: *"the row a send answers with is the row a history read would have produced"*.

The two request read-backs go through `Records.request_by_id/1` — the one query in that module with no
party predicate — rather than `request_of/2`, and the reason is a race: `request_of/2` carries
`superseded_at IS NULL`, and a decline is one statement with no transaction around it, so a
counterpart's fresh approach committing between the `UPDATE` and the read-back would make a `one!`
raise on a channel where a raise takes every conversation down. `request_by_id/1` has no predicate
that can stop matching and nothing deletes request rows (U10 retains them deliberately — the row *is*
KTD19's block). The state is re-applied to the row that comes back, because `state` is virtual and the
re-read does not carry it.

## Decision 5 — every render heads on the name being a binary

`RoomChannel.rendered/1` matches on `is_binary(name)` so that *"a message read by a path that forgot
the join is a `FunctionClauseError` here rather than a `null` on the wire and an `undefined` in a
heading"*. All three peer renders take that head, and `Connection.counterpart_display_name/2` takes it
too — same repeated-variable shape as `Connection.counterpart/2`, so a connection read without the
join has no clause.

That guard is **insurance whose value is only visible as a pair**, exactly as #70's `handle_info/2`
catch-all turned out to be: on its own, removing it kills nothing, because every read path has the
join. It is measured as a pair (M-guard-a alone, M-guard-b with a dropped join) rather than claimed.

## Decision 6 — a request carries **both** names, not the counterpart's

`rendered_request/1` already carries `requester_id` and `addressee_id` and the client renders whichever
side it is not. A `counterpart_display_name` would have to be viewer-relative, and `rendered_request/1`
has no viewer — it serves four call sites (`request`, `decline`, and both lists) whose viewer is the
caller in each case but is not an argument. Threading it through all four to produce a field the
symmetric pair already answers is the change that makes one entity's shape depend on who asked.

It discloses nothing new: a request exists only between two people who were visible to each other, and
`list_visible_peers/1` has carried the counterpart's name since #66.

## Decision 7 — the four notices keep their ids and only the message push gains a name

`client/src/features/peers/use-peer-surface.ts` is explicit: `peer_request`,
`peer_request_declined`, `peer_connected` and `peer_disconnected` are **nudges** — none is applied to
local state, each causes the affected list to be re-asked, because a request's `state` is derived per
read and a notice cannot carry it. `peer_message` is the exception and is applied directly, "because
the notice carries the whole message".

So the one push that must gain `author_display_name` is `peer_message`, and it must, because
`peer_channel_test.exs` already asserts the push's **whole key set equals the send reply's** (#31).
The other four are left alone; adding a name to a nudge would be a field nothing reads.

## Decision 8 — Part B is one event, and the two lists come from `Engagements` and `Peers` rather than from `Profiles`

**One event, `"list_audiences"`.** The picker renders both kinds at once and a single round trip means
the two halves are answered at one instant. `PeerChannel`'s `"list_requests"` — one event, two lists,
two context calls — is the precedent.

**It is not `Profiles.list_audiences/1`**, which was the obvious home and is refused for two reasons
that are both about that context's stated rules. `Profiles` answers **no Ecto schema** in the success
half of any spec (#36), so it could not hand back a `Venue.t()` and would have to project one — which
is the render layer's job everywhere else in this tree (`EmployerController.render_venue/1`,
`RoomController.render_venue_room/1`) and would put a third spelling of a venue inside a context. And
`profiles_test.exs` pins `Profiles.__info__(:functions)` against a literal, which is the right cost
for a *profile* function and the wrong one for a composition of two other contexts' relations.

So `HospitalityComsWeb.ProfileChannel` calls two contexts. It is the first channel in the tree to do
so; every controller does, and `RoomController` — the surface whose reads are "lists you need before
you have a room to ask through" — is this event's nearest sibling.

**The venue list is neither of the two that already exist.**

- Not `VisibleEntry.venue_id`: that is the venue that *asserted an entry*, which is what the picker is
  choosing an audience for. It is why the picker could not be built before.
- Not `Rooms.list_venue_rooms/1`: it subtracts suspensions.
  `Engagements.list_managed_venues/1`'s docstring writes out the trap a previous unit fell into — a
  manager who used the person-side venue-room opt-out disappears from a list employer authority never
  consults. An audience is not a room either: a venue reads a worker's record through
  `employer_visible_attested_entries`, which knows nothing about `venue_room_suspensions`.
- Not `Engagements.list_managed_venues/1` itself: that one requires a **live grant**, so an ordinary
  worker's picker would be empty at the venues that can actually read their record.

The right predicate is the view's own. `create_employer_visible_view.exs` gates on
`viewer.starts_at <= now AND viewer.ends_at > now` — the worker's engagement at that venue must be
**active at the instant** — which is `EngagementRecords.active_at/2` and not a second spelling of
activeness. So `Engagements.list_engaged_venues/1` is `managed_venues/2` with the grant filter dropped,
sharing the venue-projection helper so the ordering and the deduplication have one spelling.

**Residue, on the record:** a venue whose term has ended is not offered, because it cannot read the
record. A decision already taken about it stays in the ledger, still shows in `list_disclosures`, and
applies again if the worker returns. That is the honest reading of "the venues an audience could be" at
the asking instant, and it is the same instant-derived shape the people list has.

**The people list is visible ∪ connected, which is the gate's own pair.**
`Profiles.fetch_peer_profile/2` admits a reader who is `Peers.visible?/2` **or** `Peers.connected?/2`,
and those are not redundant — visibility lapses thirty days past the first engagement to end, and a
connection is permanent. A picker offering only visible peers would make one of the two remedies
`CLAUDE.md` names for the peer-disclosure residue unreachable from the UI: *"it has two remedies the
suite asserts: one `set_disclosure/4` row, or `Peers.disconnect/2`"*. So `Peers.list_reachable_peers/1`
is the list form of that pair, documented as such so the gate and the list cannot come to mean two
things. A **closed** connection's counterpart is not on it — they cannot read the record either.

Visibility is symmetric and so is connection, so "the people who can see them" and "the people they can
see" are the same set; the issue's wording is satisfied by the same query either way.

## The exact wire shapes this unit ships

Written here because the client agent builds against them, and repeated verbatim in the two channel
moduledocs and in the commit message. Added keys are marked **new**; everything else is unchanged.

`HospitalityComsWeb.PeerChannel`:

```
rendered_peer/1        %{person_id, display_name, venue_id, venue_name, role_label,
                         visible_from, visible_until}                       (unchanged)

rendered_conversation/1 %{connection_id, peer_id, peer_display_name*, connected_at,
                          disconnected_at, disconnected_by_id, open}
                        — each entry of "list_conversations", and the replies to
                          "accept" and "disconnect"

rendered_request/1     %{request_id, requester_id, requester_display_name*,
                         addressee_id, addressee_display_name*, state, requested_at,
                         accepted_at, declined_at}
                        — the replies to "request" and "decline", and every entry of
                          both lists in "list_requests"

rendered_message/1     %{message_id, connection_id, author_id, author_display_name*,
                         body, sent_at}
                        — the reply to "send", every entry of "history", and the
                          "peer_message" push

peer_request / peer_request_declined / peer_connected / peer_disconnected  (unchanged)
```

`HospitalityComsWeb.ProfileChannel`, one new event:

```
"list_audiences"   payload %{}
                   reply   %{venues: [%{venue_id, name}],
                             people: [%{person_id, display_name}]}
```

`venue_id`/`name` rather than `venue_id`/`venue_name`, because a venue listed **as itself** is spelled
that way twice already — `EmployerController.render_venue/1` and `RoomController.render_venue_room/1`,
and both client decoders read it. `venue_name` is what a venue named *inside another entity* is called
(`rendered_peer/1`, `rendered_entry/1`), which this is not. Venues are ordered by name then id; people
by display name then person id, since names collide by design.

## Acceptance criteria

1. `Peers.list_conversations/1` and `fetch_conversation/2` answer a `Conversation` carrying
   `peer_display_name`, and it is the **counterpart's**, from either side of the pair.
2. That name survives the visibility that produced the connection lapsing, and survives both parties'
   engagements ending.
3. An erased counterpart's conversation renders `Lifecycle.erased_display_name/0` with nothing having
   visited `peer_connections`.
4. `Peers.list_incoming_requests/1` and `list_outgoing_requests/1` carry both parties' names, including
   on a request whose state is `:lapsed`.
5. `Peers.list_messages/2` carries `author_display_name` on every message, in an open conversation and
   in the own-messages-only read after a disconnect.
6. `request_connection/2`, `decline_request/2`, `accept_request/2` and `send_message/3` answer rows
   whose names are populated — the same values a list read would give.
7. `PeerChannel`'s four rendered shapes have exactly the key sets above, asserted against literals.
8. The `peer_message` push's key set still equals the `"send"` reply's, with the name in both.
9. `Engagements.list_engaged_venues/1` answers the venues a person holds an engagement at, active at
   the scope's instant: no grant required, suspensions not consulted, deduplicated, name-ordered.
10. `Peers.list_reachable_peers/1` answers every counterpart who is visible at the instant or connected,
    deduplicated across venues, and excludes a disconnected counterpart and a stranger.
11. `ProfileChannel`'s `"list_audiences"` answers both lists with the key sets above and survives
    `Jason`.
12. No employer-facing render gains a name (KTD2), and the chat message keeps its short id.
13. `peers_test.exs`'s "discloses no email address" assertion is unchanged and unweakened.
14. Nothing under `client/` is edited; `npm run verify` stays at 531 passed / 15 skipped.

## Edge cases

- **A conversation with an erased counterpart.** Covered as criterion 3 rather than left to inference:
  it is the one case where "no activeness predicate" and "no `erased_at` filter" are the same decision
  seen from two sides.
- **A `:lapsed` outgoing request.** The pair cannot see each other, the request is still listed, and the
  name must be there. This is the case a visibility-scoped join kills and the ordinary tests do not.
- **A disconnected conversation's own-messages read.** `own_messages_of/2` composes `messages_of/1`, so
  the join is inherited; asserted anyway, because a future author could give it its own `from`.
- **Two counterparts with the same display name.** Collisions are deliberate (#66). Nothing here
  deduplicates on the name, and `list_reachable_peers/1` deduplicates on `person_id` — asserted with two
  people renamed to one string, because `Enum.uniq_by(& &1.display_name)` is the plausible slip.
- **A person visible at two venues.** One entry in `list_reachable_peers/1`, where
  `list_visible_peers/1` correctly gives two (it is per venue and carries the venue).
- **A worker with no engagements and no peers.** `"list_audiences"` answers two empty lists rather than
  refusing; there is nothing to be not-found about.
- **A suspended worker.** Present in the venue list (criterion 9). The suspension is a person-side
  venue-room opt-out and the venue's employer door is untouched by it.
- **The employer surface.** Explicitly out of scope and asserted by absence: `employer_role` holds no
  privilege on `people` at table *or* column level, so an employer session cannot read a display name.
  `boundary_test.exs` already carries that and must not move.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms_web/channels/peer_channel_test.exs` | **will fail, correctly.** Two exact key sets (message, request) are literals and each gains fields. They are *extended*, never relaxed to a subset match — the exact set is what catches an email address arriving |
| `test/hospitality_coms/peers_test.exs:307` | the email-absence assertion. Must survive verbatim. The new fields are names, and the test above it (the exact `Visibility` key set) is its control |
| `lib/hospitality_coms/peers.ex` | four write paths gain a read-back. `send_message/3`'s `FOR SHARE` step and `disconnect/2`'s conditional `UPDATE` must keep the queries they have (Decision 3) |
| `test/hospitality_coms/peers_concurrency_test.exs` | races the same four writes. A read-back inside a transaction lengthens the window it holds; the file is not sandboxed and parks real racers on real locks |
| `test/hospitality_coms/lifecycle_test.exs` | erasure's whole-row comparisons. Virtual fields are not columns, so `Map.from_struct/1` on a schema **does** include them — a comparison of two structs read by two paths could differ on a virtual that one path filled |
| `test/hospitality_coms/engagements_test.exs` | `list_managed_venues/1`'s block. The venue projection is refactored into a shared helper; its ordering, dedup and suspension behaviour must not move |
| `test/hospitality_coms_web/channels/profile_channel_test.exs` | the channel gains an event and two aliases; the terminal `handle_in/3` clause must still answer everything else |
| `test/hospitality_coms/profiles_test.exs` | pins `Profiles`' export list. This unit adds nothing to it; if it needs an edit, Decision 8 was wrong |
| `test/hospitality_coms_web/parameter_filter_test.exs` | the allowlist. `"list_audiences"` sends `%{}` and nothing is added |
| `.credo.exs` | `:boundary_modules` must not grow |
| `client/**` | must not be edited. `npm run verify` at 531/15 is the assertion. The client's decoders check named keys with `typeof` and ignore extras, so an added field cannot break them — if one does, it is reported, not fixed |

## Test matrix

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | a conversation carries the counterpart's display name, asked from **both** sides | peers | unit | `with_pair/1` on `connections_of/1`; and `counterpart_display_name/2` taking the right side |
| 2 | …and the two people have different names, so the wrong side is visible | peers | boundary | **control for 1** — a name taken from `person_a` always satisfies a one-sided test |
| 3 | `fetch_conversation/2` carries the same name as the list entry | peers | unit | the join on the single read; asserted as an equality between two reads |
| 4 | a conversation between two people whose co-rostering has lapsed still carries the name | peers | boundary | **Decision 2** — a visibility predicate on the join |
| 5 | an erased counterpart's conversation reads `Lifecycle.erased_display_name/0` | peers | boundary | **Decision 2's other half** — an `erased_at IS NULL` filter |
| 6 | both request lists carry `requester_display_name` and `addressee_display_name` | peers | unit | `with_parties/1` on the two list queries |
| 7 | …on a request the pair can no longer see each other over (`:lapsed`) | peers | boundary | a visibility predicate on the request join |
| 8 | `fetch_request/2` carries both names | peers | unit | `with_parties/1` on `request_of/2` |
| 9 | every message in an open conversation carries `author_display_name` | peers | unit | `with_author/1` on `messages_of/1` |
| 10 | …and in the own-messages-only read after a disconnect | peers | boundary | the join surviving composition through `own_messages_of/2` |
| 11 | a message whose author's engagement has ended still carries the name | peers | boundary | **Decision 2** at the message join |
| 12 | `request_connection/2`'s answer carries both names | peers | unit | **Decision 4** — the read-back |
| 13 | `decline_request/2`'s answer carries both names **and** still reports `:declined` | peers | boundary | the read-back, and re-applying the virtual state to the re-read row |
| 14 | `accept_request/2`'s answer carries the counterpart's name | peers | unit | the read-back |
| 15 | `disconnect/2`'s answer carries the counterpart's name | peers | unit | the read-back |
| 16 | `send_message/3`'s answer carries the author's name, equal to the history read's | peers | boundary | the read-back; asserted as an equality between the write reply and a list read |
| 17 | `list_reachable_peers/1` gives a visible counterpart once, with their name | peers | unit | the visible half |
| 18 | …and a connected counterpart whose visibility has lapsed | peers | boundary | the connected half — the remedy the picker exists to reach |
| 19 | …and **not** a counterpart whose connection was closed, nor a stranger | peers | boundary | **control for 17/18** — a list that returned everybody satisfies both |
| 20 | …once for a counterpart visible at two venues, and once for one who is both visible and connected | peers | edge | the dedup, on `person_id` |
| 21 | …deduplicated on the id and not on the name, with two counterparts sharing one name | peers | edge | `uniq_by(& &1.display_name)`, the plausible slip |
| 22 | the peer list still discloses no email address, by value and by key | peers | boundary | **unchanged assertion**, listed so its survival is deliberate |
| 23 | `list_engaged_venues/1` gives a venue where the person holds no grant | engagements | unit | the grant filter left in |
| 24 | …and a venue where the person is suspended from the venue room | engagements | boundary | **KTD18** — `Rooms.list_venue_rooms/1` reused |
| 25 | …with `Rooms.list_venue_rooms/1` answering `[]` beside it | engagements | boundary | **control for 24** — a suspension that silently did nothing satisfies 24 |
| 26 | …not a venue whose term has ended, and not one that has not opened | engagements | boundary | `active_at/2` |
| 27 | …once for two stints at one venue, ordered by name | engagements | edge | the set-membership projection; a join would list it twice |
| 28 | …and `list_managed_venues/1` is unchanged in the same fixture | engagements | boundary | **control for 23** — the refactor moving the grant filter |
| 29 | the four peer wire shapes have exactly their key sets | peer_channel | unit | the renders; the exact sets, which fail when a field is *added* |
| 30 | the `peer_message` push's key set equals the `"send"` reply's, name included | peer_channel | boundary | **Decision 7** — the announcement not carrying the name |
| 31 | `"accept"` and `"disconnect"` replies carry `peer_display_name` | peer_channel | unit | the two read-backs, at the transport |
| 32 | a conversation heading renders the counterpart, not the reader | peer_channel | boundary | **control for 29** — asserted by value against two different names |
| 33 | `"list_audiences"` answers both lists with exact key sets | profile_channel | unit | the event; the renders |
| 34 | …the venue list holding a venue the worker manages nothing at | profile_channel | boundary | Decision 8's venue source |
| 35 | …the people list holding a connected-but-not-visible counterpart | profile_channel | boundary | Decision 8's people source |
| 36 | …and a stranger in neither list | profile_channel | boundary | **control for 34/35** |
| 37 | the reply survives `Jason` and decodes to string keys | profile_channel | boundary | **#70's Decision 8** — a struct on the wire passes every Elixir-side assertion |
| 38 | an id from `"list_audiences"` is accepted by `"set_disclosure"` as an audience of each kind | profile_channel | boundary | the whole point: a picker whose ids the write refuses is not a picker |
| 39 | the channel still answers an event it does not handle, and stays alive | profile_channel | edge | the terminal clause, after a seventh event was added above it |

## Controls, listed explicitly

- **Row 2 controls row 1, and row 32 controls it at the transport.** "The conversation carries a display
  name" passes against a name taken from `person_a` every time, from a viewer who happens to be
  `person_b`, and from the *reader's own* name. Both people are renamed to distinct known strings and
  the assertion is by value from both sides.
- **Row 19 controls rows 17 and 18.** A `list_reachable_peers/1` that returned every person in the
  database satisfies both. The closed connection is the sharper half: it is the one case where
  "connected" has to mean *live*.
- **Row 25 controls row 24**, in `engagements_test.exs`'s own existing shape for exactly this claim — a
  suspension that silently did nothing satisfies "the suspended worker is in the list", so
  `Rooms.list_venue_rooms/1` answering `[]` beside it is what makes the suspension real.
- **Row 28 controls row 23.** The refactor that shares the venue projection could quietly drop the grant
  filter from `list_managed_venues/1`, which every assertion about the *new* function would be happy
  with.
- **Row 36 controls rows 34 and 35.**
- **Row 37 is a control in a different shape**, per `tests-that-certify-nothing.md`'s standing
  instruction: the other assertions read Elixir terms, so only a `Jason` round trip fails for a struct
  or an atom that should have been a string.
- **Row 22 is a survival control**: the assertion this unit is most likely to be tempted to relax is
  named in the matrix so that leaving it alone is a recorded act.
- **Every list assertion pattern-matches an element out** (`assert [one] = …`) before asserting anything
  about it, so an empty list cannot satisfy it.
- **Every key set is a literal written in the test file**, never `Map.keys/1` of the struct on the other
  side of the render — the shape that made #34's control invariant under every possible difference in
  content. Rows 3 and 16 are the deliberate exceptions and are equalities between **two different
  reads**, which is what makes them one-shape assertions rather than two copies of one literal.

## Implementation constraints

- **No migration, no column, no table.** Five virtual fields. `Zones` untouched, `boundary_test.exs`
  must not move.
- **Nothing under `client/` changes.** A client test that breaks is reported as a finding.
- **No employer-facing render gains a name.** KTD2 is not negotiable here and the issue says so.
- **`Profiles` gains no export** (Decision 8); `profiles_test.exs`'s literal must not need an edit.
- **`.credo.exs`'s `:boundary_modules` must not grow.** Nothing added reads a clock; every instant comes
  off the scope.
- **`@spec` on every function, with enumerated error atoms.** `Peers`' three failure typedocs are the
  precedent and none of them gains a member.
- **Queries stay in `Records`**, which `peers_test.exs` pins structurally out of the compiled `imports`
  chunk: no module in the `HospitalityComs.Peers` namespace but `Records` may reach
  `Ecto.Query.Builder` or `Builder.From`.
- **Pattern-matched clauses over `case`/`if`** — every render head, `counterpart_display_name/2`, and
  the audience projections.
- **Never migrate `hospitality_coms_dev`.**
- Gates: `mix format --check-formatted`, `mix deps.unlock --check-unused`,
  `mix compile --force --warnings-as-errors` in **dev and `MIX_ENV=prod`**, `mix quality`, `mix test`.
  Baseline **1275/1279**, the four `PostgresRolesTest` failures being issue #20's documented
  `hospitality_coms_dev` condition. Client: `npm run verify`, baseline **531 passed / 15 skipped**, and
  it must be exactly that afterwards.

## Mutations to be run

Each applied to the finished tree, run against the whole suite, then restored. Counts are failures
minus the four `PostgresRolesTest` baseline failures. **Predictions are written here before
measurement**, because a predicted zero is worth more than a surprised one.

| # | Mutation | Predicted |
|---|----------|-----------|
| M1 | `with_author/1` (peer messages) is not composed — the message join dropped | ≥3 |
| M2 | `with_pair/1` dropped from `list_conversations/1` | ≥2 |
| M3 | `with_parties/1` dropped from the two request lists | ≥2 |
| M4 | the conversation join is restricted to counterparts still visible at the instant | ≥1 |
| M5 | the message-author join is restricted to authors whose engagement is active | ≥1 |
| M6 | the request join is restricted to counterparts still visible | ≥1 |
| M7 | the author join adds `where: is_nil(person.erased_at)` | ≥1 |
| M8 | `counterpart_display_name/2` answers the **viewer's** own name | ≥2 |
| M9 | `rendered_request/1` swaps the two names | ≥1 |
| M10 | `rendered_conversation/1` omits `peer_display_name` | ≥1 |
| M11 | `rendered_message/1` omits `author_display_name` | ≥2 |
| M12 | `rendered_request/1` omits both names | ≥1 |
| M13 | `Peers.sent/1`'s announcement omits the name (push and reply disagree) | ≥1 |
| M14 | `send_message/3` drops its read-back | ≥1 |
| M15 | `accept_request/2` drops its read-back | ≥1 |
| M16 | `disconnect/2` drops its read-back | ≥1 |
| M17 | `request_connection/2` drops its read-back | ≥1 |
| M18 | `decline_request/2` drops its read-back | ≥1 |
| M19 | `decline_request/2` keeps the read-back but loses the re-applied `:declined` state | ≥1 |
| M20 | the audience venue list comes from `Rooms.list_venue_rooms/1` | ≥1 |
| M21 | the audience venue list comes from `Engagements.list_managed_venues/1` | ≥1 |
| M22 | `list_engaged_venues/1` drops `active_at/2` | ≥1 |
| M23 | `list_reachable_peers/1` drops the connected half | ≥1 |
| M24 | `list_reachable_peers/1` drops the visible half | ≥1 |
| M25 | `list_reachable_peers/1` counts closed connections as connected | ≥1 |
| M26 | `list_reachable_peers/1` deduplicates on `display_name` | ≥1 |
| M27 | `"list_audiences"` spells the venue `%{venue_id, venue_name}` | ≥1 |
| M28a | every render's `is_binary` head guard removed, joins intact | **0** |
| M28b | the guard removed **and** `fetch_conversation/2`'s join dropped | ≥1 |

M28a's zero is predicted rather than discovered: every read path has the join, so the guard is
insurance and its value is only visible as the pair with M28b — the same shape #70 found for
`RoomChannel.ignored/1`. If M28a kills something, the prediction was wrong and this brief says so
before it is measured.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | all four peer shapes, both directions of the request, both halves of the audience picker, both write and read paths |
| Control discipline | 4/5 | rows 2, 19, 25, 28, 32, 36 are each a mutation somebody would plausibly make; row 37 is the different-shape control. The weak one is row 21, whose mutation (deduplicating on a name) is plausible but narrow |
| Regression protection | 4/5 | eleven existing paths named; two key-set literals will fail by design and are extended rather than relaxed; the client is protected by an unchanged count rather than by an assertion |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it, and M28a's zero is predicted before it is run |
| Risk of a vacuous pass | 3/5 | the residue is the browser and the client's decoders. No test in this tree renders a heading, so "the conversation shows a name" is inferred from a reply shape and a `Jason` round trip. Written into the report rather than claimed as coverage |

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from explicitly. The
sections above are not edited to agree with what shipped.

1. **Decision 3 was the brief's prediction and it held, which is the most useful thing in here.**
   `CLAUDE.md` recorded the expected fix as widening `Records.connections_of/1` and `connection_of/2`.
   Two of that query's four callers refuse it — `disconnect/2` composes it into an `update_all`, and
   `locked_open_connection_of/2` adds `FOR SHARE` over what would become a join. Written down before
   the code, and nothing during implementation contradicted it.

2. **An erased person has no peer messages, so criterion 3 could only be asserted for two of the three
   shapes.** The brief assumed an erased counterpart's *message* would render the constant. It cannot:
   `Lifecycle.erase_person/1` deletes the erasing party's own peer messages and keeps the connection and
   the request rows (the request row *is* KTD19's block). The test asserts the conversation heading and
   a **pending incoming request** read `erased_display_name/0`, and asserts the erased party's messages
   are gone — which is why there is no third case rather than an omission. Found by a red test, not by
   reading.

3. **The three "activeness predicate" mutations could not be written as join predicates**, and the brief
   said they would be. `with_pair/1`, `with_parties/1` and `with_author/1` take no instant — they are
   composables over a queryable — so the only predicates expressible *on the join* are instant-free, and
   `erased_at IS NULL` is the one worth running (M7). The instant-bearing form was applied where the
   scope's `now` lives, in the context, and mutated **only the name**: `list_conversations/1`,
   `list_messages/2` and `with_states/3` blank the name for a counterpart who is no longer visible
   (M4, M5, M6). That is precisely the failure the decision names — a blanked heading — rather than a
   different rule wearing its clothes.

4. **Matrix row 27's deduplication half is unreachable, and the reason is a schema decision.**
   `engagements_no_overlap` refuses a second engagement for one person at one venue over an overlapping
   term, so two engagements active at one instant cannot exist and `venues_named_by/1`'s set membership
   has nothing to fold. The fixture failed on the exclusion constraint, which is how this was found.
   The row became an ordering test with the residue written into it — and it applies equally to
   `list_managed_venues/1`, whose docstring makes the same claim.

5. **M28a's prediction was wrong, and the reason is that the brief wrote a test for the guard.** It
   predicted 0 and killed **1** — the `assert_raise FunctionClauseError` test in `peers_test.exs`, which
   exists for the guard and nothing else. So the number is close to tautological and the honest reading
   is unchanged: for every *other* path in the tree the guard is insurance, and its value is visible
   only as the pair with M28b, which kills 6. Same shape #70 found for `RoomChannel.ignored/1`, arrived
   at from the other direction.

6. **`VisibleDisclosure` did not gain an `audience_name`, and that is a decision rather than an
   oversight.** The issue's survey names `profile-route.tsx:298` — a stored ledger row rendering
   `shortId(audienceId)` — and `list_audiences` lets the client resolve that id against the two lists it
   just fetched. What is left uncovered is an audience that has left both lists: a venue whose term has
   ended, or a peer who is neither visible nor connected. Closing it needs two nullable left joins for a
   polymorphic name **and** a third read-back family, because `VisibleDisclosure.of_decision/1` takes the
   `Disclosure` schema and serves the write path as well as the read. That is a bigger change than the
   picker the issue asks for; it is reported as a residue instead.

7. **Rows do not map one-to-one onto test bodies**, as every brief since U8 has recorded. Thirty-nine
   rows became **13** new bodies in `peers_test.exs`, **1** new and **2** extended in
   `peer_channel_test.exs`, **5** in `profile_channel_test.exs` and **5** in `engagements_test.exs` —
   27 new tests.

8. **Baseline arithmetic.** Elixir **1275/1279** before, **1302/1306** after — the same four
   `PostgresRolesTest` failures naming `hospitality_coms_dev` (issue #20). Client **531 passed / 15
   skipped** before and after, with nothing under `client/` edited.

## Mutation record

Twenty-nine mutations, each applied to the finished tree, run against the whole suite, then restored.
Counts are failures minus the four `PostgresRolesTest` baseline failures. **No mutation killed zero.**

| # | Mutation | Predicted | Killed |
|---|----------|-----------|--------|
| M1 | the message join dropped from `messages_of/1` | ≥3 | 6 |
| M2 | `with_pair/1` dropped from `connections_of/1` | ≥2 | 14 |
| M3 | `with_parties/1` dropped from both request lists | ≥2 | 6 |
| M4 | the conversation's name blanked once the pair stops being visible | ≥1 | 2 |
| M5 | a message author's name blanked once the author stops being visible | ≥1 | **1** |
| M6 | a request's names blanked once the pair stops being visible | ≥1 | 2 |
| M7 | `erased_at IS NULL` added to all three joins | ≥1 | **1** |
| M8 | `counterpart_display_name/2` answers the **viewer's own** name | ≥2 | 8 |
| M9 | `rendered_request/1` swaps the two names | ≥1 | **1** |
| M10 | `rendered_conversation/1` omits `peer_display_name` | ≥1 | **1** |
| M11 | `rendered_message/1` omits `author_display_name` | ≥2 | 2 |
| M12 | `rendered_request/1` omits both names | ≥1 | 2 |
| M13 | the `peer_message` announcement omits the name | ≥1 | **1** |
| M14 | `send_message/3` drops its read-back | ≥1 | 8 |
| M15 | `accept_request/2` drops its read-back | ≥1 | 3 |
| M16 | `disconnect/2` drops its read-back | ≥1 | 2 |
| M17 | `request_connection/2` drops its read-back | ≥1 | 3 |
| M18 | `decline_request/2` drops its read-back | ≥1 | 2 |
| M19 | `decline_request/2` keeps the read-back and loses the re-applied `:declined` | ≥1 | 4 |
| M20 | the audience venues come from `Rooms.list_venue_rooms/1` | ≥1 | **1** |
| M21 | the audience venues come from `list_managed_venues/1` | ≥1 | 4 |
| M22 | `engaged_venues/2` drops `active_at/2` | ≥1 | 6 |
| M23 | `list_reachable_peers/1` drops the connected half | ≥1 | 3 |
| M24 | `list_reachable_peers/1` drops the visible half | ≥1 | 6 |
| M25 | `list_reachable_peers/1` counts closed connections as connected | ≥1 | **1** |
| M26 | `list_reachable_peers/1` deduplicates on `display_name` | ≥1 | **1** |
| M27 | the audience venue is spelled `venue_name` | ≥1 | 2 |
| M28a | every `is_binary` head guard removed, joins intact | **0** | **1**, wrong |
| M28b | the guards removed **and** `connections_of/1`'s join dropped | ≥1 | 6 |

**Five are worth reading twice.**

- **M28a is the wrong prediction** and the reason is instructive rather than embarrassing: the brief
  predicted 0 for the rest of the suite and then wrote a test whose whole subject is the guard. The one
  kill is that test. Everything the prediction was actually about still holds — no other assertion in
  the tree notices the guard's absence while the joins are intact — and M28b at 6 is what says the guard
  matters when one is missing.
- **M9 kills exactly one, and it is the one that could not have been written from one side.** Swapping
  `requester_display_name` and `addressee_display_name` is invisible to every context test, because
  `rendered_request/1` is the channel's. The kill is the channel test that renames both people to two
  known strings and asserts by value. A test asserting `is_binary/1` on both, which is the shape somebody
  reaches for, would pass.
- **M8 kills 8, and it is the mutation the whole "ask from both sides" instruction exists for.** Taking
  the name from the reader rather than the counterpart is one character in a pattern match. Half the
  kills come from the two-sided assertions; the rest are the `Conversation` shape reaching four other
  tests.
- **M5 and M7 kill exactly one each, and each is the test written for it.** A message author's name
  surviving the author's engagement ending, and an erased counterpart reading as the constant: both are
  the "no predicate on the join" rule, both are invisible to every other test in the tree, and both
  would have shipped silently. That is the pattern this project keeps finding — a rule with no test
  fails nothing.
- **M20 kills exactly one and M21 kills four**, which is the asymmetry the audience venue list was
  designed around. Reusing `list_venue_rooms/1` is caught only by the suspended-worker test with its
  `Rooms.list_venue_rooms(worker) == []` control beside it; reusing `list_managed_venues/1` is caught
  more widely because an ordinary worker's picker goes empty. The narrow one is the one that would have
  shipped.
