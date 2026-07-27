# Test Design Brief — U7, Realtime transport and revocation

Issue: #7. Plan: `docs/plans/2026-07-26-001-feat-worker-owned-identity-poc-plan.md`, unit U7.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written before any production
code; the orchestrator stands in for the human approver (issue #21 tracks the missing
skill). Convention established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md`
and `-u6-rooms-and-derived-membership.md`.

## What is being built

Two socket modules with separate channel routing tables, channel join authorization that
re-derives membership from the database at a fresh instant, one subscription module whose
clauses key on the scope struct, presence keyed on engagements, and revocation whose
enforcement is **the refused rejoin**.

**Nothing here is the revocation.** U5 already closes an engagement's term and announces it
after commit; U6 already derives every membership from that term. What U7 adds is a
transport that cannot outlive either. KTD8 is explicit that the broadcast, the terminal
push and the channel stop are all *nudges* — the JS client auto-rejoins on `phx_error`, so
the only thing that actually revokes access is `join/3` asking the database again and being
told no. A test that asserts the channel process died is testing the nudge.

## Acceptance criteria

1. **KTD7 — socket id is per session.** `PersonSocket.id/1` and `EmployerSocket.id/1` both
   return `"session:<base64url of the stored token digest>"`, which is the exact string
   `HospitalityComsWeb.PersonAuth.disconnect_sessions/1` already broadcasts `"disconnect"`
   to. Not per person: a per-person id would take down the Venue A session when the Venue B
   engagement ends, violating R7 and AE1 directly.
2. **KTD9 — two socket modules.** `EmployerSocket` declares no peer topic and no room
   topic, so `EmployerSocket.__channel__("peer")` is `nil` and a join attempt is refused in
   Phoenix's dispatch with no application code running. `PersonSocket.__channel__("peer")`
   matches, which is what stops criterion 2 passing for an empty routing table.
3. **KTD10 — peer conversations multiplex.** One person-scoped `"peer"` channel rather than
   one channel per conversation, so a multi-employer worker's channel count stays far below
   `max_channels_per_transport` (100 in Phoenix 1.8.9) and no peer topic exists on an
   employer socket to be routed to.
4. **The token travels in a header.** Both sockets are declared `auth_token: true`, so the
   credential arrives in `connect_info[:auth_token]` (from `Sec-WebSocket-Protocol` on the
   websocket transport) rather than in a query parameter that lands in access logs.
5. **KTD8 — `join/3` is the enforcement point.** Every join re-derives membership against
   the database at an instant taken *at join time*, through the same U6 predicates. Nothing
   about membership is cached on the socket.
6. **KTD5 — the unit of work is the inbound event.** The scope's instant is refreshed on
   every inbound event, never stamped at join. A channel lives for hours; a join-time
   instant would authorise a send against a moment before the grace window opened.
   Exactly one new module joins `:boundary_modules`.
7. **Subscription is scope-keyed.** `HospitalityComs.PubSub.subscribe/2` dispatches on the
   scope struct, so an employer scope handed a peer topic is a `FunctionClauseError` before
   any subscription is registered — the gap a repo-only analysis misses, because
   `subscribe` delivers messages with no query at all.
8. **Revocation broadcasts only after commit.** Already true of
   `Engagements.end_engagement/2`; U7 must not add a second mechanism, and a rolled-back
   change must produce no broadcast at all.
9. **Presence discloses nothing an employer may not have.** Presences are keyed on
   `engagement_id`, never `person_id` (KTD15b), and are tracked only on person-socket
   topics. No employer-facing surface reads them.
10. **Ending one venue's engagement leaves the other venue's channels joined and
    functional** — R4 and AE1, end to end over the transport.

## The refused rejoin, and why it is the whole unit

The revocation sequence the plan draws has five steps, and four of them are best effort:

```
commit → broadcast → push "access_revoked" → {:stop, {:shutdown, :revoked}}
       → client auto-rejoins → join/3 re-derives → {:error, unauthorized}
