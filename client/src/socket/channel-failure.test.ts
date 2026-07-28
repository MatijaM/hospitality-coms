import { describe, expect, it } from "vitest";

import { decodeChannelRefusal } from "./channel-failure";

/**
 * A vocabulary of this test's own, not the rooms'.
 *
 * The point of the decoder taking its codes as an argument is that no surface
 * owns the list, so importing `ROOM_ERROR_CODES` here would be testing the
 * rooms' choices rather than the narrowing.
 */
const CODES = ["unauthorized", "gone", "unprocessable_entity"] as const;

describe("decoding a channel refusal", () => {
  it("reads the envelope a channel replies with", () => {
    expect(
      decodeChannelRefusal(
        {
          error: { code: "gone", message: "that shift room is closed to new messages" },
        },
        CODES,
      ),
    ).toEqual({
      kind: "channel_error",
      code: "gone",
      rawCode: "gone",
      message: "that shift room is closed to new messages",
    });
  });

  it("keeps `fields` present and `fields` absent as two different answers", () => {
    const refusal = decodeChannelRefusal(
      {
        error: {
          code: "unprocessable_entity",
          message: "the message was rejected",
          fields: { body: ["can't be blank"] },
        },
      },
      CODES,
    );

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
      decodeChannelRefusal({ error: { code: "gone", message: "x", fields: {} } }, CODES),
    ).toEqual({
      kind: "channel_field_error",
      code: "gone",
      rawCode: "gone",
      message: "x",
      fields: {},
    });
  });

  it("narrows to the caller's vocabulary and nothing wider", () => {
    for (const code of CODES) {
      expect(
        decodeChannelRefusal({ error: { code, message: "…" } }, CODES),
      ).toMatchObject({ code, rawCode: code });
    }
  });

  it("calls a code outside the caller's set unrecognised, keeping the wire value", () => {
    // This is the coupling the type parameter exists to prevent. `forbidden` is
    // a code the room channels really do emit, and a surface that cannot meet
    // it has no business being made to write copy for it — U8's nine peer
    // events reach a room the same way.
    expect(
      decodeChannelRefusal({ error: { code: "forbidden", message: "…" } }, CODES),
    ).toMatchObject({ code: "unrecognised", rawCode: "forbidden" });
    expect(
      decodeChannelRefusal({ error: { code: "im_a_teapot", message: "…" } }, CODES),
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
      expect(decodeChannelRefusal(payload, CODES)).toEqual({
        kind: "malformed_refusal",
        message: "the refusal was not the error envelope",
      });
    }
  });
});
