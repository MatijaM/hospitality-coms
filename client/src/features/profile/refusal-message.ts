/**
 * The codes the profile channel can refuse with, and what to show a worker for
 * each.
 *
 * `src/app/failure-message.ts`'s argument applies unchanged: the envelope's own
 * documentation says `code` is the machine-readable discriminator and `message`
 * is "for a human reading a log", so **the server's message is never rendered**
 * and the copy is keyed on the code. `fields` is the one exception and is shown
 * as it arrives, because those messages come from Ecto's changeset traversal
 * and name an input the worker actually filled in — which on this surface is
 * most of what can go wrong, since two of the eight events carry worker-authored
 * text.
 *
 * ## The vocabulary is this surface's, and it is the smallest of the three
 *
 * `socket/channel-failure.ts` names no codes on purpose: a surface's copy is an
 * exhaustive `switch`, so one shared list would break every surface's switch
 * whenever any surface gained a code. `ROOM_ERROR_CODES` has six,
 * `PEER_ERROR_CODES` has seven, and this has **four** — not because the surface
 * is simpler but because `HospitalityComs.Profiles`' worker-facing functions
 * enumerate four failures between them and no more. Tracing them was the
 * exercise, and the absences below are as much the finding as the presences.
 */

import type { ChannelFailure } from "../../socket/channel-failure";

/**
 * The status atoms the profile channel would refuse with, each traced to the
 * clause in `HospitalityComs.Profiles` that produces it:
 *
 *   * `unauthorized` — **join only**, as on `PeerChannel`: a session that is no
 *     longer live against `people_tokens`, or a topic naming somebody else.
 *     `ChannelAuth.join_scope/1` re-derives the session from the token's digest
 *     on every join, so this is where a deleted token lands.
 *   * `bad_request` — a payload missing a key the event needs, and any event a
 *     `handle_in/3` has no clause for.
 *   * `not_found` — `{:error, :not_found}` from `set_disclosure/4` (an
 *     engagement that is not this person's), `amend_declared_entry/3` and
 *     `request_correction/3`, **and** `{:error, :not_a_peer}` from
 *     `fetch_peer_profile/2`. AE1: an engagement belonging to somebody else, a
 *     declared entry that does, a person who is neither visible nor connected,
 *     the caller themselves, and an id that names nothing are all one answer,
 *     deliberately, and this client must not undo that by rendering them
 *     differently.
 *   * `unprocessable_entity` — a changeset, with `fields`. Reachable from
 *     `declare_entry/2` and `amend_declared_entry/3` (a blank label, a label
 *     over 120 characters, `ends_at` not after `starts_at`), from
 *     `request_correction/3` (a blank body, or one over 4000 characters), and
 *     from `set_disclosure/4` (an audience naming no venue and no person, which
 *     arrives as a foreign-key error).
 *
 * ## Three codes the peer surface has and this one cannot
 *
 * `gone`, `forbidden` and `conflict` are absent, and each absence is a fact
 * about `Profiles` rather than an omission:
 *
 *   * nothing on this surface **lapses** — the peer surface's `gone` is
 *     `:lapsed`, which is derived per read from whether a pair can still see
 *     each other, and a profile has no such state;
 *   * nothing is **blocked** — KTD19's block is a column on a connection
 *     request, and `fetch_peer_profile/2` gates on visible-or-connected, which
 *     folds into `:not_a_peer` and therefore into `not_found`;
 *   * nothing **conflicts** — `set_disclosure/4` is an upsert against a partial
 *     unique index, so deciding twice replaces the answer and two decisions
 *     racing resolve to one row with the later answer winning. There is no
 *     "already decided" to report, which is the one place this surface is
 *     genuinely simpler than the peers'.
 */
export const PROFILE_ERROR_CODES = [
  "unauthorized",
  "bad_request",
  "not_found",
  "unprocessable_entity",
] as const;

export type ProfileErrorCode = (typeof PROFILE_ERROR_CODES)[number];