```

Every arrow before the last can fail without the guarantee failing. The broadcast can be
lost (`Engagements` logs it and carries on, deliberately). The push can race the socket
closing. The stop can be beaten by a client that reconnects first. **The last arrow is the
only one that is load-bearing**, because it is a query against a term that has already
closed, and it answers the same way whether or not anything else ran.

So the revocation test asserts, in order and in one test:

- the join succeeded before the engagement ended (**control** — a channel that never joined
  would satisfy every later assertion);
- `"access_revoked"` was pushed and the channel process went `:DOWN`;
- **a fresh join on the same authenticated socket, same topic, is refused** — this is the
  assertion the execution note demands, and it is a *new* `join/3` invocation against the
  same `%Phoenix.Socket{}` returned by `connect/3`, i.e. what the JS client's auto-rejoin
  does over the wire;
- and the same socket can still join the Venue A room, so the refusal is a re-derivation
  about this venue rather than a socket that has become useless.

## Edge cases

- A connect with no `auth_token` key, an empty token, a token that is not base64url, and a
  well-formed token naming no row — all four are `:error` from `connect/3`, indistinguishably.
- Two sessions for the same person have two different socket ids, so `"disconnect"` on one
  leaves the other alone. This is KTD7's actual content and it is asserted directly on
  `id/1` rather than only through behaviour.
- A join for a venue the person has never been engaged at, and a join for a venue whose
  engagement ended, produce the *same* refusal — so the transport enumerates nothing (AE1).
- A suspended person cannot join their venue room (U6: suspension closes their own access)
  but is still on the room's roll. Presence must not become the arithmetic that recovers
  the opt-out.
- A shift-room join uses *readability* (roster period overlapping the room's open window),
  which is wider than membership: somebody removed from the roster an hour ago can still
  join and read, and cannot send.
- A send at exactly `closes_at` is refused on a channel joined before `closes_at`, with no
  job having run and no rejoin in between. That is criterion 6 as a behaviour.
- An engagement ending at Venue B delivers on topic `engagement:<B's id>` only; the Venue A
  channel is subscribed to `engagement:<A's id>` and receives nothing.
- A revocation broadcast for an engagement this channel is not about must not stop it. The
  channel matches the incoming `engagement_id` against its own assign.
- `Presence.track/3` is never paired with an explicit `untrack` on revocation: the tracker
  monitors the channel process, so the stop *is* the leave. A test asserts the leave arrives
  with no untrack call anywhere in the tree.
- Presence fetcher tasks run in processes of their own. They must be drained before the
  test's connections are checked in, or a fetcher outliving its owner raises. Our `fetch/2`
  does no database work at all, which is the structural half; the drain assertion is the
  other half.

## Regression risks

- **`.credo.exs`'s `:boundary_modules`.** A channel is a new unit-of-work boundary and
  `CLAUDE.md` says to add it rather than work around the check. The risk is adding *six*
  entries (two sockets, four channels) and thereby making the list a formality. One module
  owns the channel unit of work and only it is added.
- **`PersonAuth`.** `session_topic/1` is currently private and is the only spelling of the
  socket-id string. The sockets must use the same spelling or `disconnect_sessions/1`
  broadcasts into the void. Making it public is additive; nothing about
  `disconnect_sessions/1` changes.
- **`Rooms`.** The channels need the *engagement* behind a membership, not just a boolean,
  in order to name the revocation topic and to key presence. `venue_room_member?/2` and
  `shift_room_readable?/2` must keep their exact current behaviour; the new functions
  compose the same `Records` predicates rather than respelling them.
- **`Engagements`.** An employer socket's authority derives from a grant-holding
  engagement, which is a read the context does not yet expose. Additive, and it reuses
  `Records.active_at/2` and `Records.live_grant_ids/2` rather than spelling "active" or
  "live" a second time.
- **`boundary_test.exs`, `venues_test.exs`, `engagements_test.exs`, `rooms_test.exs`,
  `rosters_test.exs`.** U7 creates no table, no migration and no grant. Not one assertion in
  any of them may change. The privilege sweep must be re-run and reported.
- **`application.ex`.** Presence is a supervised tree. It must start after `PubSub` and
  before `Endpoint`, or a socket can accept a connection before the tracker exists.
