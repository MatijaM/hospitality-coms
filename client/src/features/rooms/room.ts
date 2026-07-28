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
 * ## Why a room reference is a thing the client holds rather than fetches
 *
 * **There is no endpoint that lists rooms.** `lib/hospitality_coms_web/router.ex`
 * declares four API routes — the three log-in routes and `GET /api/me` — and
 * nothing else. U6 built `HospitalityComs.Rooms.list_venue_rooms/1` and
 * `list_readable_shift_rooms/1` as context functions with no HTTP surface, and
 * neither room channel carries an event that enumerates rooms either: a join
 * replies with the room and the engagement, and that is all.
 *
 * So the list here is the worker's own, held in this browser, and a room is
 * added by naming its id. That is a real limitation and it is written down
 * rather than papered over with a fabricated endpoint. Everything *about* a
 * room — whether this session may read it, whether it may write to it, whether
 * its access has ended — still comes from the server on every join and every
 * send, which is where KTD8 puts it. The client holds a bookmark, never an
 * authority.
 */

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
 * venue-local by construction. There is no name here because there is no name
 * in the employer zone to put one from.
 */
export type RoomMessage = {
  readonly id: string;
  readonly body: string;
  readonly sentAt: string;
  readonly authorEngagementId: string;
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Whether a string is the id shape a topic suffix may carry.
 *
 * The same rule `HospitalityComsWeb.ChannelAuth.topic_id/1` applies — 36 bytes,
 * then a uuid cast — and it is checked here for the worker's benefit rather
 * than the server's. The server answers a malformed suffix with exactly what it
 * answers an unknown room, deliberately, so that a refusal enumerates nothing
 * (AE1). That is right for the server and useless to somebody who has just
 * mistyped their own paste, so this client tells them about their own input
 * before it puts it on a socket. It learns nothing by doing so: the value came
 * from this browser.
 */
export function isRoomId(value: string): boolean {
  return value.length === 36 && UUID.test(value);
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
  const trimmed = value.trim().toLowerCase();

  return isRoomId(trimmed) ? trimmed : null;
}
