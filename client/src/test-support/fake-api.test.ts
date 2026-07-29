/**
 * The fakes' own defaults, asserted rather than assumed.
 *
 * Every surface test in this client is written against `createFakeApi`, so what
 * that function answers when a test says nothing is the environment those tests
 * run in. Two of its defaults are load-bearing and neither is visible from the
 * test that depends on it:
 *
 *   * `read` fails, so a list surface rendered with no `readsFrom` is a surface
 *     whose failure path was reachable;
 *   * `write` fails, for the same reason and a sharper one — a write is where
 *     this client acts irreversibly on somebody's behalf, and a surface that
 *     never met a refused write in any test is a surface whose refusal path may
 *     not exist at all.
 *
 * A default flipped to "succeeds with an empty answer" would leave every one of
 * those tests green while quietly removing the property, which is exactly the
 * shape `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues.
 * So it is asserted here, directly, where the flip fails something.
 */

import { describe, expect, it } from "vitest";

import { createFakeApi, writesTo } from "./fake-api";

describe("createFakeApi's defaults", () => {
  it("fails a write nobody stubbed", async () => {
    const result = await createFakeApi().write(
      { method: "POST", path: "/api/claims", body: { claim_code: "x" }, status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toMatchObject({ ok: false, failure: { kind: "network_error" } });
  });

  it("fails a read nobody stubbed, which is the default this one copies", async () => {
    const result = await createFakeApi().read("/api/venue-rooms", "c2Vzc2lvbg", (b) => b);

    expect(result).toMatchObject({ ok: false, failure: { kind: "network_error" } });
  });

  it("takes an override, so a test that wants an answer gets one", async () => {
    // The control: "fails by default" has to be a default rather than the only
    // behaviour, or the two assertions above would hold for a fake that could
    // never succeed and no surface could be tested at all.
    const api = createFakeApi({
      write: writesTo({ "POST /api/claims": { body: { engagement: {} } } }),
    });

    const result = await api.write(
      { method: "POST", path: "/api/claims", body: { claim_code: "x" }, status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toEqual({ ok: true, value: { engagement: {} } });
  });
});

describe("writesTo", () => {
  it("keys on the method as well as the path", async () => {
    // Two verbs on one path are two operations, and U5 puts a `DELETE` beside
    // a `POST`. A fake keyed on the path alone would answer both from one entry.
    const write = writesTo({ "DELETE /api/rosters/r1": { body: null } });

    const removed = await write(
      { method: "DELETE", path: "/api/rosters/r1", status: 204 },
      "c2Vzc2lvbg",
    );
    const posted = await write(
      { method: "POST", path: "/api/rosters/r1", status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(removed).toEqual({ ok: true, value: null });
    expect(posted).toMatchObject({ ok: false, failure: { status: 404 } });
  });

  it("puts a fixture through the real decoder, so a wrong shape fails here too", async () => {
    const write = writesTo({ "POST /api/claims": { body: { engagement: {} } } });

    const result = await write(
      { method: "POST", path: "/api/claims", status: 201 },
      "c2Vzc2lvbg",
      () => null,
    );

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "malformed_response", status: 201 },
    });
  });

  it("answers a named refusal, which is what most of these surfaces are driven through", async () => {
    const write = writesTo({
      "POST /api/claims": {
        failure: {
          kind: "api_error",
          status: 410,
          code: "unrecognised",
          rawCode: "gone",
          message: "that claim code has expired",
        },
      },
    });

    const result = await write(
      { method: "POST", path: "/api/claims", status: 201 },
      "c2Vzc2lvbg",
      (body) => body,
    );

    expect(result).toMatchObject({
      ok: false,
      failure: { status: 410, message: "that claim code has expired" },
    });
  });
});