- **PubSub is global across async tests** (plan, Risks). Every topic here is namespaced by
  a fixture-generated id — venue, engagement, shift room — so two files cannot collide.
- **Channel processes are separate processes.** The room fixtures already commit for real
  because the two repos cannot see each other under the sandbox; a channel process holds no
  connection of its own, so these tests need shared ownership over the real connections.
  Getting that wrong shows up as `DBConnection.OwnershipError` inside `join/3`, which the
  channel would report as a crash rather than a refusal — a failure mode that could be
  mistaken for the feature working.

## Test matrix

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | A person socket connects with a live token and gets a socket id of `session:<digest>` | sockets_test | unit | `auth_token` wiring + KTD7's id |
| 2 | Two sessions for one person have different socket ids | sockets_test | unit | the id being per session, not per person |
| 3 | The socket id equals the topic `PersonAuth.disconnect_sessions/1` broadcasts to | sockets_test | unit | one spelling of the string |
| 4 | A connect with no token, a malformed token, or an unknown token is refused | sockets_test | unit | authentication at connect |
| 5 | An expired session token is refused at connect | sockets_test | unit | the instant reaching the token query |
| 6 | An employer socket connects with the same credential | sockets_test | unit | employer transport existing at all |
| 7 | `EmployerSocket.__channel__("peer")` is nil; `PersonSocket`'s is not | sockets_test | unit | **KTD9** |
| 8 | Joining `"peer"` on the employer socket fails as an unmatched topic | sockets_test | unit | KTD9, at the dispatch |
| 9 | Joining `"peer"` on the person socket succeeds (control for 7 and 8) | sockets_test | unit | the peer route existing |
| 10 | `EmployerSocket` routes no venue-room and no shift-room topic | sockets_test | unit | room conversation staying worker-facing |
| 11 | An employer scope passed to `PubSub.subscribe/2` for a peer topic raises `FunctionClauseError` | pub_sub_test | unit | **scope-keyed clauses** |
| 12 | …and for a venue-room, shift-room and engagement topic likewise | pub_sub_test | unit | the same, on every person target |
| 13 | A person scope passed an employer-venue topic raises too (symmetry) | pub_sub_test | unit | the refusal being structural, not one-way |
| 14 | A person scope subscribing to *another* person's peer topic raises | pub_sub_test | unit | the id being pinned to the scope by match |
| 15 | An employer scope subscribing to *another* venue's topic raises | pub_sub_test | unit | the venue being pinned by match |
| 16 | Each accepted pairing subscribes and the process receives a broadcast (control for 11–15) | pub_sub_test | unit | subscription actually working |
| 17 | Joining a venue room with an active engagement succeeds | venue_room_channel_test | unit | join re-deriving membership |
| 18 | Joining a venue room after the engagement ends is refused | venue_room_channel_test | unit | **KTD8** |
| 19 | Joining a venue the person was never engaged at gets the identical refusal | venue_room_channel_test | boundary | AE1's not-found-rather-than-forbidden |
| 20 | A suspended person cannot join their venue room | venue_room_channel_test | unit | suspension reaching the transport |
| 21 | …and resuming lets them join again (control for 20) | venue_room_channel_test | unit | reversibility |
| 22 | A send over the channel writes a message and broadcasts it to the topic | venue_room_channel_test | unit | the send path |
| 23 | A send after the engagement ends is refused on a channel joined before it | venue_room_channel_test | unit | **KTD5** — instant per event, not per join |
| 24 | Joining a shift room the person may read succeeds | shift_room_channel_test | unit | readability reaching the transport |
| 25 | Joining a shift room the person was never rostered on is refused | shift_room_channel_test | unit | KTD14's scope |
| 26 | Somebody removed from the roster after open can still join and read | shift_room_channel_test | unit | readability being overlap, not containment |
| 27 | …and their send is refused as `not_rostered` (control for 26) | shift_room_channel_test | unit | membership ≠ readability |
| 28 | A send inside the grace window is accepted on the channel | shift_room_channel_test | unit | the write window |
| 29 | A send at exactly `closes_at` is refused on a channel joined before it | shift_room_channel_test | unit | **KTD5**, the demo's flagship beat |
| 30 | Ending an engagement pushes `access_revoked` and stops the venue-room channel | revocation_test | unit | the after-commit broadcast reaching the channel |
| 31 | …and stops the shift-room channel of the same venue in the same breath | revocation_test | unit | every channel subscribing to its engagement |
| 32 | **After that stop, a rejoin on the same authenticated socket is refused** | revocation_test | unit | **the guarantee**; the nudge alone would pass 30 |
| 33 | The join that preceded it succeeded (control for 32) | revocation_test | unit | a channel that never joined would satisfy 32 |
| 34 | Ending a Venue B engagement leaves the Venue A channel joined | revocation_test | unit | per-engagement topics, per-session socket id |
| 35 | …and the Venue A channel still sends afterwards | revocation_test | unit | "functional", not merely "alive" |
| 36 | …and the Venue A room is still rejoinable on the same socket | revocation_test | unit | the refusal in 32 being about the venue |
| 37 | A rolled-back end (last grant holder) produces no revocation broadcast | revocation_test | unit | broadcast only on `{:ok, _}` (KTD8) |
| 38 | …and the channel is still joined and still sends after the refusal | revocation_test | unit | the rollback not being a half-measure |
| 39 | A revocation for a different engagement does not stop this channel | revocation_test | unit | the channel matching its own assign |
| 40 | Presence tracks the joiner under their `engagement_id`, never `person_id` | presence_test | boundary | KTD15b at the transport |
| 41 | Presence emits a leave when a revoked channel stops, with no untrack call | presence_test | unit | the tracker monitoring the process |
| 42 | Presence fetcher processes are drained on test exit | presence_test | unit | fetchers outliving their owner |
| 43 | A suspended person is absent from presence and present on the room's roll | presence_test | boundary | **KTD18** — presence must not recover the opt-out |
| 44 | No employer-socket topic carries presence | presence_test | boundary | KTD18 and KTD9 together |

