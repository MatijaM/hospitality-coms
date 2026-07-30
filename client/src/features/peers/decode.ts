/**
 * Turning `PeerChannel`'s payloads into the types the peer surface renders.
 *
 * Same posture as `src/api/decode.ts` and `features/rooms/decode.ts`: every
 * decoder answers `null` for "this is not that", never a partial value and
 * never a throw. Keys are the wire's snake_case, the types are camelCase, and
 * this file is the only place the two meet.
 *
 * **The shapes were read out of `lib/hospitality_coms_web/channels/peer_channel.ex`,
 * not inferred from prose.** `rendered_peer/1`, `rendered_request/1`,
 * `rendered_conversation/1` and `rendered_message/1` are the four, and
 * `peer_channel_test.exs` asserts two of the key sets exactly — which is what
 * makes this file checkable against something rather than against a memory.
 *
 * ## One entity, one decoder — which it was not
 *
 * A message reaches this client down two paths, and they used to carry
 * **different keys for its instant**: the reply to `"send"` and each entry of
 * `"history"` are `rendered_message/1`, which says `sent_at`, while the
 * `"peer_message"` push went through `PeerChannel.stamped/1`, which says `at`.
 * So this file carried two decoders and one type, each refusing the other's key
 * — deliberately, because a single decoder with a fallback would also accept a
 * payload carrying neither.
 *
 * Issue #31 closed it on the server: the push goes through `PeerChannel.sent/1`
 * now and says `sent_at`, and the four notices that genuinely are notices still
 * say `at` because `at` means "when this notice happened". So the two decoders
 * are one, and `peer_channel_test.exs` pins the push's key set against the
 * reply's rather than against a memory of it.
 */

import { isRecord } from "../../api/decode";
import type { Conversation, Peer, PeerMessage, PeerRequest, RequestState } from "./peer";
import { REQUEST_STATES } from "./peer";

/** Every entry or nothing: a list with one bad row is not a shorter list. */
function decodeList<Value>(
  value: unknown,
  decode: (entry: unknown) => Value | null,
): readonly Value[] | null {
  if (!Array.isArray(value)) return null;

  const decoded: Value[] = [];

  for (const entry of value) {
    const one = decode(entry);
    if (one === null) return null;
    decoded.push(one);
  }

  return decoded;
}

function optionalString(value: unknown): string | null | undefined {
  if (value === null) return null;
  if (typeof value === "string") return value;

  return undefined;
}

/** `%{person_id:}` — `PeerChannel.admitted/3`'s join reply. */
export function decodeJoinedPersonId(payload: unknown): string | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.person_id !== "string") return null;

  return payload.person_id;
}

/**
 * `%{person_id:, display_name:, venue_id:, venue_name:, role_label:,
 * visible_from:, visible_until:}` — `rendered_peer/1`.
 *
 * Every field is required and none is nullable: `venues.name` and
 * `engagements.role_label` are both `null: false`, and `Visibility.t()` types
 * the two labels as `String.t()` rather than `String.t() | nil`.
 */
export function decodePeer(payload: unknown): Peer | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.person_id !== "string") return null;
  if (typeof payload.display_name !== "string") return null;
  if (typeof payload.venue_id !== "string") return null;
  if (typeof payload.venue_name !== "string") return null;
  if (typeof payload.role_label !== "string") return null;
  if (typeof payload.visible_from !== "string") return null;
  if (typeof payload.visible_until !== "string") return null;

  return {
    personId: payload.person_id,
    displayName: payload.display_name,
    venueId: payload.venue_id,
    venueName: payload.venue_name,
    roleLabel: payload.role_label,
    visibleFrom: payload.visible_from,
    visibleUntil: payload.visible_until,
  };
}

/** `%{peers: [...]}` — the reply to `"list_peers"`. */
export function decodePeers(payload: unknown): readonly Peer[] | null {
  if (!isRecord(payload)) return null;

  return decodeList(payload.peers, decodePeer);
}

/**
 * `%{request_id:, requester_id:, requester_display_name:, addressee_id:,
 * addressee_display_name:, state:, requested_at:, accepted_at:, declined_at:}`
 * — `rendered_request/1`.
 *
 * **Both names are required and neither is nullable** (#73). The render heads
 * on `is_binary/1` for both, so a read path that forgot the join crashes on the
 * server rather than putting a `null` on the wire — which means a missing name
 * here is a server that has drifted, and a fallback would only hide it. There
 * is no state it would serve: `Records.with_parties/1` carries no activeness
 * predicate and no `erased_at` filter, so a lapsed request and one from an
 * erased person both arrive with a string, the second being
 * `Lifecycle.erased_display_name/0`.
 *
 * The two are kept apart rather than collapsed into a counterpart, because the
 * server cannot collapse them: that function serves four call sites and takes
 * no viewer. Which one a surface renders is this client's choice per list.
 *
 * `state` is an `Ecto.Enum` atom on the Elixir side and a string on the wire.
 * It is narrowed against `REQUEST_STATES` rather than taken as any string,
 * because everything the surface renders about a request switches on it and an
 * unknown value would fall out of an exhaustive switch with no case to catch
 * it. A state this client does not know is therefore a decode failure, which
 * surfaces as a named absence rather than as a blank badge.
 */
