import { describe, expect, it, vi } from "vitest";

import type * as RoomModule from "./room";
import {
  isRoomId,
  mergeMessages,
  normaliseRoomId,
  roomFallbackLabel,
  roomKey,
  roomKindLabel,
  roomLabel,
  roomTopic,
  sameRoom,
  shiftRoomLabel,
} from "./room";

const ID = "11111111-1111-4111-8111-111111111111";

/**
 * Runs against a copy of `room.ts` that resolved a named timezone.
 *
 * **Nothing in this file may format in the runner's timezone.** A cross-midnight
 * test is a claim about which calendar day two instants fall on, and every one
 * of them has a timezone in which it is false — so a fixture chosen against
 * whatever machine happened to run it first is green here and red on CI, or
 * green everywhere while asserting nothing. Each case below names the timezone
 * it means, and two of them name the same instants twice to opposite effect.
 *
 * It re-imports rather than poking at the environment around the static import
 * because `room.ts` builds its `Intl.DateTimeFormat`s once at module load —
 * they are expensive and the label runs per room per render — so each one holds
 * the timezone that was in force when the module first ran. Changing
 * `process.env.TZ` afterwards moves `Intl`'s default for formatters built after
 * the change and for none built before it.
 *
 * The locale is left alone: Node fixes it at startup and `LANG` will not move
 * it, so no assertion below may depend on one. Each reads the rendering of an
 * instant back out of `instantLabel` instead of spelling `9 Mar` itself.
 */
async function inTimeZone<T>(
  timeZone: string,
  ask: (room: typeof RoomModule) => T,
): Promise<T> {
  const before = process.env.TZ;

  process.env.TZ = timeZone;
  vi.resetModules();

  try {
    return ask(await import("./room"));
  } finally {
    if (before === undefined) {
      delete process.env.TZ;
    } else {
      process.env.TZ = before;
    }

    vi.resetModules();
  }
}

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

