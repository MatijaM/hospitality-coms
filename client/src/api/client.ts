/**
 * The typed client for the session endpoints, plus **one generic primitive**
 * that every person-side read goes through.
 *
 *     POST   /api/log-in         {email}  -> 202
 *     POST   /api/log-in/token   {token}  -> 201 {token, person}
 *     GET    /api/me                      -> 200 {person}
 *     DELETE /api/log-out                 -> 204
 *
 * Two properties are deliberate.
 *
 * Nothing here throws. Every call answers `{ok: true, value}` or
 * `{ok: false, failure}` with `failure` drawn from an enumerated union, which
 * is the same posture `AGENTS.md` requires of the Elixir side and means a
 * caller cannot forget the failure path by not writing a `catch`.
 *
 * `fetch` is an argument. That is the whole of the test seam — no request
 * interception, no service worker, no HTTP recording — and it is why the tests
 * for this file are fast and say what they mean.
 *
 * ## Why `read` is generic and the room routes are not methods here
 *
 * U12's room routes are the first person-side reads this API has, and the
 * profile surface is waiting on the same fork
 * (`features/profile/contract.ts`). Four `venueRooms()`/`shiftRooms()`/…
 * methods here would be easier to fake and would make this file a grab-bag of
 * every feature's endpoints by the time the profile lands its seven.
 *
 * So the layering is: **a feature owns its paths and its wire shapes; this file
 * owns "an authenticated GET that decodes or fails".** `features/rooms/rooms-api.ts`
 * is the first tenant, and a profile one adds nothing here at all.
 *
 * The session calls above stay as named methods. They are not reads of a
 * feature's resource — they are how a session begins and ends, they are the
 * only calls that are not GETs, and two of them run before there is a token to
 * pass.
 */

import { decodeErrorEnvelope, decodePersonEnvelope, decodeSession } from "./decode";
import type { MalformedResponse, NetworkError, RequestFailure } from "./errors";
import type { Person, Session } from "./types";

/**
 * The part of `Response` this client uses.
 *
 * Narrower than the DOM type on purpose: `globalThis.fetch` satisfies it, and
 * so does a two-property object literal in a test, without either side
 * pretending to implement a streaming body.
 */
export type HttpResponse = {
  readonly status: number;
  json(): Promise<unknown>;
};

export type FetchLike = (url: string, init: RequestInit) => Promise<HttpResponse>;

export type ApiResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly failure: RequestFailure };

export type ApiClientConfig = {
  /**
   * Prefixed to every path. Empty means same-origin, which is what the Vite dev
   * proxy arranges and what a deployment serving both from one origin wants.
   */
  readonly baseUrl: string;
  readonly fetch?: FetchLike;
};

export type ApiClient = {
  /**
   * Asks for a magic link, registering the address if it is new.
   *
   * The server answers 202 whether or not it knew the address — one door, and
   * the same answer to an enumeration attempt either way — so a caller cannot
   * learn from this whether an account existed, and must not phrase its
   * confirmation as though it had.
   */
  requestMagicLink(email: string): Promise<ApiResult<null>>;

  /**
   * Redeems a magic link for the session token.
   *
   * Invalid, expired and already-used links are one answer — 401 — on purpose.
   */
  redeemMagicLink(token: string): Promise<ApiResult<Session>>;

  /** Reads back the person a session token belongs to. */
  currentPerson(sessionToken: string): Promise<ApiResult<Person>>;

  /**
   * Ends the session.
   *
   * A delete, not an expiry: the row goes and the next request carrying that
   * token is anonymous.
   */
  logOut(sessionToken: string): Promise<ApiResult<null>>;

  /**
   * An authenticated `GET`, decoded by the caller.
   *
   * `path` is absolute from the API root and carries its own query string; the
   * caller builds it, because the caller is the one that knows what its
   * resource is called. Only `200` is a success — every route this serves
   * answers `200` or the error envelope, so a `204` or a redirect is a contract
   * drift and surfaces as a failure rather than as an empty value.
   *
   * `decode` returns `null` for "this is not that", exactly as every decoder in
   * `api/decode.ts` does, and `null` becomes `malformed_response`. That is what
   * keeps a field the server renames a *named* failure instead of `undefined`
   * arriving in a heading.
   */
  read<T>(
    path: string,
    sessionToken: string,
    decode: (body: unknown) => T | null,
  ): Promise<ApiResult<T>>;
};

