import { describe, expect, it } from "vitest";

import { createApiClient } from "./client";
import type { FetchLike, HttpResponse } from "./client";

type RecordedRequest = { url: string; init: RequestInit };

/**
 * A `fetch` that answers from a queue and records what it was asked.
 *
 * The client takes its `fetch` as configuration rather than reaching for the
 * global one, which is why no request interception library appears anywhere in
 * this project: the seam is an argument.
 */
function stubFetch(...responses: (HttpResponse | Error)[]): {
  fetch: FetchLike;
  requests: RecordedRequest[];
} {
  const requests: RecordedRequest[] = [];
  const queue = [...responses];

  const fetch: FetchLike = (url, init) => {
    requests.push({ url, init });
    const next = queue.shift();

    if (next === undefined) throw new Error(`no stubbed response for ${url}`);
    if (next instanceof Error) return Promise.reject(next);

    return Promise.resolve(next);
  };

  return { fetch, requests };
}

function respond(status: number, body?: unknown): HttpResponse {
  return {
    status,
    json: () =>
      body === undefined
        ? Promise.reject(new Error("Unexpected end of JSON input"))
        : Promise.resolve(body),
  };
}

function envelope(code: string, message: string, fields?: Record<string, string[]>) {
  return fields === undefined
    ? { error: { code, message } }
    : { error: { code, message, fields } };
}

const baseUrl = "http://api.test";

describe("requestMagicLink", () => {
  it("posts the address as JSON and reports the 202 as success", async () => {
    const { fetch, requests } = stubFetch(respond(202, { status: "sent" }));

    const result = await createApiClient({ baseUrl, fetch }).requestMagicLink(
      "worker@example.com",
    );

    expect(result).toEqual({ ok: true, value: null });
    expect(requests).toHaveLength(1);
    expect(requests[0]?.url).toBe("http://api.test/api/log-in");
    expect(requests[0]?.init.method).toBe("POST");
    expect(requests[0]?.init.body).toBe(JSON.stringify({ email: "worker@example.com" }));
  });

  it("carries no Authorization header, because there is no session yet", async () => {
    const { fetch, requests } = stubFetch(respond(202, { status: "sent" }));

    await createApiClient({ baseUrl, fetch }).requestMagicLink("worker@example.com");

    expect(requests[0]?.init.headers).not.toHaveProperty("Authorization");
  });

  it("keeps the per-field messages of a 422 attached to their fields", async () => {
    const { fetch } = stubFetch(
      respond(
        422,
        envelope("unprocessable_entity", "the address was not accepted", {
          email: ["must have the @ sign and no spaces"],
        }),
      ),
    );

    const result = await createApiClient({ baseUrl, fetch }).requestMagicLink("nonsense");

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "api_field_error",
        status: 422,
        code: "unprocessable_entity",
        rawCode: "unprocessable_entity",
        message: "the address was not accepted",
        fields: { email: ["must have the @ sign and no spaces"] },
      },
    });
  });

  it("distinguishes an envelope with no fields from one with empty fields", async () => {
    const { fetch } = stubFetch(
      respond(400, envelope("bad_request", "email is required")),
    );

    const result = await createApiClient({ baseUrl, fetch }).requestMagicLink("");

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "api_error",
        status: 400,
        code: "bad_request",
        rawCode: "bad_request",
        message: "email is required",
      },
    });
  });

  it("reports a mail provider outage as its own code rather than a generic failure", async () => {
    const { fetch } = stubFetch(
      respond(502, envelope("bad_gateway", "the log-in email could not be delivered")),
    );

    const result = await createApiClient({ baseUrl, fetch }).requestMagicLink(
      "worker@example.com",
    );

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.failure).toMatchObject({ kind: "api_error", code: "bad_gateway" });
  });

  it("returns a network failure rather than throwing when fetch rejects", async () => {
    const { fetch } = stubFetch(new TypeError("Failed to fetch"));

    const result = await createApiClient({ baseUrl, fetch }).requestMagicLink(
      "worker@example.com",
    );

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "network_error", message: "Failed to fetch" },
    });
  });

  it("accepts the 202 without reading its body, so a body change is not a client break", async () => {
    const { fetch } = stubFetch(respond(202));

    const result = await createApiClient({ baseUrl, fetch }).requestMagicLink(
      "worker@example.com",
    );

    expect(result).toEqual({ ok: true, value: null });
  });
});

