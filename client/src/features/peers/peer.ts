/**
 * What the peer surface is to this client: one topic, four entities, and no
 * local authority over any of them.
 *
 * ## One topic for every conversation
 *
 * `HospitalityComsWeb.PeerChannel` is joined at `peer:<person_id>`, and the
 * suffix is **the session's own person**, matched at `join/3` against the scope
 * it derived — `admitted/3`'s repeated variable is the check. So there is
 * exactly one peer topic per session and no per-conversation topic exists at
 * all: KTD10 puts the conversation in every payload and never in the topic,
 * which is what keeps conversations out of `max_channels_per_transport` and
 * stops a per-conversation topic name existing for a later unit to copy into an
 * employer socket's routing table.
 *
 * The consequence for this client is the shape of `use-peer-surface.ts`: one
 * subscription for the whole feature, and a conversation is a **selection**
 * rather than a join.
 *
 * ## Nothing here is persisted, and that is the answer to the room list's
 * question
 *
 * `features/rooms/` keeps a bookmark file because no endpoint and no event
 * enumerates rooms. The peer channel has three that do — `list_peers`,
 * `list_requests` and `list_conversations` — so this feature holds no store, no
 * `localStorage` key and nothing to clear when the session ends. That is worth
 * stating rather than leaving as an absence: peer data is a graph of who a
 * worker knows, which is more sensitive than which venue they worked at, and
 * the reason none of it survives a log-out on a shared terminal is that none of
 * it was ever written down here.
 *
 * ## The client computes nothing about time
 *
 * Every instant on the wire is `DateTime.to_iso8601/1` of something the server
 * stamped, and it stays a string. `:lapsed` in particular is **derived by the
 * server at the instant of the event** (KTD5) — the same clock advance that
 * lapses the visibility lapses the request, in the same query — so a client
 * that compared `visible_until` against its own clock would be re-deriving a
 * decision it is not the authority for, and would disagree with the server
 * whenever `HospitalityComs.Clock` is offset, which the demo does deliberately.
 */

import { shortId } from "../../app/short-id";
import { normaliseTopicId } from "../../socket/topic-id";

/** Where `HospitalityComs.Peers` announces, and what `PeerChannel` joins. */
export function peerTopic(personId: string): string {
  return `peer:${personId}`;
}

/**
 * An id as this client will put it in a topic, or `null` if it is not one.
 *
 * The same rule `HospitalityComsWeb.ChannelAuth.topic_id/1` applies — 36 bytes,
 * then a uuid cast — and the **lowercasing is load-bearing for exactly the
 * reason it is in `features/rooms/room.ts`**, only worse here.
 *
 * `Ecto.UUID.cast/1` downcases, so `peer:ABC…` and `peer:abc…` are one person
 * as far as `admitted/3` is concerned and the join succeeds. But
 * `Phoenix.Channel.Server` subscribes the joined channel to the **literal topic
 * string**, and `HospitalityComs.Peers.topic/1` broadcasts on
 * `PubSub.topic({:peer, person_id})`, which is the lowercase one. An uppercase
 * suffix therefore produces a channel that joins, answers every push it is
 * asked, and receives **no announcement at any time** — every request, every
 * acceptance and every message from the other party silently absent, with
 * nothing refused and nothing logged.
 *
 * A room in the wrong case loses one room's fan-out. This loses the whole
 * surface's, so it is checked at the one place a topic is built.
 *
 * It was duplicated from `room.ts` rather than shared, with the condition for
 * un-duplicating it written down here: *"hoisting a uuid helper into
 * `src/socket/` is the alternative, and it belongs to whichever unit first has
 * a third caller."* The profile surface is that third caller, so the rule now
 * lives in `src/socket/topic-id.ts` and this is the peer surface's name for it.
 */
export function normalisePersonId(value: string): string | null {
  return normaliseTopicId(value);
}

/**
 * Somebody this person can see, at one venue, over one interval.
 *
 * `HospitalityComsWeb.PeerChannel.rendered_peer/1` of a
 * `HospitalityComs.Peers.Visibility`, which is derived on every read and stored
 * nowhere. What it carries about a counterpart — their id, the shared venue and
 * the employer-authored role label, and since #66 their display name — is
 * exactly what the venue room's roll already discloses, and there is **no email
 * address in it**, which is the only other identifying column `people` has.
 *
 * One entry per counterpart per venue: two venues are two entries, and two
 * stints at one venue are merged by `Visibility.merge_stints/1` before they
 * reach the wire. So `personId` can repeat across entries and `personId` plus
 * `venueId` cannot.
 */
