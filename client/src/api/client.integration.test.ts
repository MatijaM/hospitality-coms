/**
 * The four endpoints against a real Phoenix server, in order.
 *
 * Skipped unless `HOSPITALITY_COMS_API_URL` is set, so `npm test` on a machine
 * with no backend running is still green. It is the only test in this project
 * that proves the client's idea of the API matches the API, and it is worth
 * having because everything else here is written against a stub that this
 * project also wrote.
 *
 *     mix phx.server                              # in the repo root
 *     HOSPITALITY_COMS_API_URL=http://localhost:4000 npm test
 *
 * The magic link is read back out of `/dev/mailbox/json`, which is how a link
 * is read in development: nothing renders one, and the mailbox preview is a
 * dev-only route.
 */

import { describe, expect, it } from "vitest";

import { createApiClient } from "./client";

const baseUrl = process.env.HOSPITALITY_COMS_API_URL ?? "";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/** The most recent link mailed to this address, as its bare token. */
async function readMagicLinkToken(address: string): Promise<string> {
  const response = await fetch(`${baseUrl}/dev/mailbox/json`);
  const body: unknown = await response.json();

  if (!isRecord(body) || !Array.isArray(body.data)) {
    throw new Error("the mailbox preview answered in an unexpected shape");
  }

  const delivered = body.data
    .filter(isRecord)
    .filter((email) => JSON.stringify(email.to).includes(address))
    .at(-1);

  if (delivered === undefined) throw new Error(`no mail was sent to ${address}`);
  if (typeof delivered.text_body !== "string") throw new Error("the mail had no body");

  const link = /https?:\S+/.exec(delivered.text_body)?.[0];

  if (link === undefined) throw new Error("the mail carried no link");

  return link.split("/").filter(Boolean).at(-1) ?? "";
}

describe.skipIf(baseUrl === "")("against a running server", () => {
  it("registers, redeems, reads the session back, and ends it", async () => {
    const api = createApiClient({ baseUrl });
    const email = `u12-${Date.now().toString()}@example.com`;

    const requested = await api.requestMagicLink(email);
    expect(requested).toEqual({ ok: true, value: null });

    const session = await api.redeemMagicLink(await readMagicLinkToken(email));
    if (!session.ok) throw new Error(`redemption failed: ${JSON.stringify(session)}`);
    expect(session.value.person.email).toBe(email);

    const me = await api.currentPerson(session.value.token);
    expect(me).toEqual({ ok: true, value: session.value.person });

    expect(await api.logOut(session.value.token)).toEqual({ ok: true, value: null });

    const after = await api.currentPerson(session.value.token);
    expect(after).toMatchObject({
      ok: false,
      failure: { kind: "api_error", status: 401, code: "unauthorized" },
    });
  });

  it("answers a malformed address in the envelope, with the field named", async () => {
    const result = await createApiClient({ baseUrl }).requestMagicLink("not an address");

    expect(result).toMatchObject({
      ok: false,
      failure: {
        kind: "api_field_error",
        status: 422,
        code: "unprocessable_entity",
        fields: { email: expect.any(Array) as string[] },
      },
    });
  });

  it("answers a spent link with the same 401 as an invalid one", async () => {
    const api = createApiClient({ baseUrl });
    const email = `u12-spent-${Date.now().toString()}@example.com`;

    await api.requestMagicLink(email);
    const linkToken = await readMagicLinkToken(email);

    expect((await api.redeemMagicLink(linkToken)).ok).toBe(true);
    expect(await api.redeemMagicLink(linkToken)).toMatchObject({
      ok: false,
      failure: { kind: "api_error", status: 401, code: "unauthorized" },
    });
  });

  it("treats a bearer token that is not base64url as no token at all", async () => {
    // `PersonAuth` decodes the header before it looks anything up, so a token
    // that cannot be decoded is anonymous rather than an error of its own.
    const result = await createApiClient({ baseUrl }).currentPerson("not base64url!!");

    expect(result).toMatchObject({
      ok: false,
      failure: { kind: "api_error", status: 401, code: "unauthorized" },
    });
  });
});