const JSON_HEADERS: Readonly<Record<string, string>> = {
  "Content-Type": "application/json",
  Accept: "application/json",
};

function networkError(cause: unknown): NetworkError {
  const message =
    cause instanceof Error ? cause.message : "the request could not be sent";

  return { kind: "network_error", message, cause };
}

function malformed(status: number, message: string): MalformedResponse {
  return { kind: "malformed_response", status, message };
}

async function readJson(
  response: HttpResponse,
): Promise<{ parsed: boolean; body: unknown }> {
  try {
    return { parsed: true, body: await response.json() };
  } catch {
    return { parsed: false, body: null };
  }
}

/**
 * Turns any response that is not the expected status into a failure.
 *
 * A body that is not the envelope is `malformed_response` rather than a
 * best-effort guess, because the envelope is a contract: `ErrorJSON` renders it
 * even for a 404 the router produced and a 500 nobody caught, so a failure body
 * in some other shape means something in front of Phoenix answered — a proxy,
 * a load balancer — and pretending otherwise would attribute it to the API.
 */
async function failureFrom(response: HttpResponse): Promise<RequestFailure> {
  const { parsed, body } = await readJson(response);

  if (!parsed) {
    return malformed(response.status, `the ${response.status} response was not JSON`);
  }

  return (
    decodeErrorEnvelope(response.status, body) ??
    malformed(
      response.status,
      `the ${response.status} response was not the error envelope`,
    )
  );
}

function bearer(sessionToken: string): Record<string, string> {
  return { Authorization: `Bearer ${sessionToken}` };
}

export function createApiClient(config: ApiClientConfig): ApiClient {
  const base = config.baseUrl.replace(/\/+$/, "");
  const send: FetchLike = config.fetch ?? ((url, init) => globalThis.fetch(url, init));

  async function perform(
    path: string,
    init: RequestInit,
  ): Promise<
    { ok: true; response: HttpResponse } | { ok: false; failure: NetworkError }
  > {
    try {
      return { ok: true, response: await send(`${base}${path}`, init) };
    } catch (cause) {
      return { ok: false, failure: networkError(cause) };
    }
  }

  /** For 202 and 204, where the body is either absent or nothing we depend on. */
  async function expectStatus(
    path: string,
    init: RequestInit,
    status: number,
  ): Promise<ApiResult<null>> {
    const attempt = await perform(path, init);
    if (!attempt.ok) return { ok: false, failure: attempt.failure };

    if (attempt.response.status !== status) {
      return { ok: false, failure: await failureFrom(attempt.response) };
    }

    return { ok: true, value: null };
  }

  async function expectBody<T>(
    path: string,
    init: RequestInit,
    status: number,
    decode: (body: unknown) => T | null,
  ): Promise<ApiResult<T>> {
    const attempt = await perform(path, init);
    if (!attempt.ok) return { ok: false, failure: attempt.failure };

    const response = attempt.response;
    if (response.status !== status) {
      return { ok: false, failure: await failureFrom(response) };
    }

    const { parsed, body } = await readJson(response);
    if (!parsed) {
      return {
        ok: false,
        failure: malformed(status, `the ${status} response was not JSON`),
      };
    }

    const value = decode(body);
    if (value === null) {
      return {
        ok: false,
        failure: malformed(status, `the ${status} response was not the expected shape`),
      };
    }

    return { ok: true, value };
  }

  return {
    requestMagicLink(email) {
      return expectStatus(
        "/api/log-in",
        { method: "POST", headers: JSON_HEADERS, body: JSON.stringify({ email }) },
        202,
      );
    },

    redeemMagicLink(token) {
      return expectBody(
        "/api/log-in/token",
        { method: "POST", headers: JSON_HEADERS, body: JSON.stringify({ token }) },
        201,
        decodeSession,
      );
    },

    currentPerson(sessionToken) {
      return expectBody(
        "/api/me",
        { method: "GET", headers: { ...JSON_HEADERS, ...bearer(sessionToken) } },
        200,
        decodePersonEnvelope,
      );
    },

    logOut(sessionToken) {
      return expectStatus(
        "/api/log-out",
        { method: "DELETE", headers: { ...JSON_HEADERS, ...bearer(sessionToken) } },
        204,
      );
    },

    read(path, sessionToken, decode) {
      return expectBody(
        path,
        { method: "GET", headers: { ...JSON_HEADERS, ...bearer(sessionToken) } },
        200,
        decode,
      );
    },
  };
}
