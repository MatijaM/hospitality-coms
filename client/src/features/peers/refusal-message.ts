/**
 * The codes `PeerChannel` can refuse with, and what to show a worker for each.
 *
 * `src/app/failure-message.ts`'s argument applies unchanged: the envelope's own
 * documentation says `code` is the machine-readable discriminator and `message`
 * is "for a human reading a log", so **the server's message is never rendered**
 * and the copy is keyed on the code. `fields` is the one exception and is shown
 * as it arrives, because those messages come from Ecto's changeset traversal
 * and name an input the worker actually filled in.
 *
 * ## The vocabulary is this surface's, and it had to be
 *
 * `socket/channel-failure.ts` names no codes: a surface's copy is an exhaustive
 * `switch`, so one shared list would break every surface's switch whenever any
 * surface gained a code. `ROOM_ERROR_CODES` is the rooms'; `PEER_ERROR_CODES`
 * below is this one's, traced to the clause that emits each, and the two sets
 * are genuinely different — the rooms cannot meet `conflict` and this surface
 * cannot meet the rooms' reading of `forbidden`.
 *
 * ## Why the copy takes the action as well as the code
 *
 * `conflict` is **four different refusals on one code**: a request already
 * outstanding, a pair already connected, a conversation already closed, and a
 * send into a closed conversation. One sentence covering all four would have to
 * be so vague as to say nothing, and the server is not going to split them —
 * they are all statements about something the caller was party to, so they are
 * the codes that are allowed to say more, and the code is where U8 stopped.
 *
 * The event this client pushed is the missing discriminator and this client
 * already knows it, so the copy takes it. Every other code reads the same
 * whichever event met it.
 */

import type { ChannelFailure } from "../../socket/channel-failure";

/**
 * The status atoms `HospitalityComsWeb.PeerChannel` is known to refuse with,
 * each traced to the clause that emits it:
 *
 *   * `unauthorized` — `admit/2` and `admitted/3`. **Join only**: a session that
 *     is no longer live, a topic naming somebody else, and a suffix that is not
 *     a uuid, all in one sentence, because saying which would answer whether a
 *     person id names anybody.
 *   * `bad_request` — `"send"` without both a `connection_id` and a `body`, one
 *     of the five id-taking events without an id, and — through
 *     `RoomChannel.unknown_event/1` — any event this channel does not handle.
 *   * `not_found` — `:not_found`, `:not_visible`, and a malformed id, which
 *     `resolved/3` folds in before a context is reached. AE1: a person who is
 *     not a peer, a conversation between two other people and an id that names
 *     nothing are indistinguishable, deliberately, and this client must not
 *     undo that by rendering them differently.
 *   * `gone` — `:lapsed`, from accepting a request whose pair can no longer see
 *     each other. Derived at the instant of the event and reversible.
 *   * `forbidden` — `:blocked`, KTD19: the party who refused keeps the
 *     initiative and the party who was refused does not.
 *   * `conflict` — `:already_requested`, `:already_connected`,
 *     `:already_disconnected` and `:disconnected`. See the header.
 *   * `unprocessable_entity` — a changeset, with `fields`. Reachable from
 *     `"send"` (the body), from `"request"` (the pair's one-current-row index)
 *     and from `"accept"` (the connection).
 */
export const PEER_ERROR_CODES = [
  "unauthorized",
  "bad_request",
  "not_found",
  "gone",
  "forbidden",
  "conflict",
  "unprocessable_entity",
] as const;

export type PeerErrorCode = (typeof PEER_ERROR_CODES)[number];

/** A channel refusal drawn from the peer surface's vocabulary. */
export type PeerFailure = ChannelFailure<PeerErrorCode>;

/**
 * What this client asked for, which is the discriminator the wire does not
 * carry.
 *
 * `join` and `list` cannot be refused by any clause in `PeerChannel` — a join
 * that gets past `admitted/3` is admitted, and the three list events answer
 * `{:ok, …}` unconditionally — but both can still **time out**, and a timeout
 * is not a refusal. They are in the union so that the timeout copy can be right
 * about them.
 */
export type PeerAction =
  "join" | "list" | "request" | "accept" | "decline" | "history" | "send" | "disconnect";

export function isPeerErrorCode(code: string): code is PeerErrorCode {
  return (PEER_ERROR_CODES as readonly string[]).includes(code);
}

/**
 * The most recent thing that went wrong, and what this client had asked for.
 *
 * Two members, because a **refusal** and an **answer this client cannot read**
 * are different events. `malformed_reply` is not a `ChannelFailure` and could
 * not be one: adding a member to that union would break `features/rooms/`'s
 * exhaustive switches, which is exactly the coupling `channel-failure.ts` was
 * made codeless to avoid. It lives here rather than with the hook's state so
 * that every sentence this surface can show is written in one file.
 */
export type PeerNotice =
  | {
      readonly kind: "refused";
      readonly action: PeerAction;
      readonly failure: PeerFailure;
    }
  | { readonly kind: "malformed_reply"; readonly action: PeerAction };

/** The one sentence for whatever the surface most recently ran into. */
export function noticeMessage(notice: PeerNotice): string {
  switch (notice.kind) {
    case "refused":
      return refusalMessage(notice.action, notice.failure);
    case "malformed_reply":
      return malformedReplyMessage(notice.action);
  }
}

/**
 * The server answered, and the answer was not a shape this client was promised.
 *
 * `decode.ts` says every decoder returns `null` for "this is not that" so the
 * caller can turn it into a **named absence** rather than `undefined` in a
 * heading. This is that name. Without it the list loaders kept the previous
 * list and said nothing, so one row carrying a `state` this client has no case
 * for left an empty list on screen under the sentence "Nobody has asked you to
 * connect" — the documented property and the implemented one disagreeing, which
 * is the class of defect this project keeps finding.
 */
