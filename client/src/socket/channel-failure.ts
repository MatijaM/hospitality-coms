/**
 * The error envelope over a channel — the transport's half of
 * `src/api/errors.ts`.
 *
 * `ErrorEnvelope` builds every refusal a channel replies with, exactly as it
 * builds every HTTP error body, so the payload of a refused join and the
 * payload of a refused `"send"` are the same two shapes:
 *
 *     {"error": {"code": "gone", "message": "…"}}
 *     {"error": {"code": "unprocessable_entity", "message": "…",
 *                "fields": {"body": ["…"]}}}
 *
 * ## Why this is not `RequestFailure`
 *
 * `ApiError` carries a `status`, because an HTTP failure has one and reporting
 * a code nobody planned for needs the number. A channel reply has no status
 * line at all — `Phoenix.Channel`'s `{:reply, {:error, …}}` is a frame — so a
 * `status` here would be a number this client invented.
 *
 * ## The envelope is shared; the vocabulary is the caller's
 *
 * **This module names no codes.** It used to, and that was a coupling with a
 * date on it: a surface's copy is an exhaustive `switch` over the codes it can
 * meet, so a single shared list makes *every* switch break when *any* surface
 * gains a code. U8 puts nine events on one multiplexed `"peer"` channel, and a
 * peer-only code on a shared list would have demanded a case inside
 * `features/rooms/`, which knows nothing about peers and can say nothing
 * useful about one.
 *
 * `src/api/errors.ts` gets away with one shared list because exactly one switch
 * consumes it. Here there will be at least three.
 *
 * So `decodeChannelRefusal` takes the caller's own vocabulary and narrows to
 * it: `features/rooms/refusal-message.ts` owns `ROOM_ERROR_CODES` and traces
 * each one to the clause that emits it, and U8 can add `PEER_ERROR_CODES`
 * without editing a room-owned file. Anything outside the caller's set is
 * `unrecognised`, with the wire value kept in `rawCode` — which is also the
 * right answer for a peer code arriving on a room topic: it is a code that
 * surface cannot meet, and inventing copy for it would be worse than saying so.
 */

import { isRecord, isStringArray } from "../api/decode";
import type { FieldErrors } from "../api/errors";

/** The channel refused, and named no input. */
export type ChannelError<Code extends string> = {
  readonly kind: "channel_error";
  readonly code: Code | "unrecognised";
  readonly rawCode: string;
  readonly message: string;
};

/** The channel refused, and named the inputs it rejected. */
export type ChannelFieldError<Code extends string> = {
  readonly kind: "channel_field_error";
  readonly code: Code | "unrecognised";
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

export type ChannelFailure<Code extends string> =
  ChannelError<Code> | ChannelFieldError<Code> | ChannelTimeout | MalformedRefusal;

/**
 * Turns a refusal payload into a failure drawn from the caller's vocabulary.
 *
 * Never returns `null` and never throws: every caller has a surface to put a
 * sentence on, and there is no case where saying nothing is right.
 */
export function decodeChannelRefusal<Code extends string>(
  payload: unknown,
  known: readonly Code[],
): ChannelFailure<Code> {
  if (!isRecord(payload)) return notTheEnvelope();

  const error = payload.error;
  if (!isRecord(error)) return notTheEnvelope();
  if (typeof error.code !== "string") return notTheEnvelope();
  if (typeof error.message !== "string") return notTheEnvelope();

  const rawCode = error.code;
  const code = known.find((candidate) => candidate === rawCode) ?? "unrecognised";
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
