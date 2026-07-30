/**
 * `HospitalityComsWeb.ProfileChannel` answers all of this (#70, #73).
 *
 * This file is the whole of what the profile surface asks a Phoenix channel
 * for. It was written *before* any channel answered it — the one clearly-marked
 * place the other three slices of U12 did not need — so that whoever put U9 on
 * the transport had an exact list to satisfy rather than a surface to reverse
 * engineer. That happened in #70, and **not one line under `client/` changed**,
 * which is the strongest thing that can be said for a contract written ahead of
 * its implementation.
 *
 * **`listAudiences` is the one event here that went the other way**, and the
 * distinction is worth keeping straight. The seven below were this file asking
 * and #70 answering. The eighth was #76 *offering* something no version of this
 * file had asked for, because it could not: `DisclosureControl` made the worker
 * type a raw uuid for an audience, and the two lists that would have let it
 * offer a picker existed in `Engagements` and `Peers` with no transport. So its
 * shape was read out of `profile_channel.ex` rather than specified here, which
 * is the posture `features/peers/decode.ts` has for the whole peer surface.
 *
 * It stays the specification rather than becoming a record of one. The channel
 * is tested against these payloads; where the two disagree, this file is right
 * and the channel is wrong.
 *
 * Measured against the tree at `3063e9c`, which is U9 merged:
 *
 *   * `grep -rn 'Profiles' lib/hospitality_coms_web/` finds **nothing**.
 *   * `router.ex` declares four API routes — `POST /api/log-in`,
 *     `POST /api/log-in/token`, `GET /api/me`, `DELETE /api/log-out` — and the
 *     dev mailbox. None of them is a profile.
 *   * `PeerChannel` handles nine events (`list_peers`, `list_conversations`,
 *     `list_requests`, `request`, `accept`, `decline`, `history`, `send`,
 *     `disconnect`) and none of them carries an entry, a disclosure or a
 *     correction.
 *   * `EmployerVenueChannel` has one `handle_in/3` clause and it is the
 *     terminal one, which answers `bad_request` to everything.
 *
 * U9's issue named contexts, migrations and one test file, and its verification
 * is a context-level claim. So the absence is deliberate on that side, not an
 * oversight, and this file is deliberate on this side.
 *
 * ## Why the client was built against it anyway
 *
 * The alternative was to build only what an existing channel event can feed,
 * and that set is **empty** — see the four measurements above. "Build nothing"
 * is not a slice. What made building it defensible is that the part U9 has
 * settled is the part a client actually depends on: the *shapes*.
 * `VisibleEntry`, `VisibleCorrection`, `DeclaredEntry` and `Disclosure` are
 * real modules with `@enforce_keys`, `@type t()` and a moduledoc arguing every
 * field, and `HospitalityComs.Profiles`' `@spec`s say exactly which function
 * answers which. What is *not* settled is the envelope — the topic, the event
 * names, the wire casing — and that is what is written down here rather than
 * scattered through the surface.
 *
 * The README's standing rule is "nothing is stubbed; a placeholder for a shape
 * nobody has chosen costs the next unit more to find and undo than it costs to
 * write from nothing". That rule is about a shape **nobody has chosen**. These
 * are chosen; only their envelope is not.
 *
 * ## What a transport author has to write, exactly
 *
 * Every event below traces to one exported function of `HospitalityComs.Profiles`
 * and one render shape. Nothing here needs a context change. Four of the eight
 * do need a **render function** written next to the channel, because the context
 * answers an Ecto schema struct rather than a render struct — `listAudiences` is
 * the fourth and needs two, since both halves of its reply are schema structs
 * (`ProfileChannel.rendered_venue/1` and `rendered_person/1`) — see
 * "Three entities have no render struct" below, which is the one thing in this
 * contract that is a finding rather than a choice.
 *
 * ## The topic, and why it is a constant
 *
 * `PROFILE_TOPIC_PREFIX` is `"profile:"`, joined as `profile:<person_id>` on
 * `PersonSocket`, with the suffix matched against the joining scope's own
 * person exactly as `PeerChannel.admitted/3` matches its own.
 *
 * Putting these eight events on `PeerChannel` instead is the real alternative
 * and it is a **one-constant change here**: none of the eight names collides
 * with any of `PeerChannel`'s nine, deliberately, so the client would need this
 * file's prefix changed and nothing else.
 *
 * It is written as a separate topic rather than as more clauses on `PeerChannel`
 * for a reason that is in `PeerChannel`'s own moduledoc: "a crash on this
 * channel takes every one of that person's conversations with it (KTD10,
 * deliberate)". Two of these eight events carry worker-authored text into an
 * Ecto changeset, which is the most likely thing on this surface to raise. A
 * profile is also not a conversation, so it is not what that multiplexing point
 * exists for. And `PersonSocket` gaining a route is a change `sockets_test.exs`
 * asserts structurally, so it happens in the open. **`EmployerSocket` gains
 * nothing either way** — KTD9, and see "The employer read is not here" below.
 *
 * ## Three entities have no render struct, and that is a finding
 *
 * `VisibleEntry` and `VisibleCorrection` name their ids `attested_entry_id` and
 * `correction_request_id`. `DeclaredEntry`, `Disclosure` and `CorrectionRequest`
 * are Ecto schemas and name theirs **`id`** — they have no render struct at all,
 * because U9 had no transport to render for.
 *
 * A channel that put those schemas on the wire wholesale would ship `id` for
 * three entities beside `attested_entry_id` and `correction_request_id` for two,
 * on one surface. That is the defect class this project has already fixed twice
 * (U8's `rendered_message/1` saying `id` in the reply and `message_id` in the
 * push; U9's `venue_corrections/1` handing back a schema so `resolution` was
 * `"declined"` on one path and `:declined` on three others), and issue #31 is a
 * third instance. So this contract asks for `declared_entry_id` and
 * `disclosure_id`, and asks `request_correction` to answer a
 * `VisibleCorrection` rather than the `CorrectionRequest` schema its `@spec`
 * currently returns — which is what makes the write path and the four read
 * paths one shape instead of five-minus-one.
 *
 * ## `audience_kind` + `audience_id`, in both directions
 *
 * `Disclosure.audience()` is `{:venue, id} | {:person, id}` and the table spells
 * it as two nullable columns with exactly one set. Neither is what goes on the
 * wire: a request would then have to be validated for "exactly one", and a
 * reply spelled `audience_venue_id`/`audience_person_id` beside a request
 * spelled otherwise would be one entity with two key names again.
 *
 * So it is `audience_kind` (`"venue"` or `"person"`) plus `audience_id`, in the
 * payload and in the reply. The channel maps it to the tuple with two function
 * heads, which is `Disclosure.put_audience/2`'s own shape.
 *
 * ## What the join reply carries, and why the notice is on it
 *
 * `%{person_id: …, incompleteness_notice: …}`.
 *
 * `Profiles.incompleteness_notice/0` is **arity zero on purpose**: a notice
 * that could depend on the worker it is shown beside would be an oracle naming
 * which workers conceal something, which discloses strictly more than the
 * concealed entries do.
 *
 * Arity zero on a transport is "it arrives once, on the join, and no profile
 * reply carries it". A per-profile field would be arity one however carefully
 * the server computed it — the constant would be *structurally* able to vary
 * per subject, and nothing on this side could tell that it had not.
 *
 * **So no profile reply below carries a notice, a count, a total, or any field
 * whose value depends on what was withheld.** That is the property, and
 * `profile.test.tsx` asserts it against the rendered output rather than against
 * this comment.
 *
 * ## The employer read is not here
 *
 * `Profiles.list_visible_entries/2`, `list_visible_corrections/2`,
 * `list_venue_corrections/1` and `resolve_correction/3` all take an
 * `EmployerScope`, so they belong on `EmployerVenueChannel` and on nothing this
 * file touches. They are absent because whether an employer session is a
 * different route tree, a different build, or the same one is an open question
 * this client has never answered — the README records it as such — and because
 * the two profile scenarios issue #12 names are both worker-facing.
 */

