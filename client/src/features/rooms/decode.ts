/**
 * Turning channel payloads into the types the room surfaces render.
 *
 * Same posture as `src/api/decode.ts`: every decoder returns `null` for "this
 * is not that", never a partial value and never a throw. A channel payload is
 * `unknown` for the same reason an HTTP body is — `phoenix` hands over whatever
 * the frame carried — and a field the server renames has to surface as a named
 * absence rather than as `undefined` in a message bubble.
 *
 * The shapes are `HospitalityComsWeb.RoomChannel`'s `rendered/1` and `closed/4`,
 * and the two `join/3` replies. Keys are the wire's snake_case; the types are
 * this client's camelCase, and this file is the only place the two meet.
 */

import { isRecord } from "../../api/decode";
import type { RoomClosure, RoomMessage } from "./room";

/**
 * `%{id:, body:, sent_at:, author_engagement_id:}` — `RoomChannel.rendered/1`.
 *
 * `sent_at` stays a string. It is `DateTime.to_iso8601/1` of an instant the
 * server stamped, and parsing it into a `Date` here would invite this client to
 * compute with it — which is `HospitalityComs.Clock`'s job on the other side,
 * and the one thing KTD5 says a long-lived process must not do for itself.
 */
export function decodeRoomMessage(payload: unknown): RoomMessage | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.id !== "string") return null;
  if (typeof payload.body !== "string") return null;
  if (typeof payload.sent_at !== "string") return null;
  if (typeof payload.author_engagement_id !== "string") return null;

  return {
    id: payload.id,
    body: payload.body,
    sentAt: payload.sent_at,
    authorEngagementId: payload.author_engagement_id,
  };
}

/**
 * The engagement id out of a join reply.
 *
 * Both replies carry `engagement_id`; they differ in whether the room is named
 * `venue_id` or `shift_room_id`, and this client already knows which room it
 * joined. The engagement id is the part worth keeping — it is what a message's
 * `author_engagement_id` is compared against to tell this session's own
 * messages from everybody else's, which is the only identity U7 puts on the
 * wire and the only one KTD15b permits.
 */
export function decodeJoinedEngagementId(payload: unknown): string | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.engagement_id !== "string") return null;

  return payload.engagement_id;
}

/**
 * `%{engagement_id:, at:, venue_id | shift_room_id}` — `RoomChannel.closed/4`.
 *
 * The reason is not in the payload: it is which event the server pushed,
 * `"access_revoked"` or `"access_suspended"`, so the caller supplies it and
 * this decoder does not invent one.
 */
export function decodeRoomClosure(
  reason: RoomClosure["reason"],
  payload: unknown,
): RoomClosure | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.engagement_id !== "string") return null;
  if (typeof payload.at !== "string") return null;

  return { reason, engagementId: payload.engagement_id, at: payload.at };
}
