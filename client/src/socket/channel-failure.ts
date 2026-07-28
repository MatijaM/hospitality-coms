/**
 * Every way a channel can refuse, enumerated — the transport's half of
 * `src/api/errors.ts`.
 *
 * The envelope is the same contract on both transports. `ErrorEnvelope` builds
 * every refusal a channel replies with, exactly as it builds every HTTP error
 * body, so the payload of a refused join and the payload of a refused `"send"`
 * are the same two shapes:
 *
 *     {"error": {"code": "gone", "message": "…"}}
 *     {"error": {"code": "unprocessable_entity", "message": "…",
 *                "fields": {"body": ["…"]}}}
 *
 * ## Why this is not `RequestFailure`
 *
 * Two reasons, and the second is the one that matters.
 *
 * `ApiError` carries a `status`, because an HTTP failure has one and reporting
 * a code nobody planned for needs the number. A channel reply has no status
 * line at all — `Phoenix.Channel`'s `{:reply, {:error, …}}` is a frame, not a
 * response — so a `status` here would be a number this client invented.
 *
 * And the **vocabulary is different**. `KNOWN_ERROR_CODES` is what
 * `SessionController`, `PersonAuth` and `ErrorJSON` produce. The room channels
 * produce `forbidden` and `gone`, which no endpoint does, and produce neither
 * `not_found` nor `bad_gateway`, which endpoints do. Folding the two together
 * would mean one exhaustive switch writing log-in copy for a room refusal and
 * room copy for a log-in refusal; keeping them apart is what lets each surface
 * say something true.
 */

import type { FieldErrors } from "../api/errors";
import { isRecord, isStringArray } from "../api/decode";

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
 * Anything else is `unrecognised`, with the wire value kept in `rawCode`.
 */
export const KNOWN_CHANNEL_ERROR_CODES = [
  "unauthorized",
  "bad_request",
  "forbidden",
  "gone",
  "unprocessable_entity",
] as const;

export type KnownChannelErrorCode = (typeof KNOWN_CHANNEL_ERROR_CODES)[number];
export type ChannelErrorCode = KnownChannelErrorCode | "unrecognised";

/** The channel refused, and named no input. */
export type ChannelError = {
  readonly kind: "channel_error";
  readonly code: ChannelErrorCode;
  readonly rawCode: string;
  readonly message: string;
};

/** The channel refused, and named the inputs it rejected. */
export type ChannelFieldError = {
  readonly kind: "channel_field_error";
  readonly code: ChannelErrorCode;
  readonly rawCode: string;
  readonly message: string;
  readonly fields: FieldErrors;
};

/**
 * The push was sent and nothing came back inside `phoenix`'s timeout.
 *
 * Not a refusal: nobody decided anything, and the message may well have been
 * written. The copy for it has to say that rather than "rejected".
 */
export type ChannelTimeout = { readonly kind: "channel_timeout" };

/**
 * A refusal arrived in a shape this client was not promised.
 *
 * The same job `malformed_response` does for HTTP: drift surfaces as a named
 * failure rather than as `undefined` where a sentence should be. It also covers
 * the frames `phoenix` itself refuses with — `%{reason: "unmatched topic"}` for
 * a topic no socket routes, and `%{reason: "too many channels joined"}` at
 * `max_channels_per_transport` — neither of which is an `ErrorEnvelope`.
 */
export type MalformedRefusal = {
  readonly kind: "malformed_refusal";
  readonly message: string;
};

export type ChannelFailure =
  ChannelError | ChannelFieldError | ChannelTimeout | MalformedRefusal;

export function isKnownChannelErrorCode(code: string): code is KnownChannelErrorCode {
  return (KNOWN_CHANNEL_ERROR_CODES as readonly string[]).includes(code);
}

/**
 * Turns a refusal payload into a failure, or into `malformed_refusal`.
 *
 * Never returns `null` and never throws: every caller has a surface to put a
 * sentence on, and there is no case where saying nothing is right.
 */
export function decodeChannelRefusal(payload: unknown): ChannelFailure {
  if (!isRecord(payload)) return notTheEnvelope();

  const error = payload.error;
  if (!isRecord(error)) return notTheEnvelope();
  if (typeof error.code !== "string") return notTheEnvelope();
  if (typeof error.message !== "string") return notTheEnvelope();

  const rawCode = error.code;
  const code = isKnownChannelErrorCode(rawCode) ? rawCode : "unrecognised";
  const common = { code, rawCode, message: error.message } as const;

  // `fields` absent and `fields` present are two answers, for the reason
  // `src/api/errors.ts` gives: the envelope's own documentation says the
  // absence is information.
  if (!("fields" in error)) return { kind: "channel_error", ...common };

  const fields = decodeFields(error.fields);
  if (fields === null) return notTheEnvelope();

  return { kind: "channel_field_error", ...common, fields };
}

function notTheEnvelope(): MalformedRefusal {
  return {
    kind: "malformed_refusal",
    message: "the refusal was not the error envelope",
  };
}

function decodeFields(value: unknown): FieldErrors | null {
  if (!isRecord(value)) return null;

  const fields: Record<string, readonly string[]> = {};

  for (const [key, messages] of Object.entries(value)) {
    if (!isStringArray(messages)) return null;
    fields[key] = messages;
  }

  return fields;
}
