/**
 * A shift room, as both halves of this API render it — one type, one decoder,
 * one label.
 *
 * ## Why it is here and not in a feature directory
 *
 * `HospitalityComsWeb.RoomController.rendered_shift_room/1` is a **public**
 * function, and its docstring says exactly why: *"`EmployerController` renders
 * the same rooms from the employer's side, and a second shape carrying
 * `shift_type_id` where this one carries `shift_type_name` would be one entity
 * with two spellings on one API."* The server spent an export preventing that
 * divergence. Giving this client two `ShiftRoomListing` types and two decoders
 * would reintroduce it one layer up, where
 * `docs/solutions/conventions/one-entity-one-key-name-and-decoders-that-refuse-the-other.md`
 * records three occurrences already.
 *
 * The alternative was `features/employer/` importing from `features/rooms/`,
 * which is precisely the debt `src/app/instant.ts` exists to have paid off:
 * *"a cross-feature import into a feature directory, which nothing else in
 * `src/features/` production code does."* So the entity moved on its second
 * caller and the first delegates — `use-fetched.ts`'s manoeuvre for `Loaded`,
 * `topic-id.ts`'s for `isRoomId`, and on the Elixir side `EntityId`'s and
 * `Extent`'s.
 *
 * **The envelopes stay in their features**, because the two routes disagree
 * about them: `GET /api/venues/:venue_id/shift-rooms` answers
 * `{shift_rooms: [...]}` and `GET /api/employer/venues/:venue_id/shift-rooms`
 * answers `{shift_rooms: [...], complete}`. A feature owns its paths and its
 * envelopes; the *entity* is the thing there can only be one of.
 *
 * `features/rooms/room.ts` and `features/rooms/decode.ts` re-export what they
 * wrote, so no rooms file changed across the move. Those are shims and not a
 * second home: a new caller imports from here.
 */

import { isRecord } from "../api/decode";
import { termLabel } from "./instant";

/**
 * One shift room, as `RoomController.rendered_shift_room/1` puts it on the
 * wire.
 *
 * A shift room has **no display name of its own** — the server sends the shift
 * *type*'s name plus the term, and `shiftRoomLabel` is where the two become a
 * sentence.
 *
 * There is no `shiftTypeId` here because there is none on the wire. The
 * employer's own plan asked for one so that a client could join the type's name
 * itself; KTD-E7 recommended the preload instead and U3 took it, so the name
 * arrives resolved and there is nothing to join against.
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
   * message is the server's answer to a send.
   */
  readonly closesAt: string;
};

/**
 * One entry of either shift-room list.
 *
 * Every field is required, `shift_type_name` included: it is the only thing in
 * the payload a reader can read, and a room whose name failed to decode would
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

/**
 * What a shift room is called on screen: the shift type, then the term.
 *
 * **The term is not decoration.** Two Tuesdays of one shift type are two rooms
 * with one name, so a label that were only `shiftTypeName` would be as
 * ambiguous as the uuid it replaced — differently, and less obviously.
 *
 * **And the formatting is here rather than on the server.** Rendering a shift
 * time means choosing a timezone. `venues` carries one and this device carries
 * another, and whoever is reading the label is the one holding the device — so
 * the choice is made where the answer is known. `termLabel` is also what writes
 * the second day out loud when a shift crosses local midnight, which in
 * hospitality is the ordinary case rather than the edge one.
 */
export function shiftRoomLabel(room: ShiftRoomListing): string {
  return `${room.shiftTypeName} · ${termLabel(room.startsAt, room.endsAt)}`;
}
