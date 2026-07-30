/**
 * What a room is to this client: a kind, an id, and a topic derived from both.
 *
 * ## Two kinds, because the server routes two topics
 *
 * `HospitalityComsWeb.PersonSocket` routes `venue_room:*` and `shift_room:*`,
 * and the suffix is the venue's id or the shift room's id respectively. They
 * are not interchangeable: a venue room's roll is the venue's active
 * engagements, a shift room's is a roster period overlapping the room's window,
 * and the two channels answer a send with different refusals. So the kind is
 * part of the reference rather than something guessed from the id's shape.
 *
 * ## Two lists, and why the local one survives the server's
 *
 * The server now lists rooms. `GET /api/venue-rooms` answers the venue rooms
 * this person is in **by name**, and `GET /api/venues/:venue_id/shift-rooms`
 * answers the shift rooms they may read at one of them —
 * `features/rooms/rooms-api.ts` is where those live. So a room is browsed to
 * rather than pasted, and no list on this surface is uuid prefixes.
 *
 * The **local** list is kept anyway, and it is not a cache of the server's. It
 * holds `barred`, which is the one thing on this surface that was *learned*
 * rather than fetched: nothing on the wire says in advance that a shift room is
 * past its `closes_at` or that a roster period has ended, so the client is told
 * once, by a refused send, and remembers (see `room-store.ts`). It is also what
 * keeps a room open across a reload.
 *
 * Neither list is an authority. Everything *about* a room — whether this
 * session may read it, whether it may write to it, whether its access has
 * ended — still comes from the server on every join and every send, which is
 * where KTD8 puts it. A browsed room and a pasted one take the same path.
 */

import type { ListExtent } from "../../api/types";
import { instantLabel, termLabel } from "../../app/instant";
import type { ShiftRoomListing } from "../../app/shift-room";
import { shiftRoomLabel } from "../../app/shift-room";
import { isTopicId, normaliseTopicId } from "../../socket/topic-id";

/**
 * Both instant renderings, re-exported under the names the rooms surface wrote
 * them with.
 *
 * They moved to `src/app/instant.ts` when U4's employer and claim surfaces
 * became their second and third callers — this file said that was the
 * condition, and see there for the argument. The re-export is what keeps
 * `rooms-route.tsx`, `room-view.tsx` and both rooms test files unchanged across
 * the move, which is `use-room-lists.ts`'s manoeuvre for `Loaded` and
 * `topic-id.ts`'s for `isRoomId`.
 *
 * **It is a shim and not a second home.** A new caller imports from
 * `src/app/instant.ts`; importing from here is what made these cross-feature in
 * the first place.
 */
export { instantLabel, termLabel };

/**
 * The shift room itself, re-exported under the names this surface wrote it
 * with.
 *
 * It moved to `src/app/shift-room.ts` when U5's employer shift panel became its
 * second caller, for `instantLabel`'s reason one entity further in: the server
 * renders a shift room through **one** public function for both halves of the
 * API, and two decoders here would put the divergence back that
 * `rendered_shift_room/1` was exported to prevent. Same shim rule as above.
 */
export type { ShiftRoomListing };
export { shiftRoomLabel };

/** The two topics `PersonSocket` routes for a room. */
export type RoomKind = "venue" | "shift";

export type RoomRef = {
  readonly kind: RoomKind;
  /** `venues.id` for a venue room, `shift_rooms.id` for a shift room. */
  readonly id: string;
};

/**
 * Why this session cannot write to a room it can read.
 *
 * Both are learned from a refused send, because nothing on the wire says either
 * in advance — see `room-store.ts`.
 *
 *   * `room_closed` — the shift room's `closes_at` has passed. KTD5's grace
 *     window: refused on an open channel, with no rejoin and no job having run.
 *   * `not_rostered` — the roster period that earned the reading has ended.
 *     KTD6b: no write withdraws access a period already earned, so the room
 *     stays readable and only the composer goes.
 */
export type SendBar = "room_closed" | "not_rostered";

export type RoomEntry = {
  readonly ref: RoomRef;
  /** What the server has told this client it may not do here, if anything. */
  readonly barred: SendBar | null;
};

/**
 * A message as `HospitalityComsWeb.RoomChannel.rendered/1` puts it on the wire.
 *
 * Attribution is the **engagement**, never the person (KTD15b), and it is
 * venue-local by construction.
 *
 * `authorDisplayName` is the author's own chosen name (#66) and
 * `authorRoleLabel` is what the venue calls the job they do there (#65). Both
 * are joined by the server on every read rather than stored beside the message
 * — so the name follows a rename, the label follows a corrected engagement, and
 * an erased author's history renders under two non-identifying constants with
 * no row in `room_messages` having been touched.
 *
 * **All three are on the wire and all three are rendered.** Neither the name
 * nor the label is unique — a venue can hold two Bartenders and two people can
 * draw the same character — so the engagement id is the only one of the three
 * that tells two speakers apart, and it is venue-local where the name is not.
 */
