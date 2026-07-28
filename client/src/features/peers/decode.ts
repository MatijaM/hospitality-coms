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
 * ## One entity, two key names, and this is where that is absorbed
 *
 * A message reaches this client down two paths with **different keys for its
 * instant**:
 *
 *   * the reply to `"send"` and each entry in `"history"` are
 *     `rendered_message/1`, which says `sent_at`;
 *   * the `"peer_message"` push is `HospitalityComs.Peers`' announcement,
 *     stamped by `PeerChannel.stamped/1`, which says `at` — as every
 *     announcement on that topic does.
 *
 * Both say `message_id` (U8's review fixed the half that did not). So there are
 * two decoders and one type, and a single decoder with a fallback is
 * deliberately not it: a fallback would also accept a reply carrying neither
 * key, which is the drift this file exists to name.
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
 * `%{person_id:, venue_id:, venue_name:, role_label:, visible_from:,
 * visible_until:}` — `rendered_peer/1`.
 *
 * Every field is required and none is nullable: `venues.name` and
 * `engagements.role_label` are both `null: false`, and `Visibility.t()` types
 * the two labels as `String.t()` rather than `String.t() | nil`.
 */
export function decodePeer(payload: unknown): Peer | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.person_id !== "string") return null;
  if (typeof payload.venue_id !== "string") return null;
  if (typeof payload.venue_name !== "string") return null;
  if (typeof payload.role_label !== "string") return null;
  if (typeof payload.visible_from !== "string") return null;
  if (typeof payload.visible_until !== "string") return null;

  return {
    personId: payload.person_id,
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
 * `%{request_id:, requester_id:, addressee_id:, state:, requested_at:,
 * accepted_at:, declined_at:}` — `rendered_request/1`.
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
  if (typeof payload.addressee_id !== "string") return null;
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
    addresseeId: payload.addressee_id,
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
 * `%{connection_id:, peer_id:, connected_at:, disconnected_at:,
 * disconnected_by_id:, open:}` — `rendered_conversation/1`.
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
  if (typeof payload.connected_at !== "string") return null;
  if (typeof payload.open !== "boolean") return null;

  const disconnectedAt = optionalString(payload.disconnected_at);
  if (disconnectedAt === undefined) return null;

  const disconnectedById = optionalString(payload.disconnected_by_id);
  if (disconnectedById === undefined) return null;

  return {
    connectionId: payload.connection_id,
    peerId: payload.peer_id,
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
 * `%{message_id:, connection_id:, author_id:, body:, sent_at:}` —
 * `rendered_message/1`, which is the reply to `"send"` and every entry of
 * `"history"`.
 */
export function decodePeerMessage(payload: unknown): PeerMessage | null {
  return decodeMessage(payload, "sent_at");
}

/**
 * `%{message_id:, connection_id:, author_id:, body:, at:}` — the
 * `"peer_message"` push.
 *
 * The same entity as `decodePeerMessage`'s and one key different. See this
 * file's header: the push is the announcement shape, and every announcement on
 * the peer topic stamps its instant as `at`.
 */
export function decodePeerMessageNotice(payload: unknown): PeerMessage | null {
  return decodeMessage(payload, "at");
}

function decodeMessage(
  payload: unknown,
  instantKey: "sent_at" | "at",
): PeerMessage | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.message_id !== "string") return null;
  if (typeof payload.connection_id !== "string") return null;
  if (typeof payload.author_id !== "string") return null;
  if (typeof payload.body !== "string") return null;

  const sentAt = payload[instantKey];
  if (typeof sentAt !== "string") return null;

  return {
    messageId: payload.message_id,
    connectionId: payload.connection_id,
    authorId: payload.author_id,
    body: payload.body,
    sentAt,
  };
}

/** `%{messages: [...]}` — the reply to `"history"`, oldest first. */
export function decodePeerMessages(payload: unknown): readonly PeerMessage[] | null {
  if (!isRecord(payload)) return null;

  return decodeList(payload.messages, decodePeerMessage);
}
