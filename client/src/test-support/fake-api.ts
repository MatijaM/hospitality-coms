import { vi } from "vitest";

import type { ApiClient, ApiResult, WriteRequest } from "../api/client";
import type { RequestFailure } from "../api/errors";
import type { Person, Session } from "../api/types";

/**
 * A stand-in for the API client, for the surfaces above it.
 *
 * The client itself is tested against a stub `fetch`; everything above it is
 * tested against this, so a route test says which answer the API gave rather
 * than which JSON it sent.
 */
export function createFakeApi(overrides: Partial<ApiClient> = {}): ApiClient {
  return {
    requestMagicLink: vi.fn(() => Promise.resolve(ok(null))),
    redeemMagicLink: vi.fn(() => Promise.resolve(fails<Session>(unauthorized()))),
    currentPerson: vi.fn(() => Promise.resolve(fails<Person>(unauthorized()))),
    logOut: vi.fn(() => Promise.resolve(ok(null))),
    // Fails by default, like the other two reads above: a surface that renders
    // whatever `read` gave it must be tested against the failure path having
    // been reachable. A test that wants answers passes `readsFrom`.
    read: vi.fn(() => Promise.resolve(fails<never>(offline()))),
    // **Fails by default too, and `fake-api.test.ts` asserts it directly.** A
    // write is where this client can do irreversible damage on somebody's
    // behalf, so a surface that never met a refused write in a test is a
    // surface whose refusal path may not exist. A test that wants answers
    // passes `writesTo`.
    write: vi.fn(() => Promise.resolve(fails<never>(offline()))),
    ...overrides,
  };
}

/**
 * What a faked `write` answers for one `"<METHOD> <path>"` key.
 *
 * Two members rather than one nullable body, because a refusal is the case
 * these surfaces most need to be driven through and a fixture that could only
 * express success would quietly make that untestable.
 */
export type WriteReply =
  /** A `201`-shaped success. `null` for a `204`, where nothing is decoded. */
  { readonly body: unknown } | { readonly failure: RequestFailure };

/**
 * A `write` that answers the requests a test names and 404s everything else.
 *
 * The keys are `"POST /api/claims"` — the method **and** the path, because two
 * verbs on one path are two different operations and U5 adds a `DELETE` beside
 * a `POST`. `readsFrom` needs no such prefix: every read is a `GET`.
 *
 * Bodies go through the real decoders, so a fixture that is not the shape the
 * server sends fails as `malformed_response` here exactly as it would in a
 * browser. A request with no decoder answers `null` without looking at the
 * body, which is what the client does.
 */
export function writesTo(
  replies: Readonly<Record<string, WriteReply>>,
): ApiClient["write"] {
  return vi.fn(
    (request: WriteRequest, _token: string, decode?: (body: unknown) => unknown) => {
      const reply = replies[`${request.method} ${request.path}`];

      if (reply === undefined) {
        return Promise.resolve(
          fails<never>({
            kind: "api_error",
            status: 404,
            code: "not_found",
            rawCode: "not_found",
            message: "no such venue, or it is not one you can act for",
          }),
        );
      }

      if ("failure" in reply) return Promise.resolve(fails<never>(reply.failure));
      if (decode === undefined) return Promise.resolve(ok(null));

      const value = decode(reply.body);

      if (value === null) {
        return Promise.resolve(
          fails<never>({
            kind: "malformed_response",
            status: request.status,
            message: `the ${request.status} response was not the expected shape`,
          }),
        );
      }

      return Promise.resolve({ ok: true as const, value });
    },
  ) as ApiClient["write"];
}

/**
 * A `read` that answers the paths a test names and 404s everything else.
 *
 * The keys are **paths without the query string**, because the query string is
 * `extent` and a test that wanted to answer the two extents differently is
 * asking about the bound rather than about the route — `bodiesFor` takes the
 * whole path when it needs to. The bodies go through the real decoders, so a
 * fixture that is not the shape the server sends fails as
 * `malformed_response` here exactly as it would in a browser.
 */
export function readsFrom(bodies: Readonly<Record<string, unknown>>): ApiClient["read"] {
  return vi.fn((path: string, _token: string, decode: (body: unknown) => unknown) => {
    const body = path in bodies ? bodies[path] : bodies[path.split("?")[0] ?? path];

    if (body === undefined) {
      return Promise.resolve(
        fails<never>({
          kind: "api_error",
          status: 404,
          code: "not_found",
          rawCode: "not_found",
          message: "no such room, or it is not one you can reach",
        }),
      );
    }

    const value = decode(body);

    if (value === null) {
      return Promise.resolve(
        fails<never>({
          kind: "malformed_response",
          status: 200,
          message: "the 200 response was not the expected shape",
        }),
      );
    }

    return Promise.resolve({ ok: true as const, value });
  }) as ApiClient["read"];
}

export function ok<T>(value: T): ApiResult<T> {
  return { ok: true, value };
}

export function fails<T>(failure: RequestFailure): ApiResult<T> {
  return { ok: false, failure };
}

export function unauthorized(): RequestFailure {
  return {
    kind: "api_error",
    status: 401,
    code: "unauthorized",
    rawCode: "unauthorized",
    message: "the request carries no live session token",
  };
}

export function offline(): RequestFailure {
  return {
    kind: "network_error",
    message: "Failed to fetch",
    cause: new TypeError("Failed to fetch"),
  };
}

export function invalidAddress(): RequestFailure {
  return {
    kind: "api_field_error",
    status: 422,
    code: "unprocessable_entity",
    rawCode: "unprocessable_entity",
    message: "the address was not accepted",
    fields: { email: ["must have the @ sign and no spaces"] },
  };
}

export const somePerson: Person = {
  id: "8b1b0a3c-0000-4000-8000-000000000001",
  email: "worker@example.com",
};
