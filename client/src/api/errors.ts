/**
 * Every way a request to this API can fail, enumerated.
 *
 * `AGENTS.md` bans `{:error, term()}` on the Elixir side and asks for the
 * actual atoms traced through the function bodies. The analogue here is a
 * discriminated union with no `Error` and no `any` in it: a caller switches on
 * `kind` and the compiler names the case it forgot.
 *
 * The API's own failures arrive in one envelope, built only by
 * `HospitalityComsWeb.ErrorEnvelope`:
 *
 *     {"error": {"code": "unauthorized", "message": "..."}}
 *     {"error": {"code": "unprocessable_entity", "message": "...",
 *                "fields": {"email": ["..."]}}}
 *
 * `fields` is present only when the failure is per-field, and the envelope's
 * own documentation says its absence is information: there is nothing to
 * attach to an input. So it is two members of this union rather than one
 * member with an optional property, and a form that wants to mark up its
 * inputs asks whether it has an `api_field_error` rather than whether some
 * property happened to be defined.
 */

/**
 * The status atoms these four endpoints are known to produce, traced through
 * `SessionController`, `PersonAuth.require_authenticated_person/2` and
 * `ErrorJSON`.
 *
 * `ErrorEnvelope.for_status/1` can render any status Phoenix knows, so this
 * list is what the client discriminates on rather than what the server can
 * emit. Anything outside it decodes as `unrecognised` with the wire value kept
 * in `rawCode`, because a code nobody planned for is still worth logging.
 */
export const KNOWN_ERROR_CODES = [
  /** No `email`, or no `token`, in the request body. */
  "bad_request",
  /** No live session token, or a magic link that is invalid, expired or spent. */
  "unauthorized",
  /** A route that does not exist. Rendered by `ErrorJSON`, not by a controller. */
  "not_found",
  /** The address was rejected; `fields` names the inputs. */
  "unprocessable_entity",
  /** The log-in request could not be recorded, or nothing caught an exception. */
  "internal_server_error",
  /** The mail provider could not be reached. Says nothing about the address. */
  "bad_gateway",
] as const;

export type KnownErrorCode = (typeof KNOWN_ERROR_CODES)[number];
export type ErrorCode = KnownErrorCode | "unrecognised";

/** Per-field validation messages, keyed by the input they belong to. */
export type FieldErrors = Readonly<Record<string, readonly string[]>>;

/** The API refused, and named no input. */
export type ApiError = {
  readonly kind: "api_error";
  readonly status: number;
  readonly code: ErrorCode;
  readonly rawCode: string;
  readonly message: string;
};

/** The API refused, and named the inputs it rejected. */
export type ApiFieldError = {
  readonly kind: "api_field_error";
  readonly status: number;
  readonly code: ErrorCode;
  readonly rawCode: string;
  readonly message: string;
  readonly fields: FieldErrors;
};

/**
 * The request never produced a response: offline, DNS, a refused connection, or
 * a cross-origin request the browser blocked before it left.
 */
export type NetworkError = {
  readonly kind: "network_error";
  readonly message: string;
  readonly cause: unknown;
};

/**
 * A response arrived and was not the shape this client was promised — a success
 * body missing a field, or a failure body that is not the envelope.
 *
 * This case exists so that a contract drift surfaces as a named failure rather
 * than as `undefined` travelling into a component and rendering as nothing.
 */
export type MalformedResponse = {
  readonly kind: "malformed_response";
  readonly status: number;
  readonly message: string;
};

export type RequestFailure = ApiError | ApiFieldError | NetworkError | MalformedResponse;

export function isKnownErrorCode(code: string): code is KnownErrorCode {
  return (KNOWN_ERROR_CODES as readonly string[]).includes(code);
}

/**
 * Whether this failure means the session is gone.
 *
 * Worth a named predicate rather than a comparison at each call site: it is the
 * one failure that must clear the stored token, and treating any other failure
 * that way logs a worker out because their train went into a tunnel.
 */
export function isSessionExpired(failure: RequestFailure): boolean {
  return (
    (failure.kind === "api_error" || failure.kind === "api_field_error") &&
    failure.code === "unauthorized"
  );
}