export function decodePeerRequest(payload: unknown): PeerRequest | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.request_id !== "string") return null;
  if (typeof payload.requester_id !== "string") return null;
  if (typeof payload.requester_display_name !== "string") return null;
  if (typeof payload.addressee_id !== "string") return null;
  if (typeof payload.addressee_display_name !== "string") return null;
  if (typeof payload.requested_at !== "string") return null;

  const state: RequestState | undefined = REQUEST_STATES.find(
    (candidate) => candidate === payload.state,
  );
  if (state === undefined) return null;

  const acceptedAt = optionalString(payload.accepted_at);
  if (acceptedAt === undefined) return null;

  const declinedAt = optionalString(payload.declined_at);
  if (declinedAt === undefined) return null;

  return {
    requestId: payload.request_id,
    requesterId: payload.requester_id,
    requesterDisplayName: payload.requester_display_name,
    addresseeId: payload.addressee_id,
    addresseeDisplayName: payload.addressee_display_name,
    state,
    requestedAt: payload.requested_at,
    acceptedAt,
    declinedAt,
  };
}

/**
 * `%{incoming: [...], outgoing: [...]}` — the reply to `"list_requests"`.
 *
 * The two lists are not the same query and the asymmetry is deliberate on the
 * server: `list_incoming_requests/1` is only what the addressee can still
 * answer, while `list_outgoing_requests/1` carries every unsuperseded approach
 * this person made, answered or not. So an outgoing list holds `declined` and
 * `accepted` entries and an incoming one does not.
 */
export function decodePeerRequests(payload: unknown): {
  readonly incoming: readonly PeerRequest[];
  readonly outgoing: readonly PeerRequest[];
} | null {
  if (!isRecord(payload)) return null;

  const incoming = decodeList(payload.incoming, decodePeerRequest);
  if (incoming === null) return null;

  const outgoing = decodeList(payload.outgoing, decodePeerRequest);
  if (outgoing === null) return null;

  return { incoming, outgoing };
}

/**
 * `%{connection_id:, peer_id:, peer_display_name:, connected_at:,
 * disconnected_at:, disconnected_by_id:, open:}` — `rendered_conversation/1`.
 *
 * `peer_display_name` is required (#73). A conversation always has one to
 * carry: the join has no activeness predicate and no `erased_at` filter, so a
 * closed conversation, one whose counterpart left the trade, and one whose
 * counterpart was erased all arrive with a string.
 *
 * Also the reply to `"accept"` and to `"disconnect"`, both of which go through
 * `rendered_connection/2` and land on the same shape. So an acceptance answers
 * with the conversation it created rather than with the request it answered,
 * which is what lets the surface open it immediately.
 */
export function decodeConversation(payload: unknown): Conversation | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.connection_id !== "string") return null;
  if (typeof payload.peer_id !== "string") return null;
  if (typeof payload.peer_display_name !== "string") return null;
  if (typeof payload.connected_at !== "string") return null;
  if (typeof payload.open !== "boolean") return null;

  const disconnectedAt = optionalString(payload.disconnected_at);
  if (disconnectedAt === undefined) return null;

  const disconnectedById = optionalString(payload.disconnected_by_id);
  if (disconnectedById === undefined) return null;

  return {
    connectionId: payload.connection_id,
    peerId: payload.peer_id,
    peerDisplayName: payload.peer_display_name,
    connectedAt: payload.connected_at,
    disconnectedAt,
    disconnectedById,
    open: payload.open,
  };
}

/** `%{conversations: [...]}` — the reply to `"list_conversations"`. */
export function decodeConversations(payload: unknown): readonly Conversation[] | null {
  if (!isRecord(payload)) return null;

  return decodeList(payload.conversations, decodeConversation);
}

/**
 * `%{message_id:, connection_id:, author_id:, author_display_name:, body:,
 * sent_at:}` — the reply to `"send"`, every entry of `"history"`, and the
 * `"peer_message"` push.
 *
 * **One decoder for all three, and it took a server change to earn that.** The
 * push used to say `at`; see this file's header and issue #31. `sent_at` is
 * still required rather than accepted alongside `at`, because accepting either
 * is how one entity keeps two key names for ever.
 *
 * `author_display_name` is #73's, spelled exactly as `decodeRoomMessage`
 * spells it — a message's author is one entity whichever room or conversation
 * carried the words. It is required on all three paths because
 * `peer_channel_test.exs` pins the push's key set against the reply's, so it
 * reaches all three or none.
 */
export function decodePeerMessage(payload: unknown): PeerMessage | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.message_id !== "string") return null;
  if (typeof payload.connection_id !== "string") return null;
  if (typeof payload.author_id !== "string") return null;
  if (typeof payload.author_display_name !== "string") return null;
  if (typeof payload.body !== "string") return null;
  if (typeof payload.sent_at !== "string") return null;

  return {
    messageId: payload.message_id,
    connectionId: payload.connection_id,
    authorId: payload.author_id,
    authorDisplayName: payload.author_display_name,
    body: payload.body,
    sentAt: payload.sent_at,
  };
}

/** `%{messages: [...]}` — the reply to `"history"`, oldest first. */
export function decodePeerMessages(payload: unknown): readonly PeerMessage[] | null {
  if (!isRecord(payload)) return null;

  return decodeList(payload.messages, decodePeerMessage);
}
