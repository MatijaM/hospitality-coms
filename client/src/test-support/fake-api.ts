import { vi } from "vitest";

import type { ApiClient, ApiResult } from "../api/client";
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
    ...overrides,
  };
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
