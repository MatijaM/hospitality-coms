import { describe, expect, it } from "vitest";

import { decodeChannelRefusal } from "../../socket/channel-failure";
import type { PeerAction, PeerFailure } from "./refusal-message";
import {
  PEER_ERROR_CODES,
  closesConversation,
  isPeerErrorCode,
  refusalMessage,
} from "./refusal-message";

/** The envelope `ErrorEnvelope.new/2` builds, with a message nobody renders. */
function refusal(code: string, message = "SERVER-SIDE LOG SENTENCE"): PeerFailure {
  return decodeChannelRefusal({ error: { code, message } }, PEER_ERROR_CODES);
}

const ACTIONS: readonly PeerAction[] = [
  "join",
  "list",
  "request",
  "accept",
  "decline",
  "history",
  "send",
  "disconnect",
];

describe("the peer surface's vocabulary", () => {
  it("is the codes PeerChannel emits, and it is not the rooms'", () => {
    // Traced through `PeerChannel.refused/1`, `admit/2`, `admitted/3`,
    // `resolved/3` and `RoomChannel.unknown_event/1`. `conflict` is the one no
    // room channel can produce and `unauthorized` is join-only here.
    expect([...PEER_ERROR_CODES]).toEqual([
      "unauthorized",
      "bad_request",
      "not_found",
      "gone",
      "forbidden",
      "conflict",
      "unprocessable_entity",
    ]);

    expect(isPeerErrorCode("conflict")).toBe(true);
    expect(isPeerErrorCode("too_many_requests")).toBe(false);
  });

  it("has a sentence for every code and every action, and never the server's", () => {
    for (const action of ACTIONS) {
      for (const code of PEER_ERROR_CODES) {
        const message = refusalMessage(action, refusal(code));

        expect(message).not.toBe("");
        // The envelope's own documentation says `message` is for a human
        // reading a log. Rendering it would put untranslated internal copy in
        // front of somebody trying to answer a colleague.
        expect(message).not.toContain("SERVER-SIDE LOG SENTENCE");
      }
    }
  });
});

describe("not_found", () => {
  it("reads the same whichever event met it, which is AE1 kept intact", () => {
    // `:not_found` covers "does not exist" and "exists and is not yours"
    // identically, and `resolved/3` folds a malformed id in before a context is
    // reached. A client that rendered two sentences would hand back exactly the
    // distinction the server declines to make.
    const sentences = new Set(
      ACTIONS.map((action) => refusalMessage(action, refusal("not_found"))),
    );

    expect(sentences.size).toBe(1);
    expect([...sentences][0]).toMatch(/cannot tell you which/i);
  });
});

describe("conflict", () => {
  it("reads differently per event, because it is four refusals on one code", () => {
    // `:already_requested`, `:already_connected`, `:already_disconnected` and
    // `:disconnected` all arrive as `conflict`. The event this client pushed is
    // the discriminator the wire does not carry.
    const asking = refusalMessage("request", refusal("conflict"));
    const sending = refusalMessage("send", refusal("conflict"));

    expect(asking).toMatch(/already outstanding|already connected/i);
    expect(sending).toMatch(/closed/i);
    expect(asking).not.toBe(sending);
  });
});

describe("the codes that say more than not_found", () => {
  it("says a block means the next approach has to come from them", () => {
    // KTD19: the party who refused keeps the initiative. It is a statement
    // about something the caller was party to, so it discloses nothing they did
    // not already have — which is why the server is willing to say it.
    expect(refusalMessage("request", refusal("forbidden"))).toMatch(
      /has to come from them/i,
    );
  });

  it("says a lapsed request expired rather than that it was refused", () => {
    const message = refusalMessage("accept", refusal("gone"));

    expect(message).toMatch(/expired/i);
    expect(message).toMatch(/nobody refused it/i);
  });
});

describe("a timeout, which is not a refusal", () => {
  it("says a read changed nothing and a write may have gone through anyway", () => {
    // Telling somebody their message failed when it is sitting in the other
    // person's conversation is the one sentence here that could be actively
    // wrong.
    const timeout: PeerFailure = { kind: "channel_timeout" };

    expect(refusalMessage("list", timeout)).toMatch(/nothing has been refused/i);
    expect(refusalMessage("send", timeout)).toMatch(/may or may not/i);
  });
});

describe("what a refusal means for the conversation it named", () => {
  it("is a reason to ask again, and only for a send or a disconnect", () => {
    // The one real difference from `features/rooms/`. A room had to *remember*
    // `room_closed`, because nothing on the wire carries a shift room's
    // `closes_at`. Here `list_conversations` carries `open`, so this is a
    // trigger to re-ask and there is nothing to store and nothing to un-learn.
    expect(closesConversation(refusal("conflict"), "send")).toBe(true);
    expect(closesConversation(refusal("conflict"), "disconnect")).toBe(true);
    expect(closesConversation(refusal("conflict"), "request")).toBe(false);
    expect(closesConversation(refusal("not_found"), "send")).toBe(false);
    expect(closesConversation({ kind: "channel_timeout" }, "send")).toBe(false);
  });
});

describe("a refusal that is not the envelope", () => {
  it("still says something, because silence is the one wrong answer", () => {
    // `phoenix` itself refuses with `%{reason: "unmatched topic"}` and, at
    // `max_channels_per_transport`, `%{reason: "too many channels joined"}`.
    // Neither is an `ErrorEnvelope`.
    const failure = decodeChannelRefusal(
      { reason: "too many channels joined" },
      PEER_ERROR_CODES,
    );

    expect(refusalMessage("join", failure)).toMatch(/does not understand/i);
  });

  it("keeps a code it does not know rather than inventing copy for it", () => {
    const failure = refusal("teapot");

    expect(failure).toEqual(
      expect.objectContaining({ code: "unrecognised", rawCode: "teapot" }),
    );
    expect(refusalMessage("send", failure)).toContain("teapot");
  });
});