/** A channel refusal drawn from the profile surface's vocabulary. */
export type ProfileFailure = ChannelFailure<ProfileErrorCode>;

/**
 * What this client asked for, which is the discriminator the wire does not
 * carry.
 *
 * `join`, `profile` and `disclosures` cannot be refused by anything but a
 * transport bug — the two reads take no argument and answer unconditionally —
 * but all three can **time out**, and a timeout is not a refusal. They are in
 * the union so the timeout copy can be right about them.
 */
export type ProfileAction =
  | "join"
  | "profile"
  | "disclosures"
  | "audiences"
  | "set_disclosure"
  | "declare"
  | "amend"
  | "correction"
  | "peer_profile";

export function isProfileErrorCode(code: string): code is ProfileErrorCode {
  return (PROFILE_ERROR_CODES as readonly string[]).includes(code);
}

/**
 * The most recent thing that went wrong, and what this client had asked for.
 *
 * Two members, for `PeerNotice`'s reason: a **refusal** and an **answer this
 * client cannot read** are different events, and `malformed_reply` could not be
 * a `ChannelFailure` without breaking the rooms' exhaustive switches.
 *
 * On this surface the second member is doing more work than it does elsewhere.
 * No channel emits these shapes yet, so the first thing a real transport will
 * produce if it is written to a different contract than `contract.ts` is
 * precisely a reply this client cannot decode — and the worst outcome would be
 * a profile surface that renders empty and says nothing, which is
 * indistinguishable from a worker who has never worked anywhere.
 */
export type ProfileNotice =
  | {
      readonly kind: "refused";
      readonly action: ProfileAction;
      readonly failure: ProfileFailure;
    }
  | { readonly kind: "malformed_reply"; readonly action: ProfileAction };

/** The one sentence for whatever the surface most recently ran into. */
export function noticeMessage(notice: ProfileNotice): string {
  switch (notice.kind) {
    case "refused":
      return refusalMessage(notice.action, notice.failure);
    case "malformed_reply":
      return malformedReplyMessage(notice.action);
  }
}

function malformedReplyMessage(action: ProfileAction): string {
  switch (action) {
    case "profile":
      return "The server answered in a shape this client does not understand, so your record could not be loaded. What is on screen may be out of date or incomplete — do not read it as everything you have.";
    case "peer_profile":
      return "The server answered in a shape this client does not understand, so that person's record could not be shown.";
    case "disclosures":
      return "The server answered in a shape this client does not understand, so your disclosure decisions could not be loaded. Nothing on screen should be read as who can see what.";
    case "audiences":
      // Deliberately does not say "there is nobody". The list is unknown, not
      // empty, and the surface renders the same distinction.
      return "The server answered in a shape this client does not understand, so the employers and people you could name could not be listed. Decisions you have already taken are unaffected.";
    case "join":
    case "set_disclosure":
    case "declare":
    case "amend":
    case "correction":
      // Reachable only if `run` starts reporting one: an action's reply is
      // decoded there and an undecodable answer is treated as success with no
      // value, because the server accepted it and the lists are re-asked
      // anyway. Kept as a sentence so a caller that does report one is not
      // silent.
      return "That went through, but the server described it in a shape this client does not understand.";
  }
}

export function refusalMessage(action: ProfileAction, failure: ProfileFailure): string {
  switch (failure.kind) {
    case "channel_timeout":
      return timeoutMessage(action);
    case "malformed_refusal":
      return "The server refused in a way this client does not understand. Nothing was changed.";
    case "channel_error":
    case "channel_field_error":
      return codeMessage(action, failure.code, failure.rawCode);
  }
}

/**
 * A timeout is not a refusal: nobody decided anything.
 *
 * The distinction that matters is whether the thing might have happened anyway.
 * A read that never answered changed nothing; a write that never answered may
 * well have committed with only the answer lost — and on this surface the write
 * that must not be reported wrongly is `set_disclosure`. Telling somebody their
 * entry is still hidden when the row committed, or the reverse, is the one
 * sentence here that could send a worker's record somewhere they meant to stop.
 */
