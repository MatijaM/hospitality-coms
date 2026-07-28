/**
 * The codes a room channel can refuse with, and what to show a worker for each.
 *
 * `src/app/failure-message.ts`'s argument applies here unchanged: the
 * envelope's own documentation says `code` is the machine-readable
 * discriminator and `message` is "for a human reading a log", so the server's
 * message is not rendered and the copy is keyed on the code.
 *
 * It is a **separate switch** from `failureMessage` rather than a shared one.
 * The codes overlap in spelling and not in meaning: `unauthorized` from
 * `POST /api/log-in/token` is a magic link that has been spent and the answer
 * is "ask for a new link", while `unauthorized` from `VenueRoomChannel.join/3`
 * is an engagement that has ended and there is no link to ask for. One switch
 * would have to pick one of those sentences and be wrong about the other.
 *
 * `fields` is the exception and is rendered as it arrives, for the reason it is
 * there: those messages come from Ecto's changeset traversal and name the input
 * — `body` — that the worker actually typed.
 *
 * Every switch here is exhaustive, so a code added to `ROOM_ERROR_CODES` fails
 * the build rather than falling through to silence.
 */

import type { RequestFailure } from "../../api/errors";
import type { ChannelFailure } from "../../socket/channel-failure";
import type { SendBar } from "./room";

/**
 * The status atoms the two room channels are known to refuse with, traced
 * through `HospitalityComsWeb.VenueRoomChannel`, `ShiftRoomChannel` and
 * `RoomChannel`:
 *
 *   * `unauthorized` — every join refusal, and a send by a session that is not
 *     in the room. The refusal enumerates nothing, so an ended engagement, a
 *     suspension, a room at another venue and an id that names nothing are all
 *     this one code (AE1).
 *   * `bad_request` — `"send"` without a string `body`, and any event neither
 *     channel handles.
 *   * `forbidden` — a shift room this session may read but is not rostered on.
 *     KTD6b: a roster period already elapsed still earns the reading.
 *   * `gone` — a shift room past its `closes_at`. The grace window (KTD5),
 *     answered on the same channel process with no rejoin and no job having run.
 *   * `unprocessable_entity` — the message itself was rejected, with `fields`
 *     naming `body`.
 *
 * **This list is the rooms' own**, not the transport's. `channel-failure.ts`
 * names no codes precisely so that U8's peer codes cannot force a case into
 * this file's switches; anything outside this list arrives as `unrecognised`.
 */
export const ROOM_ERROR_CODES = [
  "unauthorized",
  "bad_request",
  "forbidden",
  "gone",
  "unprocessable_entity",
] as const;

export type RoomErrorCode = (typeof ROOM_ERROR_CODES)[number];

/** A channel refusal drawn from the rooms' vocabulary. */
export type RoomFailure = ChannelFailure<RoomErrorCode>;

export function isRoomErrorCode(code: string): code is RoomErrorCode {
  return (ROOM_ERROR_CODES as readonly string[]).includes(code);
}

export function refusalMessage(failure: RoomFailure): string {
  switch (failure.kind) {
    case "channel_timeout":
      return "The server did not answer in time. Your message may or may not have been sent — check the room before sending it again.";
    case "malformed_refusal":
      return "The server refused in a way this client does not understand. Nothing was sent.";
    case "channel_error":
    case "channel_field_error":
      return codeMessage(failure.code, failure.rawCode);
  }
}

function codeMessage(code: RoomErrorCode | "unrecognised", rawCode: string): string {
  switch (code) {
    case "unauthorized":
      return "You are not in this room. Either the engagement that let you in has ended, or the room is not one you can reach.";
    case "bad_request":
      return "That could not be sent as written.";
    case "forbidden":
      return "You are no longer on this shift's roster. You can still read everything that was said, but you cannot post.";
    case "gone":
      return "This room is closed. Nothing more can be posted to it, and everything already here stays readable.";
    case "unprocessable_entity":
      return "That message was not accepted.";
    case "unrecognised":
      return `The server refused for a reason this client does not know about (${rawCode}).`;
  }
}

/**
 * What a refused send means for the composer from here on.
 *
 * Two of the five codes say something durable about the **room** — it is
 * closed, or this session is off its roster — and both leave a room that is
 * still perfectly readable. Those are bars: remembered, rendered, and cleared
 * only by "Check again".
 *
 * `unauthorized` is deliberately **not** one of them, and it is not "no
 * consequence" either. It says nothing about the room and everything about
 * whether this session is still in it, which is a question `join/3` re-derives
 * — so `use-room.ts` answers it at the connection level instead, and re-opening
 * the room is what asks again. Making it a bar would persist a guess about
 * access that the very next join settles for free.
 *
 * The remaining three are about the message or about this attempt, and change
 * nothing at all.
 */
export function barFromRefusal(failure: RoomFailure): SendBar | null {
  if (failure.kind !== "channel_error" && failure.kind !== "channel_field_error") {
    return null;
  }

  switch (failure.code) {
    case "gone":
      return "room_closed";
    case "forbidden":
      return "not_rostered";
    case "unauthorized":
    case "bad_request":
    case "unprocessable_entity":
    case "unrecognised":
      return null;
  }
}

/**
 * Whether a refused send means this session is no longer in the room at all.
 *
 * Only `unauthorized`, which is what both channels answer a send from a
 * session `fetch_venue_room_membership/2` or `fetch_shift_room_reader/2` no
 * longer returns an engagement for.
 */
export function endsAccess(failure: RoomFailure): boolean {
  return (
    (failure.kind === "channel_error" || failure.kind === "channel_field_error") &&
    failure.code === "unauthorized"
  );
}

/** How a room whose composer is barred describes itself. */
export function barMessage(bar: SendBar): string {
  switch (bar) {
    case "room_closed":
      return "This room is closed. It is read-only from here.";
    case "not_rostered":
      return "You are not on this shift's roster. This room is read-only for you.";
  }
}

/**
 * What to show when one of the four HTTP room reads fails.
 *
 * A **third** switch, and the reason is the one that already separates the two
 * above it: the codes overlap in spelling and not in meaning.
 * `app/failure-message.ts` renders `not_found` as "That address does not exist
 * on this server", which is right for a route the router did not recognise and
 * wrong for a room — `HospitalityComsWeb.RoomController` answers `404` for a
 * room that does not exist, a room this session may not reach, an engagement
 * that has ended and a suspension in force, identically and on purpose (AE1).
 * One switch would have to pick one of those sentences and be wrong about the
 * others.
 *
 * `bad_request` is `extent` — which this client is the only thing that sets, so
 * it is a bug here rather than something a worker can correct. It says so.
 */
export function readFailureMessage(failure: RequestFailure): string {
  switch (failure.kind) {
    case "network_error":
      return "That list could not be loaded. Check your connection and try again.";
    case "malformed_response":
      return `The server answered in a way this client does not understand (${failure.status.toString()}).`;
    case "api_error":
    case "api_field_error":
      return readCodeMessage(failure.code, failure.status);
  }
}

function readCodeMessage(code: string, status: number): string {
  switch (code) {
    case "not_found":
      return "That room is not one you can reach. Either it does not exist, the engagement that let you in has ended, or you have suspended it.";
    case "unauthorized":
      return "Your session has ended. Sign in again.";
    case "bad_request":
      return "This client asked for that in a way the server refused. Nothing was changed.";
    default:
      return `The server refused with a status this client does not know about (${status.toString()}).`;
  }
}
