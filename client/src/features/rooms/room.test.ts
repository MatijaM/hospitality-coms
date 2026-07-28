import { describe, expect, it } from "vitest";

import { isRoomId, roomKey, roomKindLabel, roomTopic, sameRoom } from "./room";

const ID = "11111111-1111-4111-8111-111111111111";

describe("a room's topic", () => {
  it("is the one PersonSocket routes for its kind", () => {
    // `channel "venue_room:*"` and `channel "shift_room:*"`, read out of
    // `HospitalityComsWeb.PersonSocket`. A prefix that is wrong by one
    // character is refused by Phoenix's dispatch with nothing in the
    // application's logs to say why.
    expect(roomTopic({ kind: "venue", id: ID })).toBe(`venue_room:${ID}`);
    expect(roomTopic({ kind: "shift", id: ID })).toBe(`shift_room:${ID}`);
  });

  it("distinguishes the two kinds at the same id", () => {
    // Nothing stops a venue and a shift room sharing an id across two tables,
    // and the two topics mean entirely different things.
    expect(roomKey({ kind: "venue", id: ID })).not.toBe(
      roomKey({ kind: "shift", id: ID }),
    );
    expect(sameRoom({ kind: "venue", id: ID }, { kind: "shift", id: ID })).toBe(false);
    expect(sameRoom({ kind: "venue", id: ID }, { kind: "venue", id: ID })).toBe(true);
  });

  it("names each kind for a reader", () => {
    expect(roomKindLabel("venue")).toBe("Venue room");
    expect(roomKindLabel("shift")).toBe("Shift room");
  });
});

describe("what may be a topic suffix", () => {
  it("accepts a canonical uuid, in either case", () => {
    expect(isRoomId(ID)).toBe(true);
    expect(isRoomId(ID.toUpperCase())).toBe(true);
  });

  it("refuses sixteen characters, which `Ecto.UUID.cast/1` alone would take", () => {
    // `ChannelAuth.topic_id/1` takes `byte_size(id) == 36` first, and says the
    // length is the load-bearing half rather than a pre-filter: `cast/1` on its
    // own also accepts sixteen raw bytes and encodes them.
    expect(isRoomId("sixteen bytes!!!")).toBe(false);
  });

  it("refuses everything else, including the near misses", () => {
    for (const value of [
      "",
      "not-an-id",
      `${ID} `,
      ID.slice(0, 35),
      `${ID}1`,
      "11111111-1111-4111-8111-11111111111g",
      "111111111111411181111111111111111111",
    ]) {
      expect(isRoomId(value)).toBe(false);
    }
  });
});