describe("what a row in the recently-opened list is called", () => {
  const listed = { ref: { kind: "venue", id: ID }, barred: null } as const;

  it("prefers the live name, so a renamed venue corrects itself", () => {
    // The stored name is what this browser last saw and the live one is the
    // server's answer now. Reversing the two leaves a venue renamed six months
    // ago reading under its old name for as long as the bookmark survives,
    // with nothing to invalidate it and no way to notice.
    expect(roomLabel({ ...listed, name: "The Old Anchor" }, "The Anchor")).toBe(
      "The Anchor",
    );
  });

  it("falls back to the stored name, which is all a collapsed shift room has", () => {
    expect(roomLabel({ ...listed, name: "Kitchen · Mon" }, null)).toBe("Kitchen · Mon");
  });

  it("falls back to the kind and eight characters when it has never had a name", () => {
    // Written out rather than composed from `shortId`, and both kinds, because
    // this is the string the row shows when everything else is absent.
    expect(roomLabel({ ...listed, name: null }, null)).toBe("venue room 11111111");
    expect(
      roomFallbackLabel({ kind: "shift", id: "22222222-2222-4222-8222-222222222222" }),
    ).toBe("shift room 22222222");
  });

  it("tells two nameless rooms of one kind apart, which is why it is not the bare kind", () => {
    // The reachable case: two of a venue's shifts bookmarked, then a reload
    // with that venue never expanded. "Shift room" twice would be two
    // identical rows over two different conversations.
    const one = roomFallbackLabel({
      kind: "shift",
      id: "22222222-2222-4222-8222-222222222222",
    });
    const other = roomFallbackLabel({
      kind: "shift",
      id: "33333333-3333-4333-8333-333333333333",
    });

    expect(one).not.toBe(other);
  });

  it("never puts a whole uuid in a row, which is what was reported", () => {
    // The control is the positive assertion beside it: the label is a real
    // string, so "contains no uuid" is not passing against an empty one.
    const label = roomLabel({ ...listed, name: null }, null);

    expect(label).not.toContain(ID);
    expect(label).toContain("11111111");
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

  // Written when a worker pasted ids into a box, and kept now that #80 has
  // taken the box away: the stored list is decoded through this same function,
  // and a list written by an older build or edited by hand in devtools is where
  // a stray space arrives from now.
  it("trims, so a stray space around an id is still an id", () => {
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

  // 23:00 to 07:00 the next morning in UTC, and 02:00 to 10:00 the same morning
  // three hours east of it. Both endpoints move together, so the term is eight
  // hours either way and only the calendar disagrees.
  const overnight = {
    ...kitchen,
    startsAt: "2026-03-09T23:00:00Z",
    endsAt: "2026-03-10T07:00:00Z",
    closesAt: "2026-03-10T07:30:00Z",
  };

  // The same trick pointed the other way: one evening in UTC, and an evening
  // running into the next morning in Moscow.
  const evening = {
    ...kitchen,
    startsAt: "2026-03-09T20:00:00Z",
    endsAt: "2026-03-09T23:00:00Z",
    closesAt: "2026-03-09T23:30:00Z",
  };

  it("says which day a term ends on when that is not the day it starts", async () => {
    // The finding. A late shift crossing midnight is the ordinary shape of a
    // hospitality working day, and the demo manifest's own live shift room is
    // one whenever it is seeded after the afternoon — so writing the end as a
    // time alone produced `Kitchen · 9 Mar 23:00–07:00`, which reads as a room
    // that closes sixteen hours before it opens.
    await inTimeZone("UTC", ({ instantLabel, shiftRoomLabel }) => {
      const label = shiftRoomLabel(overnight);

      // The start always carries its day, and asserting it here is what stops
      // the assertion below passing on a label that formats nothing at all.
      expect(label).toContain(instantLabel(overnight.startsAt));
      expect(label).toContain(instantLabel(overnight.endsAt));
    });
  });

  it("leaves the end a time alone when the term begins and ends on one day", async () => {
    // The control for the test above: a rule that wrote the day out
    // unconditionally would pass that one and lose the reason the term is short
    // in the ordinary case.
    await inTimeZone("UTC", ({ instantLabel, shiftRoomLabel }) => {
      const label = shiftRoomLabel(evening);

      expect(label).toContain(instantLabel(evening.startsAt));
      expect(label).not.toContain(instantLabel(evening.endsAt));
    });
  });

  it("asks which day in the timezone it renders in, so one term reads two ways", async () => {
    // The subtlety, and the reason this label is composed on the client at all:
    // "a different day" is a question about the reader, and these two rooms are
    // the same eight and three hours in both columns. Answering in UTC — with
    // `getUTCDate`, or by comparing the ISO strings' date halves — passes the
    // first column and fails the second; answering in the venue's timezone
    // fails both for a worker reading from anywhere else.
    const asked = async (timeZone: string) =>
      inTimeZone(timeZone, ({ instantLabel, shiftRoomLabel }) => ({
        overnight: shiftRoomLabel(overnight).includes(instantLabel(overnight.endsAt)),
        evening: shiftRoomLabel(evening).includes(instantLabel(evening.endsAt)),
      }));

    // 23:00–07:00 crosses; 20:00–23:00 does not.
    expect(await asked("UTC")).toEqual({ overnight: true, evening: false });

    // Three hours east both endpoints shift: 02:00–10:00 is one morning, and
    // 23:00–02:00 is the one that now crosses.
    expect(await asked("Europe/Moscow")).toEqual({ overnight: false, evening: true });
  });
});

describe("one instant on its own", () => {
  const room = {
    shiftRoomId: "22222222-2222-4222-8222-222222222222",
    venueId: ID,
    shiftTypeName: "Kitchen",
    startsAt: "2026-03-09T21:30:00Z",
    endsAt: "2026-03-10T05:30:00Z",
    closesAt: "2026-03-10T06:00:00Z",
  };

  it("is the same rendering a term gives that instant, rather than a second one", async () => {
    // A shift room's `closes_at` is shown beside its term, so the two are one
    // sentence or they are a formatted value next to an ISO string — which is
    // what `rooms-route.tsx` used to put there.
    await inTimeZone("UTC", ({ instantLabel, shiftRoomLabel }) => {
      expect(instantLabel(room.closesAt)).not.toBe(room.closesAt);

      expect(shiftRoomLabel({ ...room, startsAt: room.closesAt })).toContain(
        instantLabel(room.closesAt),
      );
    });
  });

  it("hands back what it was given rather than rendering Invalid Date", async () => {
    // Same fallback the term already has, and for the same reason.
    await inTimeZone("UTC", ({ instantLabel }) => {
      expect(instantLabel("whenever")).toBe("whenever");
    });
  });
});

describe("merging a room's history with its stream", () => {
  const message = (id: string, body: string) => ({
    id,
    body,
    sentAt: "2026-07-28T09:00:00Z",
    authorEngagementId: "33333333-3333-4333-8333-333333333333",
    authorDisplayName: "Captain Nemo",
    authorRoleLabel: "Head Chef",
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
