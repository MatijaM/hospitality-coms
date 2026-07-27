/**
 * Turning `unknown` from the network into the types the rest of the client
 * uses, or into nothing at all.
 *
 * Written by hand rather than with a schema library. The surface is three
 * shapes, the runtime dependency would be larger than the code it replaced, and
 * the endpoints these decode are the only ones that exist. When U8–U11 land
 * their surfaces this is the file to reconsider, not the one to extend
 * indefinitely.
 *
 * Every decoder returns `null` for "this is not that", never a partial value
 * and never a throw. The caller turns `null` into a `malformed_response`, which
 * is why a field the server renames surfaces as a named failure rather than as
 * `undefined` in a heading.
 */

import type { ApiError, ApiFieldError, FieldErrors } from "./errors";
import { isKnownErrorCode } from "./errors";
import type { Person, Session } from "./types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((entry) => typeof entry === "string");
}

/** `{"id": ..., "email": ... | null}` — `render_person/1`'s output. */
export function decodePerson(value: unknown): Person | null {
  if (!isRecord(value)) return null;
  if (typeof value.id !== "string") return null;
  if (!(typeof value.email === "string" || value.email === null)) return null;

  return { id: value.id, email: value.email };
}

/** `{"person": {...}}` — the body of `GET /api/me`. */
export function decodePersonEnvelope(value: unknown): Person | null {
  if (!isRecord(value)) return null;

  return decodePerson(value.person);
}

/** `{"token": ..., "person": {...}}` — the body of `POST /api/log-in/token`. */
export function decodeSession(value: unknown): Session | null {
  if (!isRecord(value)) return null;
  if (typeof value.token !== "string") return null;

  const person = decodePerson(value.person);
  if (person === null) return null;

  return { token: value.token, person };
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

/**
 * The error envelope, and only the error envelope.
 *
 * The status is passed in rather than read from the body: the envelope's `code`
 * is always the response's own status atom, so the two cannot drift, and
 * carrying the number as well means a caller can report a failure it has no
 * name for.
 */
export function decodeErrorEnvelope(
  status: number,
  value: unknown,
): ApiError | ApiFieldError | null {
  if (!isRecord(value)) return null;

  const error = value.error;
  if (!isRecord(error)) return null;
  if (typeof error.code !== "string") return null;
  if (typeof error.message !== "string") return null;

  const rawCode = error.code;
  const code = isKnownErrorCode(rawCode) ? rawCode : "unrecognised";
  const common = { status, code, rawCode, message: error.message } as const;

  // `fields` absent and `fields` present are two different answers, so they are
  // two different members of the union rather than one member with a hole in
  // it. A `fields` key that is present and malformed is neither, and the whole
  // envelope fails to decode rather than quietly losing the field messages.
  if (!("fields" in error)) return { kind: "api_error", ...common };

  const fields = decodeFields(error.fields);
  if (fields === null) return null;

  return { kind: "api_field_error", ...common, fields };
}
