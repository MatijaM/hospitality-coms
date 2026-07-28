import { describe, expect, it } from "vitest";

import {
  isRoomId,
  mergeMessages,
  normaliseRoomId,
  roomKey,
  roomKindLabel,
  roomTopic,
  sameRoom,
  shiftRoomLabel,
} from "./room";

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

  it("lowercases, because the topic string is what PubSub fans out on", () => {
    // `Ecto.UUID.cast/1` takes either case and Postgres stores one value, so
    // both cases reach the same rows — but `broadcast!/3` fans out on the
    // literal topic. Two sessions naming one venue in different cases would
    // write to the same table and see none of each other's messages, which
    // looks broken from inside the room and correct from the database.
    const mixed = "A1A1A1A1-b2b2-4C3C-8d4d-E5E5E5E5E5E5";

    expect(normaliseRoomId(mixed)).toBe("a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5");
    expect(roomTopic({ kind: "venue", id: normaliseRoomId(mixed) ?? "" })).toBe(
      "venue_room:a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5",
    );
  });

  it("trims, so a paste with a stray space is still an id", () => {
    expect(normaliseRoomId(`  ${ID}\n`)).toBe(ID);
  });

  it("answers null for anything that is not an id, rather than a topic suffix", () => {
    expect(normaliseRoomId("not-an-id")).toBeNull();
    expect(normaliseRoomId("")).toBeNull();
    expect(normaliseRoomId("sixteen bytes!!!")).toBeNull();
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

describe("a shift room's label", () => {
  const kitchen = {
    shiftRoomId: "22222222-2222-4222-8222-222222222222",
    venueId: ID,
    shiftTypeName: "Kitchen",
    startsAt: "2026-03-09T13:00:00Z",
    endsAt: "2026-03-09T21:00:00Z",
    closesAt: "2026-03-09T21:30:00Z",
  };

  it("names the shift type, because the room has no name of its own", () => {
    // `ShiftRoom` carries two instants and a `shift_type_id` and nothing else a
    // person could read. Without the type's name the list is uuid prefixes,
    // which is what `GET /api/venues/:venue_id/shift-rooms` exists to stop.
    expect(shiftRoomLabel(kitchen)).toContain("Kitchen");
    expect(shiftRoomLabel(kitchen)).not.toContain(kitchen.shiftRoomId);
  });

  it("tells two shifts of one type apart, which the name alone cannot", () => {
    // Two Tuesdays of one shift type are two rooms with one name, so a label
    // that were only `shiftTypeName` would be as ambiguous as the uuid it
    // replaced — differently, and less obviously.
    const tuesday = {
      ...kitchen,
      shiftRoomId: "33333333-3333-4333-8333-333333333333",
      startsAt: "2026-03-10T13:00:00Z",
      endsAt: "2026-03-10T21:00:00Z",
      closesAt: "2026-03-10T21:30:00Z",
    };

    expect(shiftRoomLabel(tuesday)).not.toBe(shiftRoomLabel(kitchen));
  });

  it("falls back to the raw instants rather than rendering Invalid Date", () => {
    // An instant this client cannot read is still something a worker can
    // compare against another one.
    const broken = { ...kitchen, startsAt: "whenever", endsAt: "later" };

    expect(shiftRoomLabel(broken)).toContain("whenever");
    expect(shiftRoomLabel(broken)).not.toContain("Invalid");
  });
});

describe("merging a room's history with its stream", () => {
  const message = (id: string, body: string) => ({
    id,
    body,
    sentAt: "2026-07-28T09:00:00Z",
    authorEngagementId: "33333333-3333-4333-8333-333333333333",
  });

  it("puts the fetched history first and appends what arrived after", () => {
    const merged = mergeMessages([message("a", "one")], [message("b", "two")]);

    expect(merged.map((entry) => entry.body)).toEqual(["one", "two"]);
  });

  it("shows a message once when it arrives on both paths", () => {
    // The history is fetched over HTTP and the channel is joined separately, so
    // a message sent between the two is in both answers. Keying on the id is
    // the same manoeuvre `use-room.ts` makes for the send reply and the
    // broadcast of one message.
    const merged = mergeMessages(
      [message("a", "one"), message("b", "two")],
      [message("b", "two"), message("c", "three")],
    );

    expect(merged.map((entry) => entry.id)).toEqual(["a", "b", "c"]);
  });

  it("is the stream alone when nothing was fetched", () => {
    expect(mergeMessages([], [message("a", "one")]).map((entry) => entry.id)).toEqual([
      "a",
    ]);
  });
});
