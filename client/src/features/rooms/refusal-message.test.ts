import { describe, expect, it } from "vitest";

import type { ChannelFailure } from "../../socket/channel-failure";
import {
  KNOWN_CHANNEL_ERROR_CODES,
  decodeChannelRefusal,
  isKnownChannelErrorCode,
} from "../../socket/channel-failure";
import { failureMessage } from "../../app/failure-message";
import { barFromRefusal, barMessage, refusalMessage } from "./refusal-message";

/**
 * Built the way the decoder builds one, so an unknown wire code narrows to
 * `unrecognised` here exactly as it does in production. A cast would let this
 * file assert about a value `decodeChannelRefusal` can never produce.
 */
function refused(code: string, message = "SERVER-SIDE LOG SENTENCE"): ChannelFailure {
  return {
    kind: "channel_error",
    code: isKnownChannelErrorCode(code) ? code : "unrecognised",
    rawCode: code,
    message,
  };
}

describe("what a worker is told", () => {
  it("has a sentence for every code the room channels can refuse with", () => {
    for (const code of KNOWN_CHANNEL_ERROR_CODES) {
      const sentence = refusalMessage(refused(code));

      expect(sentence.length).toBeGreaterThan(0);
      expect(sentence).not.toContain("SERVER-SIDE LOG SENTENCE");
    }
  });

  it("names a code it does not know rather than saying nothing", () => {
    expect(
      refusalMessage(
        decodeChannelRefusal({ error: { code: "im_a_teapot", message: "…" } }),
      ),
    ).toContain("im_a_teapot");
  });

  it("says a timeout is a timeout, not a rejection", () => {
    // Nobody decided anything and the message may well have been written.
    // Telling a worker their message was rejected would be a lie about a row
    // that may exist.
    const sentence = refusalMessage({ kind: "channel_timeout" });

    expect(sentence).toMatch(/did not answer/i);
    expect(sentence).not.toMatch(/rejected|refused/i);
  });

  it("has a sentence for a refusal that is not the envelope", () => {
    expect(refusalMessage({ kind: "malformed_refusal", message: "x" })).toMatch(
      /does not understand/i,
    );
  });

  it("does not reuse the HTTP copy, which is about a different unauthorized", () => {
    // `unauthorized` from `POST /api/log-in/token` is a spent magic link and
    // the answer is "ask for a new link". `unauthorized` from a room channel
    // is an engagement that has ended, and there is no link to ask for.
    const room = refusalMessage(refused("unauthorized"));
    const http = failureMessage({
      kind: "api_error",
      status: 401,
      code: "unauthorized",
      rawCode: "unauthorized",
      message: "…",
    });

    expect(room).not.toBe(http);
    expect(room).not.toMatch(/link/i);
  });
});

describe("what a refusal means for the composer afterwards", () => {
  it("bars it for the two that are about the room", () => {
    expect(barFromRefusal(refused("gone"))).toBe("room_closed");
    expect(barFromRefusal(refused("forbidden"))).toBe("not_rostered");
  });

  it("leaves it alone for the ones that are about the message or the session", () => {
    // Barring on `unprocessable_entity` would make a typo look like a closure;
    // barring on `unauthorized` would hide a room the next join may well admit.
    expect(barFromRefusal(refused("unprocessable_entity"))).toBeNull();
    expect(barFromRefusal(refused("bad_request"))).toBeNull();
    expect(barFromRefusal(refused("unauthorized"))).toBeNull();
    expect(barFromRefusal(refused("im_a_teapot"))).toBeNull();
    expect(barFromRefusal({ kind: "channel_timeout" })).toBeNull();
    expect(barFromRefusal({ kind: "malformed_refusal", message: "x" })).toBeNull();
  });

  it("describes each bar as the different thing it is", () => {
    expect(barMessage("room_closed")).not.toBe(barMessage("not_rostered"));
    expect(barMessage("room_closed")).toMatch(/closed/i);
    expect(barMessage("not_rostered")).toMatch(/roster/i);
  });
});
