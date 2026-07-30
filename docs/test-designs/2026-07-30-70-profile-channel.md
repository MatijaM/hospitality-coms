# Test Design Brief — #70, the profile channel

Issue: #70, "feat: the profile channel — U9's contexts reach a browser". Raised from running the
app: opening the Profile tab logs `Ignoring unmatched topic "profile:<uuid>" in
HospitalityComsWeb.PersonSocket`.
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Written and committed before any
production code, so the ordering is visible in the history rather than asserted. Convention
established by `docs/test-designs/2026-07-27-u5-engagement-lifecycle.md` onward, including the
"record revisions rather than applying them silently" section at the end.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began. Recorded here because `AGENTS.md` requires the substitution to be visible in the artifact
rather than inferred from the absence of a review.

## What is being built

One channel — `HospitalityComsWeb.ProfileChannel`, on `HospitalityComsWeb.PersonSocket`, topic
`profile:<person_id>` — answering the seven events `client/src/features/profile/contract.ts`
enumerates. `HospitalityComs.Profiles` is complete and changes in no way; the client is complete
and changes in no way. **This unit adds a transport and nothing else**, and the two things it must
not do are change either end.

`contract.ts` is the specification rather than a description of one. It is 246 lines, it was written
against `HospitalityComs.Profiles`' `@spec`s and its four render structs, and it argues every wire
name it asks for. Its decoders in `decode.ts` **refuse `id`** for the three entities whose Ecto
schemas spell it that way, so a channel that put a schema on the wire would produce a surface that
renders empty and says nothing — which `refusal-message.ts` names as the worst outcome this surface
can have, because "nothing here" is also a meaningful claim about somebody's working life.

## Decision 1 — a channel, and the honest shape of it is written into the moduledoc

`HospitalityComs.Profiles` broadcasts nothing. There is no `announce/2` in the module, and
`use-profile-surface.ts` registers **zero** push handlers — `socket.join` is called with no `events`
key at all, with a comment saying why. So this channel is request/reply with a join lifecycle, which
is HTTP's shape.

Two arguments make it a channel anyway and both are narrow:

- **The client is already written and tested against exactly this contract.** ~2,500 lines of
  surface and ~1,550 lines of tests, passing against a fake transport that speaks `contract.ts`.
  Rewriting them to speak HTTP is the alternative, and it is a bigger change with the same outcome.
- **The rooms surface's reason for going HTTP does not transfer.** `RoomController` exists because
  two of its four reads are lists you need *before* you have a room to ask through — you cannot join
  `venue_room:<venue_id>` until you know which venues you are in. A profile topic is keyed on the
  session's **own person id**, which the client already holds from `GET /api/me`. There is nothing
  to discover first.

**What would justify it staying a channel**, named in the moduledoc so a later unit has a list
rather than a rediscovery: an employer attesting an entry (the worker's record gains a row with no
action of theirs), a correction being resolved (the venue answers a contest, which today the worker
sees only on a rejoin), and a disclosure decided on another device (the ledger is per person and a
worker with two tabs open sees two different answers). None exists today and this unit adds none.

## Decision 2 — the topic suffix is checked with a repeated variable, and this is the worst surface to get it wrong on

`PeerChannel.admitted/3` matches the topic's person against the joining scope's own person as **one
binding**, so a topic naming anybody else has no clause. The alternative — an `==` in a body below —
compiles, passes every test that only ever joins its own topic, and hands one worker another
worker's whole record: every term they have served, every venue that asserted one, every contest
they have raised, and the ledger, which is the list of what they did not want seen.

Same shape here. `ChannelAuth.topic_id/1` casts the suffix first (which also downcases, so a client
that capitalised its own id joins its own surface), then the repeated variable is the check.
`refusal-message.ts` names `unauthorized` as **join-only**, so all three join refusals — no live
session, a topic naming somebody else, a suffix that is not an id — are one `unauthorized` with one
sentence.

## Decision 3 — the join reply carries the incompleteness notice, and no other reply carries anything derived from what was withheld

`Profiles.incompleteness_notice/0` is arity zero on purpose: a notice that could depend on the
worker it is shown beside would be an oracle naming which workers conceal something, which discloses
strictly more than the concealed entries do.

