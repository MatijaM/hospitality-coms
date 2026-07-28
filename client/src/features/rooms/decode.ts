/**
 * Turning channel payloads and HTTP bodies into the types the room surfaces
 * render.
 *
 * Same posture as `src/api/decode.ts`: every decoder returns `null` for "this
 * is not that", never a partial value and never a throw. A channel payload is
 * `unknown` for the same reason an HTTP body is — `phoenix` hands over whatever
 * the frame carried — and a field the server renames has to surface as a named
 * absence rather than as `undefined` in a message bubble.
 *
 * The shapes are `HospitalityComsWeb.RoomChannel`'s `rendered/1` and `closed/4`,
 * the two `join/3` replies, and `HospitalityComsWeb.RoomController`'s four
 * bodies. Keys are the wire's snake_case; the types are this client's camelCase,
 * and this file is the only place the two meet.
 *
 * **One file for both transports on purpose.** A message is one entity, and
 * `RoomController.render_message/1` calls `RoomChannel.rendered/1` rather than
 * respelling it — so `decodeRoomMessage` is the decoder for both, and a
 * rendering that drifted on one side would fail the other's tests too.
 */

import { isRecord } from "../../api/decode";
import type {
  MessagePage,
  RoomClosure,
  RoomMessage,
  ShiftRoomListing,
  VenueRoomListing,
} from "./room";

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

/**
 * Decodes an array whose every element must decode, or nothing.
 *
 * All-or-nothing rather than filtering: a list silently one entry short is a
 * room somebody cannot find, with no sentence anywhere saying why. One bad
 * entry fails the whole body, which the caller reports as
 * `malformed_response`.
 */
function decodeEach<T>(
  value: unknown,
  one: (entry: unknown) => T | null,
): readonly T[] | null {
  if (!Array.isArray(value)) return null;

  const decoded: T[] = [];

  for (const entry of value) {
    const item = one(entry);
    if (item === null) return null;
    decoded.push(item);
  }

  return decoded;
}

/** `%{venue_id:, name:}` — one entry of `GET /api/venue-rooms`. */
export function decodeVenueRoom(value: unknown): VenueRoomListing | null {
  if (!isRecord(value)) return null;
  if (typeof value.venue_id !== "string") return null;
  if (typeof value.name !== "string") return null;

  return { venueId: value.venue_id, name: value.name };
}

/** `%{venue_rooms: [...]}` — the body of `GET /api/venue-rooms`. */
export function decodeVenueRooms(body: unknown): readonly VenueRoomListing[] | null {
  if (!isRecord(body)) return null;

  return decodeEach(body.venue_rooms, decodeVenueRoom);
}

/**
 * One entry of `GET /api/venues/:venue_id/shift-rooms`.
 *
 * Every field is required, `shift_type_name` included: it is the only thing in
 * the payload a worker can read, and a room whose name failed to decode would
 * render as a term with no subject.
 */
export function decodeShiftRoom(value: unknown): ShiftRoomListing | null {
  if (!isRecord(value)) return null;
  if (typeof value.shift_room_id !== "string") return null;
  if (typeof value.venue_id !== "string") return null;
  if (typeof value.shift_type_name !== "string") return null;
  if (typeof value.starts_at !== "string") return null;
  if (typeof value.ends_at !== "string") return null;
  if (typeof value.closes_at !== "string") return null;

  return {
    shiftRoomId: value.shift_room_id,
    venueId: value.venue_id,
    shiftTypeName: value.shift_type_name,
    startsAt: value.starts_at,
    endsAt: value.ends_at,
    closesAt: value.closes_at,
  };
}

/** `%{shift_rooms: [...]}` — the body of the shift-room list. */
export function decodeShiftRooms(body: unknown): readonly ShiftRoomListing[] | null {
  if (!isRecord(body)) return null;

  return decodeEach(body.shift_rooms, decodeShiftRoom);
}

/**
 * `%{messages: [...], complete:}` — the body of either history route.
 *
 * `complete` is required and is not defaulted. Its absence would silently
 * become "the whole history is here", which is the one reading that makes the
 * bound invisible to whoever is looking at the screen.
 */
export function decodeMessagePage(body: unknown): MessagePage | null {
  if (!isRecord(body)) return null;
  if (typeof body.complete !== "boolean") return null;

  const messages = decodeEach(body.messages, decodeRoomMessage);
  if (messages === null) return null;

  return { messages, complete: body.complete };
}
