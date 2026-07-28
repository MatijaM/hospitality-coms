import { describe, expect, it } from "vitest";

import { decodeChannelRefusal } from "./channel-failure";

describe("decoding a channel refusal", () => {
  it("reads the envelope a channel replies with", () => {
    expect(
      decodeChannelRefusal({
        error: { code: "gone", message: "that shift room is closed to new messages" },
      }),
    ).toEqual({
      kind: "channel_error",
      code: "gone",
      rawCode: "gone",
      message: "that shift room is closed to new messages",
    });
  });

  it("keeps `fields` present and `fields` absent as two different answers", () => {
    const refusal = decodeChannelRefusal({
      error: {
        code: "unprocessable_entity",
        message: "the message was rejected",
        fields: { body: ["can't be blank"] },
      },
    });

    expect(refusal).toEqual({
      kind: "channel_field_error",
      code: "unprocessable_entity",
      rawCode: "unprocessable_entity",
      message: "the message was rejected",
      fields: { body: ["can't be blank"] },
    });
  });

  it("carries an empty `fields` as a field error, because the envelope wrote one", () => {
    // `ErrorEnvelope.new/3` renders the key whenever the failure is per-field.
    // An empty map is the server saying "per-field, and none of them", which
    // is not the same answer as saying nothing.
    expect(
      decodeChannelRefusal({ error: { code: "gone", message: "x", fields: {} } }),
    ).toEqual({
      kind: "channel_field_error",
      code: "gone",
      rawCode: "gone",
      message: "x",
      fields: {},
    });
  });

  it.each([
    ["unauthorized"],
    ["bad_request"],
    ["forbidden"],
    ["gone"],
    ["unprocessable_entity"],
  ])("recognises %s, which the room channels are traced as producing", (code) => {
    const refusal = decodeChannelRefusal({ error: { code, message: "…" } });

    expect(refusal).toMatchObject({ code, rawCode: code });
  });

  it("keeps a code nobody planned for, rather than dropping it", () => {
    expect(
      decodeChannelRefusal({ error: { code: "im_a_teapot", message: "…" } }),
    ).toMatchObject({ code: "unrecognised", rawCode: "im_a_teapot" });
  });

  it("calls anything that is not the envelope malformed, and never returns null", () => {
    // `phoenix` refuses with these two on its own, and neither is an
    // `ErrorEnvelope`: an unrouted topic, and the channel-count limit.
    for (const payload of [
      { reason: "unmatched topic" },
      { reason: "too many channels joined" },
      { error: "unauthorized" },
      { error: { code: 401, message: "…" } },
      { error: { code: "gone" } },
      { error: { code: "gone", message: "…", fields: { body: "not an array" } } },
      null,
      undefined,
      "unauthorized",
      [],
    ]) {
      expect(decodeChannelRefusal(payload)).toEqual({
        kind: "malformed_refusal",
        message: "the refusal was not the error envelope",
      });
    }
  });
});