/** Joined as `profile:<person_id>`. See "The topic" above. */
export const PROFILE_TOPIC_PREFIX = "profile:";

/**
 * Every event this surface pushes, traced to the function that must answer it.
 *
 * The values are the wire strings. Nothing else in this feature writes an event
 * name as a literal, so this object is the complete list a `handle_in/3` has to
 * cover.
 */
export const PROFILE_EVENTS = {
  /**
   * `Profiles.own_profile/1`.
   *
   * Payload `{}`. Reply
   * `%{attested_entries: [rendered_entry], declared_entries: [rendered_declared_entry],
   *    correction_requests: [rendered_correction]}`.
   *
   * The worker's own record shows **everything, concealed entries included** —
   * `list_attested_entries/1`'s docstring is explicit that disclosure governs
   * what others see and that a worker who could not see what they were hiding
   * could not decide about it. So this reply is not filtered by the ledger and
   * must not become so.
   */
  ownProfile: "profile",

  /**
   * `Profiles.list_disclosures/1`.
   *
   * Payload `{}`. Reply `%{disclosures: [rendered_disclosure]}`, newest first.
   *
   * The worker's own view of the ledger and the only view of it there is: an
   * employer-facing counterpart would tell a venue which of its workers is
   * concealing something.
   */
  listDisclosures: "list_disclosures",

  /**
   * `Profiles.set_disclosure/4`.
   *
   * Payload `%{engagement_id, audience_kind, audience_id, disclosed}`.
   * Reply is one `rendered_disclosure`.
   *
   * `engagement_id` is the entry's `entry_engagement_id` — the entry is named
   * by its engagement, because `attested_entries.engagement_id` is unique and a
   * person-zone row must not point at an employer-zone entry.
   *
   * Deciding twice about one (entry, audience) replaces the answer; it does not
   * add a row. `{:error, :not_found}` for an engagement that is not this
   * person's, identically to an id that names nothing.
   */
  setDisclosure: "set_disclosure",

  /**
   * `Profiles.declare_entry/2`.
   *
   * Payload `%{role_label, organisation_name, starts_at, ends_at}`.
   * Reply is one `rendered_declared_entry`.
   *
   * `ends_at > starts_at` strictly, unlike an engagement — a declared entry is
   * never ended, only written, so the empty range has nothing to represent.
   * A changeset error arrives as `unprocessable_entity` with `fields`.
   */
  declareEntry: "declare_entry",

  /**
   * `Profiles.amend_declared_entry/3`.
   *
   * Payload `%{declared_entry_id, role_label, organisation_name, starts_at, ends_at}`.
   * Reply is one `rendered_declared_entry`.
   *
   * Somebody else's entry and an id that names nothing are both `:not_found`.
   * `declared_at` is untouched by an amendment: amending a statement is not
   * re-declaring it.
   */
  amendDeclaredEntry: "amend_declared_entry",

  /**
   * `Profiles.request_correction/3`.
   *
   * Payload `%{engagement_id, body}`. Reply is one `rendered_correction`.
   *
   * The **only** remedy against an attested entry: a worker cannot edit one and
   * there is no function that would. Resolving one writes no entry either, so
   * an accepted correction is an acknowledgement.
   *
   * The context answers a `CorrectionRequest` schema struct here and a
   * `VisibleCorrection` on all four read paths. **Render the `VisibleCorrection`**
   * — see "Three entities have no render struct" above.
   */
  requestCorrection: "request_correction",

  /**
   * `Profiles.fetch_peer_profile/2`.
   *
   * Payload `%{person_id}`. Reply is the same three lists as `profile`.
   *
   * Gated on the pair being **visible or connected**, and `{:error, :not_a_peer}`
   * must arrive as `not_found`: it covers a person who is neither, an id that
   * names nobody, and the caller themselves, identically (AE1). A client that
   * rendered two sentences would hand back the distinction the server declines
   * to make.
   *
   * This reply carries **no ledger**, and there is no event that would give a
   * viewer one. What a worker has decided about their own record is theirs.
   */
  peerProfile: "peer_profile",

  /**
   * `Engagements.list_engaged_venues/1` and `Peers.list_reachable_peers/1`.
   *
   * Payload `{}`. Reply
   * `%{venues: [%{venue_id, name}], people: [%{person_id, display_name}]}`.
   *
   * The two kinds `Disclosure.audience/0` has, which is what
   * `setDisclosure`'s `audience_kind` + `audience_id` names. **Added by #76
   * rather than asked for here** — see this file's banner.
   *
   * **One event and not two**, so both halves share an instant: neither is
   * stored, both are derived, and a picker showing a venue from 10:00 beside a
   * peer from 10:05 would be two answers to one question.
   *
   * Each list is exactly the set that can read the record, and neither is a
   * list that already existed. The venues are engagements **active at the
   * instant**, which is the employer view's own predicate — not
   * `list_managed_venues/1`, which needs a live grant and would leave an
   * ordinary worker's picker empty, and not `VisibleEntry.venue_id`, which is
   * the venue that *asserted* an entry rather than one that could be an
   * audience for it. The people are visible **or connected**, which is the pair
   * `fetch_peer_profile/2` gates on; the connected half is what makes the
   * remedy for the peer-disclosure residue reachable, since the person a worker
   * most wants to hide an entry from is one who is connected and no longer
   * co-rostered.
   *
   * **Both are answers about *now*, and the ledger is for ever.** So a decision
   * already taken can name an audience on neither list, and the surface renders
   * that rather than resolving it to nothing. See `EntryAudiences`.
   */
  listAudiences: "list_audiences",
} as const;

export type ProfileEvent = (typeof PROFILE_EVENTS)[keyof typeof PROFILE_EVENTS];