`contract.ts` turns that into a transport property: the notice arrives **on the join**, which is
about the session and which no profile read can influence. So the join reply is
`%{person_id:, incompleteness_notice:}` and **no profile reply carries a notice, a count, a total,
or any field whose value depends on what was withheld**. The assertion that carries this is an exact
key set on both profile replies, because a `hidden_count` is a field being *added* and an exact key
set is the only assertion shape that fails in that direction.

## Decision 4 — four render functions, one per shape, and every entity says `<entity>_id`

The context answers `VisibleEntry`, `VisibleDeclaration`, `VisibleCorrection` and
`VisibleDisclosure` — four render structs that already name their entities `attested_entry_id`,
`declared_entry_id`, `correction_request_id` and `disclosure_id` (#36). The channel's job is
struct → map, `DateTime` → ISO 8601, and nothing else. There is no shape here that needs inventing,
which is why `contract.ts` could be written before the transport existed.

`resolution` and `audience_kind` go on the wire as **atoms**, not strings. `Jason` encodes an atom
as a JSON string, so the client's `RESOLUTIONS`/`AUDIENCE_KINDS` string narrowing sees `"accepted"`
and `"venue"`. That is `PeerChannel.rendered_request/1`'s existing shape for `state`, asserted as
`:pending` in `peer_channel_test.exs` and decoded as `"pending"` by the peer client, so this is one
spelling rather than a new convention.

`VisibleDisclosure` renders `audience_kind` + `audience_id`, never the table's two nullable columns
and never `Disclosure.audience/0`'s tuple. The tuple cannot survive a JSON encoder, so whoever put
it on a transport would split it there — and the split done twice is one entity with two spellings.

## Decision 5 — two refusal families in one payload, and the split is per *field* rather than per *state*

`refusal-message.ts` enumerates the whole vocabulary and it is four codes: `unauthorized` (join
only), `bad_request`, `not_found`, `unprocessable_entity`. `gone`, `forbidden` and `conflict` are
absent and each absence is a fact about `Profiles`. Nothing here may invent a fifth.

The rule this unit adopts, which the contract does not spell out:

- **An id the event needs is `bad_request` when absent and `not_found` when it cannot be resolved**,
  malformed and unknown alike, through `ChannelAuth.topic_id/1`. That is `PeerChannel`'s rule
  unchanged, and it is AE1: `set_disclosure`, `amend_declared_entry` and `request_correction` all
  answer `:not_found` for somebody else's row, and a malformed id must be indistinguishable from
  that or the cast becomes an oracle.
- **Worker-authored text is left to the changeset**, so a blank label or a blank body comes back as
  `unprocessable_entity` with `fields` — which is what the client renders beside the input the
  worker actually filled in. A `bad_request` for a missing `body` would throw that away.
- **`audience_kind` + `audience_id` are one value, and a pair that is not an audience is
  `bad_request`.** This is the one place the rule above is *not* applied to an id, and the reason is
  that the two halves are a tagged union rather than a key: an unknown `audience_kind` and a
  malformed `audience_id` are the same mistake — the payload does not name an audience — and both
  are statements about the caller's own input. It is also the only answer whose copy is right:
  `notFoundMessage("set_disclosure")` says *"That entry is not one of yours"*, which is a lie about
  a mistyped venue id.

  This does mean one payload can produce two codes, `not_found` for the engagement and
  `bad_request` for the audience. That is not a leak: neither says whether anything exists, and
  `refusal-message.ts`'s own note is that the events tell apart *what was named*, never *why*. An
  audience that names no venue and no person is already `unprocessable_entity` from the foreign key,
  by the context's design, so there is no enumeration resistance on that field to preserve.

`set_disclosure` gets its **own** fallback sentence rather than falling through to "that event needs
an id", for `PeerChannel`'s `send` reason: it needs four values, and telling a caller who supplied a
perfectly good `engagement_id` that the id is the problem is worse than saying nothing. The test for
that asserts the two bodies are **unequal**, which is U3's mirror of R15's equality.

## Decision 6 — the worker's own record is not ledger-filtered, and the test needs a control that proves the concealment was real

`Profiles.list_attested_entries/1`'s docstring is explicit: disclosure governs what *others* see,
and a worker who could not see what they were hiding could not decide about it. A `profile` reply
that filtered by the ledger is the plausible-looking bug that breaks the surface's whole purpose —
the disclosure controls in `profile-route.tsx` are rendered *per entry*, so an entry that vanished
when it was hidden could never be un-hidden.

**The assertion "the concealed entry is in the reply" passes against a ledger row that did
nothing**, which is the generative shape in `tests-that-certify-nothing.md`. So the control is a
second read through the *employer's* door — `Profiles.list_visible_entries/2` for the venue the
entry was hidden from — asserting the entry is absent there. Same fixture, same instant, two
readers, opposite answers.

## Decision 7 — `peer_profile` is gated in the context and gets no second gate here

`Profiles.fetch_peer_profile/2` gates on **visible or connected** and the two clauses are not
redundant: visibility lapses thirty days after the first of the pair's two engagements ends, while a
connection is permanent. A `Peers.visible?/2` in front of it in the channel would compile, pass
every test whose pair is currently co-rostered, and take the profile away from two people still in
conversation.

So the channel calls the context and renders the answer. The test that makes the second gate fail is
a **connected pair whose visibility has lapsed**, with a stranger beside it as the control — without
the stranger, "connected people can read each other" is satisfied by a channel that gates on
nothing.

`{:error, :not_a_peer}` becomes `not_found`, covering a person who is neither, an id that names
nobody, and the caller themselves, identically.

## Decision 8 — the reply is asserted to survive `Jason`, because a channel test cannot see the wire

This is the one place the acceptance test can be strengthened past what `Phoenix.ChannelTest`
naturally proves. `assert_reply` hands back the **Elixir term**, so a reply containing a bare
`%VisibleEntry{}` — which has no `Jason.Encoder` — passes every key-set assertion in a channel test
and raises `Protocol.UndefinedError` inside the serializer the first time a browser asks. The
reported symptom in #70 is a browser symptom, and this is the closest a test can get to it without
one.

So the round-trip test encodes the join reply and the `profile` reply with `Jason` and decodes them
back, then asserts the **string** keys `decode.ts` requires and the **string** values
`RESOLUTIONS`/`AUDIENCE_KINDS` narrow against. That is the assertion that would have caught an atom
that should have been a string, and it is the assertion a key-set comparison on the Elixir side
cannot make.

## Acceptance criteria

1. `PersonSocket.__channel__("profile:" <> id)` resolves to `HospitalityComsWeb.ProfileChannel`, and
   `EmployerSocket.__channel__("profile:" <> id)` is `nil`.
2. Joining `profile:<own person id>` on a real `PersonSocket` succeeds and replies with exactly
   `%{person_id:, incompleteness_notice:}`, the notice being `Profiles.incompleteness_notice/0`.
3. A topic naming somebody else, a suffix that is not an id, and a session whose token row is gone
   are all refused with one `unauthorized` and one sentence.
4. `profile` answers the three lists, each element's key set matching `decode.ts` field for field.
5. That reply includes an attested entry the worker has concealed from a venue, and the same entry
   is absent from that venue's own read.
6. `list_disclosures` answers `%{disclosures: [...]}` with `audience_kind` + `audience_id` and
   neither nullable column.
7. `set_disclosure` answers one rendered disclosure; deciding twice about one pair replaces the
   answer rather than adding a row.
8. `declare_entry` and `amend_declared_entry` answer one rendered declaration spelled
   `declared_entry_id`, never `id`; an amendment does not move `declared_at`.
9. `request_correction` answers a `VisibleCorrection` whose key set is **the same** as the entries in
   `profile`'s `correction_requests`.
10. `peer_profile` answers the same three lists as `profile`, carries **no ledger**, and is gated
    visible-**or**-connected.
11. Every refusal is an `ErrorEnvelope` whose `code` is one of the four in
    `PROFILE_ERROR_CODES`, and no other code appears anywhere on the channel.
12. An event the channel does not handle, and a `handle_info/2` message no clause matches, both
    leave the channel alive.
13. The instant is per inbound event: a peer visible when the channel joined is refused after the
    clock advances past the tail, on the same channel with no rejoin.
14. Both replies survive `Jason.encode!/1` and decode to the string keys and string enum values
    `decode.ts` requires.
15. `npm run verify` is unchanged at 514 passed / 15 skipped, and nothing under `client/` is edited.

## Edge cases

- **A capitalised suffix.** `Ecto.UUID.cast/1` downcases, so `profile:<UPPERCASE>` joins the
  person's own surface rather than being told it belongs to somebody else. The client already
  lowercases in `normaliseTopicId`, so this is belt to that brace; it is `PeerChannel`'s documented
  behaviour and is inherited rather than re-tested.
- **Sixteen raw bytes as a suffix.** `EntityId.cast/1`'s `byte_size(id) == 36` is what refuses it;
  `Ecto.UUID.cast/1` alone would encode it into a well-formed id naming a row nobody has. Covered by
  the malformed-suffix refusal rather than as its own case, and reported as such — `employer_controller_test.exs`
  records that this input class kills nothing where both branches converge on one answer.
- **A payload that is not a map at all.** `%{}` matches every map and nothing else, so a JSON string
  or array reaches the fallback clause. `declare_entry` is the only event with no id, so it gets its
  own fallback rather than the terminal "this channel does not handle that event", which would be a
  lie about an event the channel does handle.
- **A concealed entry whose concealment is the computed default rather than a ledger row.** Not
  reachable through this channel at all: the worker's own read applies no rule, and the peer read
  applies the context's. Named because "the ledger is not the answer to who can see this" is the
  client's own standing warning and a test that assumed otherwise would be asserting the wrong thing.
- **`resolved_at` and `resolution` as a pair.** `decodeCorrectionRequest` refuses the two
  half-states `correction_requests_resolution_complete` forbids, so a render that emitted one
  without the other would decode to `null`. Both come off one struct and cannot diverge here, so
  this is an inherited guarantee rather than a case — asserted once, as `nil`/`nil` on a fresh
  request.
- **An erased person's profile.** Out of scope: `Lifecycle.erase_person/1` deletes the session
  tokens, so no channel of theirs survives, and a *peer* reading an erased person's record is
  `profiles_test.exs`'s and `lifecycle_test.exs`' claim rather than the transport's.

## Regression risks — existing files at risk, by path

| Path | What is at risk |
|---|---|
| `test/hospitality_coms_web/channels/sockets_test.exs` | **will fail, correctly.** Both routing-table pins need the profile topic: `EmployerSocket.__channel__(…) == nil` with the `PersonSocket` resolution as its control. "Refused on every topic the two sockets route" and the control beside it both enumerate the topics and are now one short |
| `lib/hospitality_coms_web/channels/person_socket.ex` | moduledoc enumerates what it routes; a fourth entry that is not described there is drift |
| `lib/hospitality_coms_web/channels/employer_socket.ex` | moduledoc enumerates the absences and each is a decision. `profile:*` is person-zone data and belongs on that list (KTD9) |
| `test/hospitality_coms_web/parameter_filter_test.exs` | the allowlist pin. Nothing is added to it — every new payload key (`engagement_id`, `audience_kind`, `audience_id`, `disclosed`, `role_label`, `organisation_name`, `starts_at`, `ends_at`, `declared_entry_id`, `body`) is filtered by default and must stay that way. `person_id` is already on the list and is `peer_profile`'s only key |
| `test/hospitality_coms/profiles_test.exs` | pins `Profiles`' whole export list against a literal. This unit calls ten of them and adds none; if that file needs an edit, the context changed and the unit is wrong |
| `.credo.exs` | `:boundary_modules` must **not** grow. `ChannelAuth` is already the one entry that covers every channel, and a `ProfileChannel` entry would be the tell that it read a clock of its own |
| `client/**` | must not be edited. `npm run verify` at 514/15 is the assertion |

## Test matrix

New file: `test/hospitality_coms_web/channels/profile_channel_test.exs`, through
`HospitalityComsWeb.ChannelCase` — **not sandboxed**, real connections, ownership `{:shared, self()}`,
clock pinned to `EngagementsFixtures.fixed_instant/0`. It has to be: a profile read spans an
attested entry written inside the claim's transaction through `Repo` and, for the control in row 5,
an employer view read through `EmployerRepo`.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | joining `profile:<own id>` replies with exactly `%{person_id:, incompleteness_notice:}` | profile_channel | unit | **the route on `PersonSocket`** — this is #70's reported symptom, directly |
| 2 | …and the notice is `Profiles.incompleteness_notice/0` and is not empty | profile_channel | boundary | **control for 1** — a join reply carrying `incompleteness_notice: ""` satisfies an exact key set |
| 3 | a topic naming somebody else and a suffix that is not an id are one `unauthorized` | profile_channel | boundary | **the repeated variable in `admitted/3`** (Decision 2) |
| 4 | …with the same socket joining its own as the control | profile_channel | boundary | **control for 3** — a `join/3` refusing everything satisfies 3 |
| 5 | `profile` answers three lists, each element's key set matching `decode.ts` field for field | profile_channel | unit | the render functions; and the exact key sets, which are what fail when a field is *added* |
| 6 | …including an attested entry the worker concealed from a venue | profile_channel | boundary | **Decision 6** — a ledger filter on the worker's own read |
| 7 | …and that venue's own read does not have it | profile_channel | boundary | **control for 6** — a ledger row that did nothing satisfies 6 |
| 8 | `list_disclosures` renders `audience_kind` + `audience_id`, both audiences | profile_channel | unit | `rendered_disclosure/1`; the two nullable columns on the wire |
| 9 | `set_disclosure` answers one disclosure and deciding twice replaces rather than adds | profile_channel | unit | the upsert reaching the channel at all; a second row would give two ledger entries |
| 10 | `set_disclosure` for an engagement that is not this person's is `not_found` | profile_channel | boundary | AE1 at the transport |
| 11 | `set_disclosure` with an unknown `audience_kind`, and with a malformed `audience_id`, are both `bad_request` | profile_channel | edge | **Decision 5** — `audience/2`'s fallback; and the cast on the audience id |
| 12 | `declare_entry` answers `declared_entry_id` and refuses to say `id` | profile_channel | unit | **the render struct reaching the wire** — the defect `decode.ts` refuses |
| 13 | `amend_declared_entry` answers the same shape and leaves `declared_at` where it was | profile_channel | boundary | the context's own rule, asserted at the transport because that is where the client reads it |
| 14 | somebody else's declared entry, an id naming nothing, and a malformed id are one `not_found` | profile_channel | boundary | `ChannelAuth.topic_id/1` in `with_id/3`; without it the malformed one raises |
| 15 | `declare_entry` with a blank label is `unprocessable_entity` and names `role_label` in `fields` | profile_channel | unit | `ErrorEnvelope.for_changeset/3`; a `bad_request` here throws the field errors away |
| 16 | `request_correction` answers a `VisibleCorrection` whose key set **equals** the one in `profile`'s list | profile_channel | boundary | one shape for the writer and the four readers (#36). Asserted as an equality between two reads rather than against a literal twice |
| 17 | …and a blank body is `unprocessable_entity` naming `body` | profile_channel | unit | Decision 5's second half |
| 18 | `peer_profile` for a visible peer answers the same three lists as `profile` | profile_channel | unit | the gate; the shared render |
| 19 | …for a **connected** pair whose visibility has lapsed, still answers | profile_channel | boundary | **Decision 7** — a `Peers.visible?/2` gate in front of the context |
| 20 | …for a stranger, for the caller themselves, and for an id naming nobody: one `not_found` | profile_channel | boundary | **control for 19** — a channel gating on nothing satisfies 19 |
| 21 | …and the reply carries no ledger and no notice | profile_channel | boundary | an exact key set; the direction a `disclosures` key would arrive from |
| 22 | a peer readable at join is refused after the clock passes the tail, same channel | profile_channel | boundary | **KTD5** — a scope built once at join |
| 23 | …having worked a moment earlier on that same channel | profile_channel | boundary | **control for 22** — a channel refusing everything satisfies 22 |
| 24 | an event with no clause is `bad_request` and the channel is alive | profile_channel | edge | the terminal `handle_in/3` clause |
| 25 | a `handle_info/2` message no clause matches leaves the channel answering | profile_channel | edge | the `handle_info/2` catch-all |
| 26 | `set_disclosure` with no payload and `amend_declared_entry` with no id are both `bad_request` and their bodies are **unequal** | profile_channel | boundary | Decision 5's own fallback clause for `set_disclosure` |
| 27 | the join reply and the `profile` reply survive `Jason` and decode to `decode.ts`'s string keys | profile_channel | boundary | **Decision 8** — the one assertion a browser would make that `assert_reply` does not |
| 28 | `EmployerSocket.__channel__("profile:" <> id) == nil` | sockets | boundary | **KTD9** — the routing table, not a check inside a `join/3` |
| 29 | …with `PersonSocket.__channel__(…)` resolving beside it | sockets | boundary | **control for 28** — an empty routing table satisfies 28 |
| 30 | a deleted token row refuses the profile topic along with the other four | sockets | boundary | `ChannelAuth.join_scope/1` in `join/3`; a socket outliving its credential |
| 31 | …and all five join while the row is live | sockets | boundary | **control for 30**, already in that file and extended |

## Controls, listed explicitly

- **Row 7 controls row 6, and it is the one that decides whether this unit's headline claim means
  anything.** "The concealed entry is in the worker's own reply" passes against a `set_disclosure`
  that wrote nothing, against a fixture where the entry was never concealable, and against a
  disclosure row for the wrong audience. The control reads the *same entry* through the *employer's*
  door at the *same instant* and requires it to be absent. Different reader, different repo,
  opposite answer.
- **Row 20 controls row 19.** A channel with no gate at all — or one that answered every
  `peer_profile` — satisfies row 19 completely. The stranger is the assertion that fails when the
  gate is deleted, and the caller-themselves case is what makes it AE1 rather than a permission
  check.
- **Row 4 controls row 3, and row 23 controls row 22**, both in the shape `sockets_test.exs` already
  uses: a refusal test passes against a `join/3` that refuses everything and against a channel that
  answers nothing, so each refusal is paired with the same socket doing the thing successfully.
- **Row 29 controls row 28**, and this is the shape the project has been burned by twice: an empty
  routing table refuses every topic, so `EmployerSocket.__channel__(x) == nil` means nothing without
  `PersonSocket.__channel__(x)` resolving in the same test.
- **Row 2 controls row 1** in the direction an exact key set cannot: `incompleteness_notice: ""` has
  the right key and no content.
- **Rows 5, 21 and 27 are exact key sets and are asserted against literals written in the test
  file**, never against the other side of the comparison. That is `tests-that-certify-nothing.md`'s
  "a key comparison between two structs of one type" — the shape that made #34's control invariant
  under every possible difference in content. Row 16 is the deliberate exception and is an equality
  between **two different reads** (a write reply and a list element), which is what makes it a
  one-shape assertion rather than two copies of one literal.
- **Every list assertion pattern-matches an element out** before asserting anything about it, so an
  empty list cannot satisfy it. `assert %{attested_entries: [entry]} = reply` rather than a count.
- **Row 27 is a control in a different shape from every other row**, which is
  `tests-that-certify-nothing.md`'s standing instruction: if the check is a key set on an Elixir
  term, control it with a JSON round trip. It is the only assertion in the file that can fail for an
  atom that should have been a string or a struct that should have been a map.

## Implementation constraints

- **`HospitalityComs.Profiles` does not change.** Ten exported functions are called and none is
  added, renamed or re-specced. `profiles_test.exs` pins the whole export list against a literal; if
  it needs an edit, this unit is wrong.
- **Nothing under `client/` changes.** If it wants to, the channel has diverged from `contract.ts`.
  A genuine contradiction *inside* `contract.ts` or between it and the context is reported, not
  resolved in the client's favour.
- **No migration**, no schema change, no new column, no new table. `Zones` is untouched and
  `boundary_test.exs` should not move.
- **The clock rule.** `ChannelAuth.person_scope/1` at the top of every `handle_in/3` and
  `ChannelAuth.join_scope/1` in `join/3`. No `Clock.now/0` anywhere in the channel and **no new
  `.credo.exs` `:boundary_modules` entry**.
- **`@spec` on every function, with enumerated error atoms.** `PeerChannel`'s `@type reply()` is the
  precedent: the union is the contract the client is written against, so it is spelled out rather
  than left as `term()`.
- **Every refusal through `HospitalityComsWeb.ErrorEnvelope`.** No hand-rolled body, and the four
  codes in `PROFILE_ERROR_CODES` are the whole vocabulary.
- **Pattern-matched clauses over `case`/`if`**, per `AGENTS.md`. The audience tag, the id cast and
  every refusal are function heads.
- **The terminal `handle_in/3` clause and the `handle_info/2` catch-all are both required**
  (KTD10) and both tested. `RoomChannel.unknown_event/1` and `RoomChannel.ignored/1` are the
  existing spellings; a second copy of either would be the drift this tree keeps fixing.
- **Never migrate `hospitality_coms_dev`.**
- Gates: `mix format --check-formatted`, `mix deps.unlock --check-unused`,
  `mix compile --force --warnings-as-errors` in **dev and `MIX_ENV=prod`**, `mix quality`,
  `mix test`. Baseline **1245/1249**, the four `PostgresRolesTest` failures being issue #20's
  documented `hospitality_coms_dev` condition. Client: `npm run verify`, baseline **514 passed / 15
  skipped**, and it must be exactly that afterwards.

## Mutations to be run

Each applied to the finished tree, run against the whole suite, then restored. Counts are failures
minus the four `PostgresRolesTest` baseline failures. **Predictions are written here before
measurement**, because a predicted zero is worth more than a surprised one.

| # | Mutation | Predicted |
|---|----------|-----------|
| M1 | `admitted/3` drops the repeated variable — the topic's person and the session's are two bindings | ≥1 |
| M2 | the join reply drops `incompleteness_notice` | ≥1 |
| M3 | `join/3` builds its scope from `socket.assigns` instead of `ChannelAuth.join_scope/1` | ≥1 |
| M4 | `profile` filters attested entries by the disclosure ledger | ≥1 |
| M5 | `rendered_declaration/1` says `id` where it should say `declared_entry_id` | ≥3 |
| M6 | `rendered_correction/1` says `id` where it should say `correction_request_id` | ≥2 |
| M7 | `rendered_disclosure/1` emits `audience_venue_id`/`audience_person_id` instead of the tagged pair | ≥2 |
| M8 | `peer_profile` gates on `Peers.visible?/2` in front of the context | ≥1 |
| M9 | the `peer_profile` reply gains `disclosures:` | ≥1 |
| M10 | the terminal `handle_in/3` clause is deleted | ≥1 |
| M11 | the `handle_info/2` catch-all is deleted | ≥1 |
| M12 | `with_id/3` passes the raw string through instead of casting it | ≥1 |
| M13 | `handle_in/3` uses an instant captured at join (KTD5 broken) | ≥1 |
| M14 | `audience/2`'s fallback treats an unknown kind as `:venue` | ≥1 |
| M15 | `set_disclosure`'s own fallback clause is removed, so it falls through to "needs an id" | ≥1 |
| M16 | `EmployerSocket` gains `channel "profile:*"` | ≥1 |
| M17 | `rendered_entry/1` gains `person_id` | ≥1 |
| M18 | `list_disclosures` replies with the `%VisibleDisclosure{}` structs rather than maps | **0 without row 27**, ≥1 with it |

M18 is the one written down as a prediction about the *test suite* rather than about the code: a
channel test reads the Elixir term, so a struct on the reply satisfies every other assertion in the
file and fails only in a browser. If row 27 does not kill it, row 27 is not doing the job it was
written for and this brief says so before it is measured.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | all seven events, both refusal families, the join lifecycle, both routing tables, the JSON round trip |
| Control discipline | 4/5 | rows 4, 7, 20, 23, 29 are each a mutation somebody would plausibly make; row 27 is the different-shape control. The weak one is row 2, whose mutation (an empty notice) is contrived |
| Regression protection | 4/5 | seven existing paths named; `sockets_test.exs` will fail by design and is extended rather than relaxed; the client is protected by an unchanged count rather than by an assertion |
| Falsifiability | 5/5 | every row names a mechanism whose removal fails it, and M18's zero is predicted before it is run |
| Risk of a vacuous pass | 3/5 | the residue is the browser. No test in this tree opens a socket over HTTP, so "the Profile tab loads" is inferred from a join, a reply shape and a `Jason` round trip rather than observed. Written into the report rather than claimed as coverage |