describe("redeemMagicLink", () => {
  it("returns the API token and the person on 201", async () => {
    const { fetch, requests } = stubFetch(
      respond(201, {
        token: "c2Vzc2lvbi10b2tlbg",
        person: {
          id: "8b1b0a3c-0000-4000-8000-000000000001",
          email: "worker@example.com",
        },
      }),
    );

    const result = await createApiClient({ baseUrl, fetch }).redeemMagicLink("bWFnaWM");

    expect(result).toEqual({
      ok: true,
      value: {
        token: "c2Vzc2lvbi10b2tlbg",
        person: {
          id: "8b1b0a3c-0000-4000-8000-000000000001",
          email: "worker@example.com",
        },
      },
    });
    expect(requests[0]?.url).toBe("http://api.test/api/log-in/token");
    expect(requests[0]?.init.body).toBe(JSON.stringify({ token: "bWFnaWM" }));
  });

  it("reports an invalid, expired or spent link as unauthorized", async () => {
    const { fetch } = stubFetch(
      respond(401, envelope("unauthorized", "the link is invalid or it has expired")),
    );

    const result = await createApiClient({ baseUrl, fetch }).redeemMagicLink("stale");

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "api_error", status: 401, code: "unauthorized" },
    });
  });

  it("refuses a 201 whose body has no token rather than reporting an undefined session", async () => {
    const { fetch } = stubFetch(
      respond(201, {
        person: { id: "8b1b0a3c-0000-4000-8000-000000000001", email: null },
      }),
    );

    const result = await createApiClient({ baseUrl, fetch }).redeemMagicLink("bWFnaWM");

    expect(result).toMatchObject({ ok: false, failure: { kind: "malformed_response" } });
  });
});

describe("currentPerson", () => {
  it("sends the session token as a bearer credential", async () => {
    const { fetch, requests } = stubFetch(
      respond(200, {
        person: {
          id: "8b1b0a3c-0000-4000-8000-000000000001",
          email: "worker@example.com",
        },
      }),
    );

    const result = await createApiClient({ baseUrl, fetch }).currentPerson("c2Vzc2lvbg");

    expect(result).toEqual({
      ok: true,
      value: { id: "8b1b0a3c-0000-4000-8000-000000000001", email: "worker@example.com" },
    });
    expect(requests[0]?.url).toBe("http://api.test/api/me");
    expect(requests[0]?.init.method).toBe("GET");
    expect(requests[0]?.init.headers).toMatchObject({
      Authorization: "Bearer c2Vzc2lvbg",
    });
  });

  it("reads an erased person's null address as null rather than failing to decode", async () => {
    const { fetch } = stubFetch(
      respond(200, {
        person: { id: "8b1b0a3c-0000-4000-8000-000000000001", email: null },
      }),
    );

    const result = await createApiClient({ baseUrl, fetch }).currentPerson("c2Vzc2lvbg");

    expect(result).toEqual({
      ok: true,
      value: { id: "8b1b0a3c-0000-4000-8000-000000000001", email: null },
    });
  });

  it("reports a dead or revoked token as unauthorized", async () => {
    const { fetch } = stubFetch(
      respond(401, envelope("unauthorized", "the request carries no live session token")),
    );

    const result = await createApiClient({ baseUrl, fetch }).currentPerson("revoked");

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "api_error", code: "unauthorized" },
    });
  });
});

describe("logOut", () => {
  it("deletes the session and treats the empty 204 as success", async () => {
    const { fetch, requests } = stubFetch(respond(204));

    const result = await createApiClient({ baseUrl, fetch }).logOut("c2Vzc2lvbg");

    expect(result).toEqual({ ok: true, value: null });
    expect(requests[0]?.url).toBe("http://api.test/api/log-out");
    expect(requests[0]?.init.method).toBe("DELETE");
    expect(requests[0]?.init.headers).toMatchObject({
      Authorization: "Bearer c2Vzc2lvbg",
    });
  });

  it("reports a token that is already dead as unauthorized", async () => {
    const { fetch } = stubFetch(
      respond(401, envelope("unauthorized", "the request carries no live session token")),
    );

    const result = await createApiClient({ baseUrl, fetch }).logOut("revoked");

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "api_error", code: "unauthorized" },
    });
  });
});