export type Peer = {
  readonly personId: string;
  readonly displayName: string;
  readonly venueId: string;
  readonly venueName: string;
  readonly roleLabel: string;
  readonly visibleFrom: string;
  readonly visibleUntil: string;
};

/**
 * Where one approach has got to, at the instant the server was asked.
 *
 * `HospitalityComs.Peers.ConnectionRequest.state/2`'s four values. `lapsed` is
 * the derived one and it can go back to `pending` — the pair being co-rostered
 * again un-lapses the same row, because nothing was written when it lapsed.
 */
export type RequestState = "pending" | "lapsed" | "declined" | "accepted";

export const REQUEST_STATES: readonly RequestState[] = [
  "pending",
  "lapsed",
  "declined",
  "accepted",
];

/**
 * `rendered_request/1`: `request_id`, both parties, the state and the instant
 * each terminal state became true.
 *
 * `acceptedAt` and `declinedAt` are here because `state` is the claim and these
 * are when it became true — a surface rendering "declined" has nothing to
 * render it *as of* without them.
 */
export type PeerRequest = {
  readonly requestId: string;
  readonly requesterId: string;
  readonly addresseeId: string;
  readonly state: RequestState;
  readonly requestedAt: string;
  readonly acceptedAt: string | null;
  readonly declinedAt: string | null;
};

/**
 * `rendered_conversation/1`: a connection seen from this person's side.
 *
 * `peerId` is the counterpart, resolved server-side out of the canonical
 * `person_a_id`/`person_b_id` pair so that a client never has to work out which
 * of the two columns it is in.
 *
 * Closed conversations are in the list and stay there. A disconnect leaves each
 * party their own messages (KTD21 deletes nothing), and a list that dropped
 * closed ones would leave those messages with nothing to reach them by.
 */
export type Conversation = {
  readonly connectionId: string;
  readonly peerId: string;
  readonly connectedAt: string;
  readonly disconnectedAt: string | null;
  readonly disconnectedById: string | null;
  readonly open: boolean;
};

/**
 * `rendered_message/1`: `message_id`, not `id`.
 *
 * That inconsistency was real and was fixed during U8's review — the live
 * `peer_message` push always said `message_id` while the send reply and the
 * history said `id`, so one entity had two key names on one channel.
 * `peer_channel_test.exs` now pins the key set.
 *
 * The push and the reply **also** differed in the instant's key — `sent_at` in
 * the reply, `at` in the push, because the push went through the generic
 * `stamped/1`. `decode.ts` carried a decoder for each, refusing the other's
 * key. Issue #31 closed it on the server: the push says `sent_at` now, the four
 * notices that are notices still say `at`, and there is one decoder.
 */
export type PeerMessage = {
  readonly messageId: string;
  readonly connectionId: string;
  readonly authorId: string;
  readonly body: string;
  readonly sentAt: string;
};

/** A stable key for a peer entry, which is one counterpart at one venue. */
export function peerKey(peer: Peer): string {
  return `${peer.personId}@${peer.venueId}`;
}

/**
 * How long an id is shown for. Never a name: there is no name on the wire.
 *
 * It moved to `src/app/short-id.ts` when the rooms surface became its third
 * caller — `profile.ts` had declared the same function with the same body — and
 * this re-export is what keeps every peer call site unchanged across the move.
 * Same shim rule as `room.ts`'s `instantLabel`: a new caller imports from there.
 */
export { shortId };

/** What the surface calls each request state. */
export function requestStateLabel(state: RequestState): string {
  switch (state) {
    case "pending":
      return "Pending";
    case "lapsed":
      return "Expired";
    case "declined":
      return "Declined";
    case "accepted":
      return "Accepted";
  }
}

/**
 * What a state means, in a sentence, from the requester's side.
 *
 * `lapsed` is the one worth spelling out: nothing was refused and nothing was
 * written. The pair stopped being co-rostered, so the approach cannot be
 * answered until they are again — at which point the same row reports `pending`
 * once more.
 */
export function requestStateMessage(state: RequestState): string {
  switch (state) {
    case "pending":
      return "Waiting for them to answer.";
    case "lapsed":
      return "This expired when you stopped working at the same place. Nobody refused it, and it can come back if you work together again.";
    case "declined":
      return "They said no.";
    case "accepted":
      return "They accepted. The conversation is below.";
  }
}
