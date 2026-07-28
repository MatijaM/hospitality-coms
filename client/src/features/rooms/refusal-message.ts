/**
 * What to show a worker when a room refuses something.
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
 * Both switches are exhaustive, so a new member of either union fails the
 * build rather than falling through to silence.
 */

import type { ChannelErrorCode, ChannelFailure } from "../../socket/channel-failure";
import type { SendBar } from "./room";

export function refusalMessage(failure: ChannelFailure): string {
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

function codeMessage(code: ChannelErrorCode, rawCode: string): string {
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
 * Two of the five codes say something durable about the room rather than about
 * this attempt — the room is closed, or this session is off the roster — and
 * both leave a room that is still perfectly readable. The other three are about
 * the message or the session and change nothing about the room, so they leave
 * the composer alone.
 */
export function barFromRefusal(failure: ChannelFailure): SendBar | null {
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

/** How a room whose composer is barred describes itself. */
export function barMessage(bar: SendBar): string {
  switch (bar) {
    case "room_closed":
      return "This room is closed. It is read-only from here.";
    case "not_rostered":
      return "You are not on this shift's roster. This room is read-only for you.";
  }
}