describe("responses that are not the envelope", () => {
  it("reports a failure body in some other shape as malformed, keeping the status", async () => {
    const { fetch } = stubFetch(
      respond(500, { errors: { detail: "Internal Server Error" } }),
    );

    const result = await createApiClient({ baseUrl, fetch }).currentPerson("c2Vzc2lvbg");

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "malformed_response", status: 500 },
    });
  });

  it("reports an unparseable failure body as malformed rather than crashing", async () => {
    const { fetch } = stubFetch(respond(503));

    const result = await createApiClient({ baseUrl, fetch }).currentPerson("c2Vzc2lvbg");

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "malformed_response", status: 503 },
    });
  });

  it("keeps a status atom it does not know about instead of discarding it", async () => {
    const { fetch } = stubFetch(
      respond(418, envelope("im_a_teapot", "the server is a teapot")),
    );

    const result = await createApiClient({ baseUrl, fetch }).currentPerson("c2Vzc2lvbg");

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "api_error",
        status: 418,
        code: "unrecognised",
        rawCode: "im_a_teapot",
        message: "the server is a teapot",
      },
    });
  });
});

describe("base URL", () => {
  it("is same-origin when empty, which is what the dev proxy arranges", async () => {
    const { fetch, requests } = stubFetch(respond(202, { status: "sent" }));

    await createApiClient({ baseUrl: "", fetch }).requestMagicLink("worker@example.com");

    expect(requests[0]?.url).toBe("/api/log-in");
  });

  it("does not double the slash when it is given with a trailing one", async () => {
    const { fetch, requests } = stubFetch(respond(202, { status: "sent" }));

    await createApiClient({ baseUrl: "http://api.test/", fetch }).requestMagicLink(
      "worker@example.com",
    );

    expect(requests[0]?.url).toBe("http://api.test/api/log-in");
  });
});

describe("read", () => {
  it("sends the bearer token and answers the decoded value on 200", async () => {
    // The primitive every person-side read goes through. The path is the
    // caller's — a feature owns what its resource is called — so this asserts
    // it is used verbatim rather than assembled here.
    const { fetch, requests } = stubFetch(respond(200, { venue_rooms: [] }));

    const result = await createApiClient({ baseUrl, fetch }).read(
      "/api/venue-rooms?extent=all",
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toEqual({ ok: true, value: { venue_rooms: [] } });
    expect(requests[0]?.url).toBe(`${baseUrl}/api/venue-rooms?extent=all`);
    expect(requests[0]?.init.method).toBe("GET");
    expect(requests[0]?.init.headers).toMatchObject({
      Authorization: "Bearer c2Vzc2lvbg",
    });
  });

  it("turns a decoder's null into malformed_response rather than a value", async () => {
    // The property the whole decoder posture rests on: a field the server
    // renames is a *named* failure, not `undefined` arriving in a heading.
    const { fetch } = stubFetch(respond(200, { venue_rooms: "not a list" }));

    const result = await createApiClient({ baseUrl, fetch }).read(
      "/api/venue-rooms",
      "c2Vzc2lvbg",
      () => null,
    );

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "malformed_response",
        status: 200,
        message: "the 200 response was not the expected shape",
      },
    });
  });

  it("reads the error envelope out of a refusal", async () => {
    // `RoomController` answers 404 for a room that does not exist and one this
    // session may not reach, identically (AE1). The client keeps the code so a
    // rooms-specific sentence can be chosen for it.
    const { fetch } = stubFetch(
      respond(404, envelope("not_found", "no such room, or it is not one you can reach")),
    );

    const result = await createApiClient({ baseUrl, fetch }).read(
      "/api/venue-rooms/whatever/messages",
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "api_error",
        status: 404,
        code: "not_found",
        rawCode: "not_found",
        message: "no such room, or it is not one you can reach",
      },
    });
  });

  it("does not treat a 204 as a success, because no room route answers one", async () => {
    // Only 200 is the contract. A status nobody planned for is a drift, and a
    // drift that decoded as an empty list would render an empty room list to a
    // worker who is in three.
    const { fetch } = stubFetch(respond(204));

    const result = await createApiClient({ baseUrl, fetch }).read(
      "/api/venue-rooms",
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result.ok).toBe(false);
  });
});