function timeoutMessage(action: ProfileAction): string {
  switch (action) {
    case "join":
    case "profile":
    case "disclosures":
    case "audiences":
    case "peer_profile":
      return "The server has not answered yet. It will keep trying on its own; nothing has been refused.";
    case "set_disclosure":
      return "The server did not answer in time, so this client cannot say whether that decision was recorded. Check the entry below before setting it again.";
    case "declare":
    case "amend":
    case "correction":
      return "The server did not answer in time. That may or may not have gone through — check below before trying it again.";
  }
}

function codeMessage(
  action: ProfileAction,
  code: ProfileErrorCode | "unrecognised",
  rawCode: string,
): string {
  switch (code) {
    case "unauthorized":
      return "This session cannot open your record. It may have been signed out somewhere else — sign in again.";
    case "bad_request":
      return "That could not be sent as written.";
    case "not_found":
      return notFoundMessage(action);
    case "unprocessable_entity":
      return "That was not accepted as written. Anything the server said about a particular field is below.";
    case "unrecognised":
      return `The server refused for a reason this client does not know about (${rawCode}).`;
  }
}

/**
 * One code, and the events tell apart *what was named*, never *why*.
 *
 * AE1 is intact in every branch: none of these says whether the thing exists.
 * The sentences differ because the worker named different things — an
 * engagement, an entry they wrote, a person — and telling them which of their
 * own inputs was not accepted discloses nothing, since the input came from this
 * browser. What none of them does is distinguish "there is no such row" from
 * "there is one and it is somebody else's", which is the distinction the server
 * declines to make.
 */
function notFoundMessage(action: ProfileAction): string {
  switch (action) {
    case "peer_profile":
      return "There is no record here for you to read. You can read somebody's record if you have worked with them recently or if the two of you are connected — and this is the same answer you would get for a person who does not exist, so it cannot tell you which.";
    case "set_disclosure":
    case "correction":
      return "That entry is not one of yours. That is the same answer you would get for one that does not exist, so it cannot tell you which.";
    case "amend":
      return "That declared entry is not one of yours. That is the same answer you would get for one that does not exist, so it cannot tell you which.";
    case "join":
    case "profile":
    case "disclosures":
    case "audiences":
    case "declare":
      // No clause reaches here: these name nothing the server has to resolve.
      // `audiences` in particular takes an empty payload and answers two
      // derived lists, so there is no id in it to fail to resolve.
      // Left as a sentence rather than as `unrecognised` copy, because if one
      // ever does, "not yours or not there" is true of every refusal on this
      // code.
      return "That is not something this session can reach. That is the same answer you would get for something that does not exist, so it cannot tell you which.";
  }
}

/**
 * Whether a refusal means this session can no longer hold the profile surface.
 *
 * Only `unauthorized`, which the join emits and no event can: the session was
 * re-derived against `people_tokens` and is not live, or the topic is not this
 * session's own.
 *
 * **The path that is real is the rejoin.** `phoenix` re-joins on its own
 * backoff after a dropped link, and a session revoked in between is refused
 * there. `RequireSession` would not have noticed — `GET /api/me` was answered
 * minutes ago — so without this the record would sit on screen under an alert
 * saying the session was gone.
 *
 * This is the **fourth** shared-terminal finding this client has acted on, and
 * the sharpest: room bookmarks name which venues somebody worked at, a peer
 * graph names who they know, and a profile names both plus every term they
 * served and everything they chose to conceal. `usePeerSurface`'s handling is
 * the model, including the half that is a restraint — it clears what is
 * **rendered** and does not touch the session, because whether this person is
 * still signed in is `GET /api/me`'s answer and a channel refusal is not this
 * client's licence to throw a live credential away.
 */
export function endsSession(failure: ProfileFailure): boolean {
  return (
    (failure.kind === "channel_error" || failure.kind === "channel_field_error") &&
    failure.code === "unauthorized"
  );
}
