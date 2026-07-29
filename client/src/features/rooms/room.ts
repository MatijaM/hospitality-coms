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

import { isTopicId, normaliseTopicId } from "../../socket/topic-id";

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
 */
export type HistoryExtent = "recent" | "all";

/** One venue room, as `GET /api/venue-rooms` renders it. */
export type VenueRoomListing = {
  readonly venueId: string;
  /** The venue's own name. This is what stops the list being uuid prefixes. */
  readonly name: string;
};

/**
 * One shift room, as `GET /api/venues/:venue_id/shift-rooms` renders it.
 *
 * A shift room has **no display name of its own** — the server sends the shift
 * *type*'s name plus the term, and `shiftRoomLabel` is where the two become a
 * sentence. See that function for why the composing happens here.
 */
export type ShiftRoomListing = {
  readonly shiftRoomId: string;
  readonly venueId: string;
  readonly shiftTypeName: string;
  readonly startsAt: string;
  readonly endsAt: string;
  /**
   * When the room stops accepting messages: `ends_at` plus the type's grace.
   *
   * **Formatted, and never compared against a clock here** — the two are
   * different things and only the second is forbidden.
   * `HospitalityComs.Clock` is offsettable and the demo moves it, while this
   * browser's clock is real, so a client-side open/closed badge would be wrong
   * during exactly the demo the offset exists for. Whether a room accepts a
   * message is the server's answer to a send, which is where `SendBar` already
   * gets it. None of that is an argument for showing somebody
   * `2026-03-09T21:30:00Z`, which is what this used to do:
   * `instantLabel` renders it the way the term beside it is already rendered.
   */
  readonly closesAt: string;
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
 * What a shift room is called on screen: the shift type, then the term.
 *
 * **The term is not decoration.** Two Tuesdays of one shift type are two rooms
 * with one name, so a label that were only `shiftTypeName` would be as
 * ambiguous as the uuid it replaced — differently, and less obviously.
 *
 * **And the formatting is here rather than on the server.** Rendering a shift
 * time means choosing a timezone. `venues` carries one and this device carries
 * another, and the worker reading the label is the one holding the device — so
 * the choice is made where the answer is known. It is also where every other
 * instant on this surface is already formatted.
 */
export function shiftRoomLabel(room: ShiftRoomListing): string {
  return `${room.shiftTypeName} · ${termLabel(room.startsAt, room.endsAt)}`;
}

// Built once: `Intl.DateTimeFormat` is expensive to construct and this runs
// per room per render.
const DAY_AND_TIME = new Intl.DateTimeFormat(undefined, {
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
});

const TIME_ONLY = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit",
  minute: "2-digit",
});

/**
 * The calendar day an instant falls on, as a string that is only ever compared
 * with another one from this same formatter.
 *
 * **It is built exactly like the two above and that is the whole point.** All
 * three pass `undefined` for the locale and name no `timeZone`, so all three
 * resolve the same one — this device's. "Does this shift end on another day"
 * is a question with a different answer in every timezone, and the only answer
 * that is not a lie is the one taken in the timezone the label is *rendered*
 * in. `getUTCDate` would ask it in UTC and `venues` carries a timezone that
 * would ask it where the shift happens; a worker in Auckland reading a term
 * that is one evening to them would be told it spans two days, or the reverse.
 *
 * The year is in there because two instants a year apart share a day and a
 * month. Nothing in a shift term goes near that, and a comparison that is
 * right by luck is one somebody has to re-derive later.
 */
const CALENDAR_DAY = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "numeric",
  day: "numeric",
});

/**
 * One instant, with its day: `9 Mar 21:30`, or the raw string if it will not
 * parse.
 *
 * Exported because a shift room's `closesAt` is rendered on its own, beside
 * the term this composes — and it is what `termLabel` writes an endpoint with
 * whenever that endpoint's day has to be said out loud.
 *
 * The fallback is deliberate: an instant this client cannot read is still
 * something the worker can compare against another one, and a label reading
 * "Invalid Date" would be worse than the ISO string it replaced.
 */
export function instantLabel(value: string): string {
  const instant = new Date(value);

  return Number.isNaN(instant.getTime()) ? value : DAY_AND_TIME.format(instant);
}

/**
 * `9 Mar 13:00–21:00`, or `9 Mar 23:00–10 Mar 07:00` when the term ends on
 * another day, or the raw instants if either will not parse.
 *
 * **The second form is the common case, not the edge case.** This is a
 * hospitality product and a late shift crossing midnight is the ordinary shape
 * of the working day — the demo manifest's own live shift room is eight hours
 * from an hour ago, so it is overnight whenever the manifest is seeded after
 * about four in the afternoon. Writing the end as a time alone made that read
 * `Kitchen · 9 Mar 23:00–07:00`, which says the room closes sixteen hours
 * before it opens.
 *
 * Which day the *reader* is on is the question `CALENDAR_DAY` answers; see
 * there for why it cannot be asked in UTC.
 */
function termLabel(startsAt: string, endsAt: string): string {
  const start = new Date(startsAt);
  const end = new Date(endsAt);

  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
    return `${startsAt}–${endsAt}`;
  }

  const sameDay = CALENDAR_DAY.format(start) === CALENDAR_DAY.format(end);

  return `${DAY_AND_TIME.format(start)}–${sameDay ? TIME_ONLY.format(end) : DAY_AND_TIME.format(end)}`;
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