describe("write", () => {
  const offer = { role_label: "Runner" };

  it("sends the method it was given, the body as JSON, and the bearer token", async () => {
    // The method is a parameter rather than baked in, because U5 ships a
    // `DELETE` through this same function and a `write` that could only POST
    // would become two functions the moment it did.
    const { fetch, requests } = stubFetch(respond(201, { invitation: {} }));

    await createApiClient({ baseUrl, fetch }).write(
      {
        method: "POST",
        path: "/api/employer/venues/v1/invitations",
        body: offer,
        status: 201,
      },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(requests).toHaveLength(1);
    expect(requests[0]?.url).toBe(`${baseUrl}/api/employer/venues/v1/invitations`);
    expect(requests[0]?.init.method).toBe("POST");
    expect(requests[0]?.init.body).toBe(JSON.stringify(offer));
    expect(requests[0]?.init.headers).toMatchObject({
      Authorization: "Bearer c2Vzc2lvbg",
      "Content-Type": "application/json",
    });
  });

  it("carries a method that is not POST, unchanged", async () => {
    // The control for the assertion above: a `write` that hard-coded "POST"
    // passes it, because "POST" is what that test asks for.
    const { fetch, requests } = stubFetch(respond(204));

    await createApiClient({ baseUrl, fetch }).write(
      { method: "DELETE", path: "/api/rosters/r1", status: 204 },
      "c2Vzc2lvbg",
    );

    expect(requests[0]?.init.method).toBe("DELETE");
    expect(requests[0]?.init.body).toBeUndefined();
  });

  it("answers the decoded value on the status it was told to expect", async () => {
    const { fetch } = stubFetch(respond(201, { claim_code: "aGFuZGVk" }));

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "POST", path: "/api/employer/venues/v1/invitations", status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toEqual({ ok: true, value: { claim_code: "aGFuZGVk" } });
  });

  it("treats a 200 as a failure when 201 is what the route promises", async () => {
    // Only the named status is a success, and a 2xx nobody planned for is a
    // drift like any other. `POST /api/employer/venues/:id/invitations` answers
    // `201`; a `200` from it means something in front of Phoenix answered.
    const { fetch } = stubFetch(respond(200, { invitation: {}, claim_code: "x" }));

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "POST", path: "/api/employer/venues/v1/invitations", status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "malformed_response", status: 200 },
    });
  });

  it("reads the error envelope out of a refusal, keeping code and message", async () => {
    // `ClaimController` distinguishes three code refusals by status **and**
    // sentence, deliberately (R6), so both have to survive the trip.
    const { fetch } = stubFetch(
      respond(409, envelope("conflict", "that claim code has already been redeemed")),
    );

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "POST", path: "/api/claims", body: { claim_code: "x" }, status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "api_error",
        status: 409,
        code: "unrecognised",
        rawCode: "conflict",
        message: "that claim code has already been redeemed",
      },
    });
  });

  it("keeps a 422's per-field messages attached to the fields they name", async () => {
    const { fetch } = stubFetch(
      respond(
        422,
        envelope("unprocessable_entity", "the offer was not accepted", {
          role_label: ["can't be blank"],
        }),
      ),
    );

    const result = await createApiClient({ baseUrl, fetch }).write(
      {
        method: "POST",
        path: "/api/employer/venues/v1/invitations",
        body: { role_label: "" },
        status: 201,
      },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toMatchObject({
      ok: false,
      failure: {
        kind: "api_field_error",
        status: 422,
        fields: { role_label: ["can't be blank"] },
      },
    });
  });

  it("turns a decoder's null into malformed_response rather than a value", async () => {
    const { fetch } = stubFetch(respond(201, { invitation: "not an object" }));

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "POST", path: "/api/employer/venues/v1/invitations", status: 201 },
      "c2Vzc2lvbg",
      () => null,
    );

    expect(result).toEqual({
      ok: false,
      failure: {
        kind: "malformed_response",
        status: 201,
        message: "the 201 response was not the expected shape",
      },
    });
  });

  it("returns a network failure rather than throwing when fetch rejects", async () => {
    const { fetch } = stubFetch(new TypeError("Failed to fetch"));

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "POST", path: "/api/claims", body: { claim_code: "x" }, status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "network_error", message: "Failed to fetch" },
    });
  });

  // **The control the whole shape exists for.** A 204 carries no body at all,
  // so a `write` built like `read` — read the body, decode it, fail on null —
  // reports U5's roster removal as `malformed_response` and the surface says
  // the removal failed after it succeeded. Omitting the decoder is what makes
  // the body go unread; this is the assertion that fails if it stops being.
  it("treats a bodiless 204 as a success, not as a malformed response", async () => {
    const { fetch } = stubFetch(respond(204));

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "DELETE", path: "/api/rosters/r1", status: 204 },
      "c2Vzc2lvbg",
    );

    expect(result).toEqual({ ok: true, value: null });
  });

  it("still refuses a 204 that was not the status the caller named", async () => {
    // The other half of the control: "no body was read" must not become "any
    // status is fine". A `204` where a `201` was promised is a drift.
    const { fetch } = stubFetch(respond(204));

    const result = await createApiClient({ baseUrl, fetch }).write(
      { method: "POST", path: "/api/claims", body: { claim_code: "x" }, status: 201 },
      "c2Vzc2lvbg",
    );

    expect(result.ok).toBe(false);
  });
});