function malformedReplyMessage(action: PeerAction): string {
  switch (action) {
    case "list":
      return "The server answered in a shape this client does not understand, so one of these lists could not be updated. What is on screen may be out of date.";
    case "history":
      return "The server answered in a shape this client does not understand, so this conversation may be missing messages.";
    case "join":
    case "request":
    case "accept":
    case "decline":
    case "send":
    case "disconnect":
      // Unreachable today: an action's reply is decoded by `run`, which treats
      // an undecodable answer as success with no value — the server accepted
      // it, and the lists are re-asked anyway. Kept as a sentence so that a
      // caller which starts reporting one is not silent.
      return "That went through, but the server described it in a shape this client does not understand.";
  }
}

export function refusalMessage(action: PeerAction, failure: PeerFailure): string {
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
 * well have committed and only the answer was lost, and telling somebody their
 * message "failed" when it is sitting in the other person's conversation is the
 * one sentence here that could be actively wrong.
 */
function timeoutMessage(action: PeerAction): string {
  switch (action) {
    case "join":
    case "list":
    case "history":
      return "The server has not answered yet. It will keep trying on its own; nothing has been refused.";
    case "request":
    case "accept":
    case "decline":
    case "send":
    case "disconnect":
      return "The server did not answer in time. That may or may not have gone through — check below before trying it again.";
  }
}

function codeMessage(
  action: PeerAction,
  code: PeerErrorCode | "unrecognised",
  rawCode: string,
): string {
  switch (code) {
    case "unauthorized":
      return "This session cannot open your peer surface. It may have been signed out somewhere else — sign in again.";
    case "bad_request":
      return "That could not be sent as written.";
    case "not_found":
      // AE1, kept intact. "Does not exist" and "exists and is not yours" are
      // one answer on purpose, so that a refusal enumerates nothing — and a
      // client that rendered two sentences would hand back exactly the
      // distinction the server declines to make.
      return "There is no such person, request or conversation for you. That is the same answer you would get for one that is somebody else's, so it cannot tell you which.";
    case "gone":
      return "That request expired when you stopped working at the same place. Nobody refused it, and it can be answered again if you work together again.";
    case "forbidden":
      return "You cannot be the one to ask. If they want to reconnect, the next approach has to come from them.";
    case "conflict":
      return conflictMessage(action);
    case "unprocessable_entity":
      return "That was not accepted.";
    case "unrecognised":
      return `The server refused for a reason this client does not know about (${rawCode}).`;
  }
}

/** One code, four refusals. The event is what tells them apart. */
function conflictMessage(action: PeerAction): string {
  switch (action) {
    case "request":
      return "You cannot ask them right now: either a request between you two is already outstanding, or you are already connected.";
    case "send":
      return "This conversation is closed. Nothing more can be sent to it, and what is already here stays yours.";
    case "disconnect":
      return "This conversation is already closed.";
    case "join":
    case "list":
    case "accept":
    case "decline":
    case "history":
      // No clause in `PeerChannel` reaches here today. Left as a sentence
      // rather than as `unrecognised` copy, because if one ever does, "already
      // settled" is true of every refusal on this code.
      return "That has already been settled.";
  }
}

/**
 * Whether a refusal means this session can no longer hold the peer surface.
 *
 * Only `unauthorized`, which `PeerChannel` emits at `join/3` alone: the session
 * was re-derived against `people_tokens` and is not live, or the topic is not
 * this session's own.
 *
 * **It is asked on the join path and nowhere else, and that is the whole of
 * where it belongs.** No event outcome can produce `unauthorized` on this
 * channel — every `handle_in/3` refusal goes through `refused/1`, which has no
 * clause for it — so a call site in `run` would be unreachable code pretending
 * to be a safeguard. The path that is real is the **rejoin**: `phoenix`
 * re-joins on its own backoff after a dropped link, and a session revoked in
 * between is refused there. `usePeerSurface`'s `onRefused` is the caller, and
 * what it does is clear the rendered graph.
 *
 * Nothing here touches the session itself. Whether this person is still signed
 * in is `GET /api/me`'s answer and `RequireSession`'s to act on; a channel
 * refusal is not this client's licence to throw a live credential away, which
 * is the line `SessionProvider` already draws between a 401 and a server it
 * could not reach.
 */
export function endsSession(failure: PeerFailure): boolean {
  return (
    (failure.kind === "channel_error" || failure.kind === "channel_field_error") &&
    failure.code === "unauthorized"
  );
}

/**
 * Whether a refusal says the conversation it named is closed.
 *
 * `conflict` from a `"send"` or a `"disconnect"`, which is `:disconnected` and
 * `:already_disconnected` respectively.
 *
 * **It is a reason to re-ask, never a thing to remember**, and that is the one
 * real difference between this surface and the rooms. A room had to remember
 * `room_closed`, because nothing on the wire carries a shift room's `closes_at`
 * and the only way to learn it was to lose a message — so `RoomStore` persists
 * the bar and offers a "Check again" to unlearn a guess that can go stale in
 * both directions. Here `list_conversations` carries `open` for every
 * conversation, so the honest response to this refusal is to ask again and
 * render what the server says. Nothing is inferred, nothing is stored, and
 * there is nothing to un-learn.
 */
export function closesConversation(failure: PeerFailure, action: PeerAction): boolean {
  if (action !== "send" && action !== "disconnect") return false;

  return (
    (failure.kind === "channel_error" || failure.kind === "channel_field_error") &&
    failure.code === "conflict"
  );
}