Controls, so no assertion can pass for the wrong reason:

- 9 is the control for 7 and 8: a socket with an empty routing table satisfies both alone.
- 17 is the control for 18 and 19; 21 for 20; 16 for 11–15; 33 for 32; 26 for 25.
- 28 is the control for 29 and 27 the control for 26 — a send path that refused everything,
  or a join that admitted everyone, would satisfy the negative half alone.
- 35 and 36 are the controls for 34: a Venue A channel that was alive but broken, or alive
  but unjoinable, would satisfy "left joined" without leaving anything working.
- 38 is the control for 37: a channel that had already stopped would produce no broadcast
  either.
- 43 carries U6's own control shape — the person is asserted *present on the roll* in the
  same test, so a presence implementation that hid everybody would fail it.

## Implementation constraints

- `@spec` on every public function; error atoms enumerated, never `{:error, term()}`.
  Functions generated by `use Phoenix.Presence` and `use Phoenix.Channel` are the
  framework's and carry no spec; everything this unit writes does.
- `Ecto.UUID.t()` for ids.
- **No migration.** U7 creates no table, no column and no grant. U1–U6's migrations are
  off-limits and none needs amending.
- `Clock.now/0` is called from exactly one new module, which is added to
  `:boundary_modules` in `.credo.exs`. `Ecto.Query.ago/2` and `from_now/2` stay banned.
- Every membership question a channel asks is answered by `Rooms` or `Engagements` through
  the `Records` predicates U5 and U6 own. No channel writes a `where` clause.
- The web layer calls context functions only — never `Repo`, never `EmployerRepo`, never a
  context's `Records` sub-module.
- Both sockets declared `auth_token: true`; neither reads a query parameter.
- `import Phoenix.ChannelTest`, not `use` — the latter is deprecated.
- Channel tests are `async: false` with real connections and shared ownership, following
  `HospitalityComs.EngagementsFixtures`; `pub_sub_test` is `async: true` and touches no
  database.
- No employer-facing surface may name a person, and `engagements.person_id` stays the only
  crossing. Presence keys are engagement ids.

## Revisions made during implementation

Recorded rather than silently applied, because the gate exists to be departed from
explicitly.