export type RoomMessage = {
  readonly id: string;
  readonly body: string;
  readonly sentAt: string;
  readonly authorEngagementId: string;
  readonly authorDisplayName: string;
  readonly authorRoleLabel: string;
};

/**
 * A page of a room's history, as `HospitalityComs.Rooms.MessagePage` renders it.
 *
 * `complete` is the server's answer to "is this the whole history", and it is
 * not derivable here: a full page and a full history of the same length are the
 * same list. It is what decides whether the "load the whole history" control
 * exists, which is why the control cannot be offered unconditionally without
 * lying to somebody whose room holds three messages.
 */
export type MessagePage = {
  readonly messages: readonly RoomMessage[];
  readonly complete: boolean;
};

/**
 * How much of a room's history to ask for.
 *
 * The server takes a **word**, never a number: the bound is
 * `HospitalityComs.Rooms.recent_message_limit/0` and lives in the context, so
 * that the unbounded read is not one forgetful caller away. This client does
 * not know what `"recent"` amounts to and must not try to.
 *
 * It is `src/api/types.ts`'s `ListExtent` under this surface's own name. The
 * employer's shift-room list is bounded by the same vocabulary and a different
 * number, and `HospitalityComsWeb.Extent` is one module for both callers on the
 * server.
 */
export type HistoryExtent = ListExtent;

/** One venue room, as `GET /api/venue-rooms` renders it. */
export type VenueRoomListing = {
  readonly venueId: string;
  /** The venue's own name. This is what stops the list being uuid prefixes. */
  readonly name: string;
};

/**
 * The terminal notice a room channel pushes on its way out.
 *
 * The two reasons are told apart on the wire because they mean opposite things
 * to whoever is reading: `access_revoked` is the employer closing a term,
 * `access_suspended` is this person opting out of this venue's room — possibly
 * from another device, which is why the channel hears about it at all (KTD18).
 */
export type RoomClosure = {
  readonly reason: "revoked" | "suspended";
  readonly engagementId: string;
  readonly at: string;
};

/** The topic string, which is the only place a kind becomes a prefix. */
export function roomTopic(ref: RoomRef): string {
  switch (ref.kind) {
    case "venue":
      return `venue_room:${ref.id}`;
    case "shift":
      return `shift_room:${ref.id}`;
  }
}

/** A stable key for a reference, for React lists and for store lookups. */
export function roomKey(ref: RoomRef): string {
  return roomTopic(ref);
}

export function sameRoom(one: RoomRef, other: RoomRef): boolean {
  return one.kind === other.kind && one.id === other.id;
}

/** What the surface calls each kind. */
export function roomKindLabel(kind: RoomKind): string {
  switch (kind) {
    case "venue":
      return "Venue room";
    case "shift":
      return "Shift room";
  }
}

/**
 * Whether a string is the id shape a room topic's suffix may carry.
 *
 * The rule itself moved to `src/socket/topic-id.ts` when the profile surface
 * became its third caller — `peer.ts` named that as the condition for hoisting
 * it. The name stays here because this is what the rooms call it and every call
 * site reads better for it.
 */
export function isRoomId(value: string): boolean {
  return isTopicId(value);
}

/**
 * An id as this client will use it, or `null` if it is not one.
 *
 * **The lowercasing is load-bearing, and not for tidiness.** `Ecto.UUID.cast/1`
 * accepts either case and Postgres stores one value, so `venue_room:ABC…` and
 * `venue_room:abc…` reach the same rows — but the topic goes to
 * `Phoenix.PubSub` as a **literal string**, and `broadcast!/3` fans out on
 * exactly that. Two sessions naming one venue in different cases would sit in
 * the same database room, write to the same table, and see none of each
 * other's messages: the room would look broken to both of them and correct to
 * anybody reading the rows.
 *
 * Every id this client holds goes through here — the paste box and the stored
 * list both — so the two paths cannot disagree about the rule the way they
 * used to.
 */
export function normaliseRoomId(value: string): string | null {
  return normaliseTopicId(value);
}

/**
 * A room's fetched history followed by what has arrived since, each message
 * once.
 *
 * The overlap is real rather than theoretical: the history is fetched over HTTP
 * and the channel is joined separately, so a message sent between the two
 * arrives on both paths. Keying on the id is the same manoeuvre `use-room.ts`
 * already makes for the send reply and the broadcast of one message.
 */
export function mergeMessages(
  history: readonly RoomMessage[],
  live: readonly RoomMessage[],
): readonly RoomMessage[] {
  const seen = new Set(history.map((message) => message.id));

  return [...history, ...live.filter((message) => !seen.has(message.id))];
}
