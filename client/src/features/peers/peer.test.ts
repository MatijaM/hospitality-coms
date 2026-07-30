import { describe, expect, it } from "vitest";

import {
  REQUEST_STATES,
  normalisePersonId,
  peerKey,
  peerTopic,
  requestStateLabel,
  requestStateMessage,
  shortId,
} from "./peer";

const ID = "a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5";

describe("the peer topic", () => {
  it("is the one PersonSocket routes, with the person as the suffix", () => {
    expect(peerTopic(ID)).toBe(`peer:${ID}`);
  });
});

describe("normalising a person id", () => {
  it("lowercases, because PubSub broadcasts on the literal topic string", () => {
    // The failure this prevents is silent and total. `Ecto.UUID.cast/1`
    // downcases, so an uppercase suffix still matches the session's own person
    // at `admitted/3` and the join *succeeds* — but `Phoenix.Channel.Server`
    // subscribes the channel to the literal string, and
    // `HospitalityComs.Peers.topic/1` publishes to the lowercase one. The
    // channel would answer every push and receive no announcement, ever.
    expect(normalisePersonId(ID.toUpperCase())).toBe(ID);
    expect(peerTopic(normalisePersonId(ID.toUpperCase()) ?? "")).toBe(`peer:${ID}`);
  });

  it("trims, so a pasted id with a stray space is still an id", () => {
    expect(normalisePersonId(`  ${ID}\n`)).toBe(ID);
  });

  it("refuses anything that is not the shape a topic suffix may carry", () => {
    // `ChannelAuth.topic_id/1`'s rule: 36 bytes, then a uuid cast. The byte
    // size is load-bearing rather than a pre-filter — `cast/1` alone accepts
    // sixteen raw bytes and encodes them.
    expect(normalisePersonId("")).toBeNull();
    expect(normalisePersonId("not-an-id")).toBeNull();
    expect(normalisePersonId(`${ID}extra`)).toBeNull();
    expect(normalisePersonId(ID.replace("-", ""))).toBeNull();
  });
});

describe("what the surface renders about a request", () => {
  it("has a label and a sentence for every state the server can report", () => {
    // The four `ConnectionRequest.state/2` can answer. A fifth would fail the
    // build inside these switches rather than render as nothing.
    expect(REQUEST_STATES).toEqual(["pending", "lapsed", "declined", "accepted"]);

    for (const state of REQUEST_STATES) {
      expect(requestStateLabel(state)).not.toBe("");
      expect(requestStateMessage(state)).not.toBe("");
    }
  });

  it("says a lapsed request was not refused, because nobody refused it", () => {
    // `:lapsed` is derived at the asking instant and can go back to `:pending`
    // if the pair is co-rostered again. Rendering it as a rejection would be
    // this client inventing a decision the server did not make.
    expect(requestStateMessage("lapsed")).toMatch(/nobody refused it/i);
    expect(requestStateMessage("declined")).toMatch(/said no/i);
  });
});

describe("keys and ids", () => {
  it("keys a peer entry on the counterpart and the venue, because both repeat", () => {
    // `list_visible_peers/1` is one entry per counterpart per venue, so the
    // person id alone is not unique across the list.
    const base = {
      personId: ID,
      displayName: "Captain Nemo",
      venueName: "The Anchor",
      roleLabel: "Bartender",
      visibleFrom: "2026-07-01T00:00:00Z",
      visibleUntil: "2026-09-01T00:00:00Z",
    };

    expect(peerKey({ ...base, venueId: "one" })).not.toBe(
      peerKey({ ...base, venueId: "two" }),
    );
  });

  it("shortens an id for reading and never invents a name", () => {
    expect(shortId(ID)).toBe("a1a1a1a1");
  });
});