1. **A fourth and fifth channel exist that the plan's file list does not name.**
   `PeerChannel` and `EmployerVenueChannel`. Without a `"peer"` route on `PersonSocket`,
   scenario 8 — the KTD9 assertion this unit exists for — passes against a socket with an
   empty routing table, which is not a test. Without any route on `EmployerSocket`, the
   same is true from the other side. Both are minimal: `PeerChannel` joins an authenticated
   person and subscribes them to their own peer topic, which is the multiplexing point
   KTD10 names and which U8 fills in; `EmployerVenueChannel` joins under a grant re-derived
   at join time and carries no room topic and no person id.

2. **`EmployerSocket` authenticates the person, and the venue is resolved per channel.**
   There is no separate employer credential in this application and there should not be
   one: a manager's authority derives from a grant, and `engagements.grant_id` is what
   records that they hold it. So the employer socket takes the same session token, and the
   `EmployerScope` is built at join from `(person, venue_id)` by re-deriving the
   grant-holding engagement. Connect authenticates; join authorises. That is KTD8 applied
   to the employer side, and it means one employer socket serves every venue the person
   manages without ever putting a venue on the transport's credential.

3. **`HospitalityComsWeb.ChannelAuth` is the channel unit-of-work boundary, and it is the
   only module added to `:boundary_modules`.** Six modules capture an instant in this unit
   — two sockets and four channels — and adding six entries would turn the check's
   allowlist into a formality. `ChannelAuth` is the exact analogue of `PersonAuth`: it
   reads the clock once per unit of work and hands back a scope, and nothing downstream
   reads a clock at all.

4. **`HospitalityComs.PubSub` is a module *and* the name of the PubSub server.** The plan
   asks for `lib/hospitality_coms/pub_sub.ex`, and the running `Phoenix.PubSub` process is
   already registered under `HospitalityComs.PubSub`. A registered process name is an atom
   and a module name is an atom, so the two coexist; the module names the server it routes
   through, which reads better than a second name would.

5. **The scope-keyed refusal is two-way and pins ids by match.** The KTD only asks that an
   employer scope handed a peer topic raise. Pinning the person id and the venue id into
   the function head costs nothing and turns "the right kind of scope" into "this scope",
   so a person cannot subscribe to another person's peer topic even by accident.

6. **`Rooms` and `Engagements` each gained one read, and neither respells a predicate.**
   `Rooms.fetch_venue_room_membership/2` exposes the private `fetch_membership/2` the
   context already used; `Rooms.fetch_shift_room_reader/2` composes the same
   `reader_engagement/3` that `shift_room_readable?/2` composes;
   `Engagements.fetch_grant_holding_engagement/2` composes `Records.active_at/2` and
   `Records.live_grant_ids/2`. No existing function changed.

7. **Presence's `fetch/2` is left as the identity.** The framework's own testing note is
   about fetchers that hit the database from a process the sandbox never lent a connection
   to. Ours cannot, because it does no work — the metas carry the role label the join
   already resolved. Scenario 42 asserts the drain anyway, because "it cannot happen" is
   the kind of sentence that stops being true when somebody adds a preload.

8. **`HospitalityComsWeb.ChannelCase` was added.** A channel process is a separate process
   and these tests are non-sandboxed, so the real connections have to be shared with it.
   Putting `Sandbox.mode({:shared, self()})` in a case template rather than in five setup
   blocks is what keeps the ordering against `EngagementsFixtures`' purge correct in one
   place.

## Quality scores (self-assessed)

- Coverage of stated scenarios: 10/10 named in the plan and the issue (plus the issue's
  post-grace send, which the orchestrator's list omitted), and 34 more.
- Assertion strength: the revocation scenario asserts a refused *rejoin*, not a dead
  process; presence asserts a diff, not a call count.
- Control coverage: 12 controls for the 12 assertions that could pass vacuously.
- Isolation: channel tests are non-sandboxed with shared ownership and purge by name
  prefix; `pub_sub_test` is async and touches nothing.
- Regression: U7 adds no table, no migration and no grant, and no existing assertion
  changed. The boundary sweep is re-run and reported.
