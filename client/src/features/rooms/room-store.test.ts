import { afterEach, describe, expect, it, vi } from "vitest";

import type { RoomEntry, RoomRef } from "./room";
import {
  RECENT_ROOM_LIMIT,
  createBrowserRoomStore,
  createLocalStorageRoomStore,
  decodeRoomEntries,
  findRoom,
  recordOpening,
  removeRoom,
  setRoomBar,
} from "./room-store";

const VENUE: RoomRef = { kind: "venue", id: "11111111-1111-4111-8111-111111111111" };
const SHIFT: RoomRef = { kind: "shift", id: "22222222-2222-4222-8222-222222222222" };
const OTHER: RoomRef = { kind: "venue", id: "33333333-3333-4333-8333-333333333333" };

function entry(
  ref: RoomRef,
  barred: RoomEntry["barred"] = null,
  name: string | null = null,
): RoomEntry {
  return { ref, barred, name };
}

/** A distinct venue room per index, so a list's order can be read back. */
function numbered(index: number): RoomRef {
  const digits = index.toString().padStart(4, "0");

  return { kind: "venue", id: `${digits}0000-0000-4000-8000-000000000000` };
}

/** A `Storage` that keeps its own map, so no global is touched. */
function memoryStorage(initial: Record<string, string> = {}): Storage {
  const values = new Map(Object.entries(initial));

  return {
    get length() {
      return values.size;
    },
    clear: () => {
      values.clear();
    },
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => {
      values.delete(key);
    },
    setItem: (key, value) => {
      values.set(key, value);
    },
  };
}

/** A `Storage` that refuses, as private-mode Safari does on write. */
function refusingStorage(): Storage {
  const refuse = () => {
    throw new DOMException("refused", "SecurityError");
  };

  return {
    get length(): number {
      return refuse();
    },
    clear: refuse,
    getItem: refuse,
    key: refuse,
    removeItem: refuse,
    setItem: refuse,
  };
}

describe("the list", () => {
  it("adds a room, with the name it was opened under", () => {
    expect(recordOpening([], VENUE, "The Anchor")).toEqual([
      entry(VENUE, null, "The Anchor"),
    ]);
  });

  it("adds a room that has no name to offer", () => {
    expect(recordOpening([], VENUE)).toEqual([entry(VENUE)]);
  });

  it("moves a room already listed to the front rather than listing it twice", () => {
    // "Recently opened" is a claim about order and nothing stores an instant,
    // so position is the only thing that can carry it. The count is asserted
    // too, because a duplicate at the front satisfies the order on its own.
    const entries = [entry(VENUE), entry(SHIFT), entry(OTHER)];

    const reopened = recordOpening(entries, OTHER);

    expect(reopened.map((each) => each.ref)).toEqual([OTHER, VENUE, SHIFT]);
    expect(reopened).toHaveLength(3);
  });

  it("does not reset what was learned when a room is opened again", () => {
    // The bar is the only thing in the list that came from the server, and
    // re-opening a room is not new information about whether it takes
    // messages. It travels with the row to the front.
    const entries = [entry(VENUE), entry(SHIFT, "room_closed")];

    expect(recordOpening(entries, SHIFT)).toEqual([
      entry(SHIFT, "room_closed"),
      entry(VENUE),
    ]);
  });

  it("keeps the stored name when the caller has none, and takes a fresh one", () => {
    // The first half is what a shift room re-opened from this list depends on:
    // its venue is collapsed, so there is no live name to pass, and wiping the
    // stored one would put the uuid back at the moment the shortcut was used.
    const stored = [entry(SHIFT, null, "Kitchen · Mon")];

    expect(recordOpening(stored, SHIFT)).toEqual([entry(SHIFT, null, "Kitchen · Mon")]);
    expect(recordOpening(stored, SHIFT, "Kitchen · Tue")).toEqual([
      entry(SHIFT, null, "Kitchen · Tue"),
    ]);
  });

  it("answers the same list when re-opening the room already at the front", () => {
    // `RoomsRoute` writes to storage only when this changes something, so this
    // identity is what stops a `localStorage` write on every click.
    const entries = [entry(VENUE, null, "The Anchor"), entry(SHIFT)];

    expect(recordOpening(entries, VENUE, "The Anchor")).toBe(entries);
    expect(recordOpening(entries, VENUE)).toBe(entries);

    // And it is an identity about the list, not about the room: a new name is
    // a change, and so is a room that is listed but not at the front.
    expect(recordOpening(entries, VENUE, "The Anchor Inn")).not.toBe(entries);
    expect(recordOpening(entries, SHIFT)).not.toBe(entries);
  });

  it("evicts the oldest when the list is full, never the newest", () => {
    // Nothing removes an entry any more — the "Forget" control went — so this
    // bound is the only thing between the list and unbounded growth in
    // `localStorage`.
    //
    // The surviving ids are named rather than counted: a cap that kept the
    // *oldest* `RECENT_ROOM_LIMIT` rooms and dropped the room just opened
    // satisfies a length assertion exactly as well as this one does.
    let entries: readonly RoomEntry[] = [];

    // One more than fits, oldest first — room 0 is opened first.
    for (let index = 0; index <= RECENT_ROOM_LIMIT; index += 1) {
      entries = recordOpening(entries, numbered(index));
    }

    const listed = entries.map((each) => each.ref.id);

    expect(listed).toHaveLength(RECENT_ROOM_LIMIT);
    // The one just opened is at the front and the first one opened is gone.
    expect(listed[0]).toBe(numbered(RECENT_ROOM_LIMIT).id);
    expect(listed).not.toContain(numbered(0).id);
    // The control on that absence: everything between the two is still here,
    // so "the oldest went" is distinguishable from "all but the newest went".
    expect(listed).toContain(numbered(1).id);
    expect(listed[listed.length - 1]).toBe(numbered(1).id);
  });

  it("keeps twelve rooms, which is written here and in one place in the source", () => {
    // Deliberately a literal rather than anything derived: every other
    // assertion in this file builds its fixture *from* the constant, so all of
    // them pass for any value of it.
    expect(RECENT_ROOM_LIMIT).toBe(12);
  });

  it("removes a room without touching the others", () => {
    expect(removeRoom([entry(VENUE), entry(SHIFT)], VENUE)).toEqual([entry(SHIFT)]);
  });

  it("sets and clears a bar on one room only, and keeps its name", () => {
    // The name is in the fixture because this function rebuilds the entry it
    // touches: written as `{ ref, barred }` it silently dropped the name, and
    // the row it had just learned something about became a uuid.
    const entries = [entry(VENUE), entry(SHIFT, null, "Kitchen · Mon")];

    expect(setRoomBar(entries, SHIFT, "not_rostered")).toEqual([
      entry(VENUE),
      entry(SHIFT, "not_rostered", "Kitchen · Mon"),
    ]);
    expect(
      setRoomBar([entry(SHIFT, "room_closed", "Kitchen · Mon")], SHIFT, null),
    ).toEqual([entry(SHIFT, null, "Kitchen · Mon")]);
  });

  it("finds a room by its topic, and answers null for one that is not there", () => {
    expect(
      findRoom([entry(VENUE)], "venue_room:11111111-1111-4111-8111-111111111111"),
    ).toEqual(entry(VENUE));
    expect(findRoom([entry(VENUE)], "shift_room:whatever")).toBeNull();
  });
});

describe("what survives a reload", () => {
  it("round-trips a list with and without a bar, and with and without a name", () => {
    const storage = memoryStorage();
    const store = createLocalStorageRoomStore(storage);
    const entries = [entry(VENUE), entry(SHIFT, "room_closed", "Kitchen · Mon")];

    store.write(entries);

    expect(store.read()).toEqual(entries);
  });

  it("carries a name across the reload a shift room's name cannot survive without", () => {
    // The point of storing it at all. A venue room's name arrives with
    // `GET /api/venue-rooms` and is therefore always available; a shift room's
    // arrives only for the venue currently expanded, so after a reload with
    // that venue collapsed this is the only copy anywhere in the client.
    const storage = memoryStorage();

    createLocalStorageRoomStore(storage).write([entry(SHIFT, null, "Kitchen · Mon")]);

    expect(createLocalStorageRoomStore(storage).read()).toEqual([
      entry(SHIFT, null, "Kitchen · Mon"),
    ]);
  });

  it("forgets the list outright when the session ends", () => {
    // Not "writes an empty array": the key goes, so a shared terminal is left
    // with nothing of the previous worker's on disk at all. `SessionProvider`
    // calls this wherever it drops the token.
    const storage = memoryStorage();
    const store = createLocalStorageRoomStore(storage);

    store.write([entry(VENUE), entry(SHIFT, "room_closed")]);
    store.clear();

    expect(store.read()).toEqual([]);
    expect(storage.getItem("hospitality-coms.rooms")).toBeNull();
  });

  it("does not throw when storage refuses to forget", () => {
    expect(() => {
      createLocalStorageRoomStore(refusingStorage()).clear();
    }).not.toThrow();
  });

  it("starts empty rather than throwing when storage refuses", () => {
    // Same contract `TokenStore` has, for the same reason: a store that throws
    // takes the whole surface down with it.
    const store = createLocalStorageRoomStore(refusingStorage());

    expect(() => {
      store.write([entry(VENUE)]);
    }).not.toThrow();
    expect(store.read()).toEqual([]);
  });

  it("discards a stored value it does not recognise rather than repairing it", () => {
    // It is a bookmark list. Losing it costs a paste; half-reading it would
    // put a room reference with no kind on a socket.
    for (const stored of [
      "not json",
      "{}",
      '[{"id": "x"}]',
      '[{"kind": "peer", "id": "11111111-1111-4111-8111-111111111111"}]',
      '[{"kind": "venue", "id": "11111111-1111-4111-8111-111111111111", "barred": "nope"}]',
      // A `name` that is present and is not a string. No build of this client
      // ever wrote one, so it is devtools or corruption, and the rule is the
      // same as for every other field: discarded, not repaired. It is the
      // *absent* name that is tolerated, and that is the next test.
      '[{"kind": "venue", "id": "11111111-1111-4111-8111-111111111111", "name": 7}]',
    ]) {
      const store = createLocalStorageRoomStore(
        memoryStorage({ "hospitality-coms.rooms": stored }),
      );

      expect(store.read()).toEqual([]);
    }
  });

  it("is the only place an id is checked before it becomes a topic", () => {
    // It used to be the looser of a pair: the paste box required a uuid and
    // this took any string at all, so the reachable path was the wrong one — a
    // list written by an older build, or edited by hand in devtools, ending up
    // as a topic suffix the server can only answer with the same refusal it
    // gives an unknown room. #80 removed the box, which leaves this as the sole
    // check rather than the weaker of two.
    expect(decodeRoomEntries([{ kind: "venue", id: "not-an-id" }])).toBeNull();

    // Carries hex letters on purpose: the other ids here are all digits, where
    // `toUpperCase()` would make the normalisation half of this vacuous.
    const mixed = "a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5";
    expect(decodeRoomEntries([{ kind: "venue", id: mixed.toUpperCase() }])).toEqual([
      entry({ kind: "venue", id: mixed }),
    ]);
  });

  it("reads a missing `barred` as no bar, so an older list still loads", () => {
    expect(
      decodeRoomEntries([{ kind: "venue", id: "11111111-1111-4111-8111-111111111111" }]),
    ).toEqual([entry(VENUE)]);
  });

  it("reads an entry written before names were stored, rather than dropping it", () => {
    // Every entry in every real browser is this shape. A decoder that required
    // `name` would answer `null` for the whole array — `decodeRoomEntries`
    // discards the list, not the row — so the deploy that added the field would
    // have silently emptied everybody's list, which is exactly the failure that
    // looks like nothing having happened.
    //
    // Written as the JSON an older build actually wrote, through the whole
    // store, because that is the path that runs on somebody's phone.
    const oldShape =
      '[{"kind":"venue","id":"11111111-1111-4111-8111-111111111111","barred":null},' +
      '{"kind":"shift","id":"22222222-2222-4222-8222-222222222222","barred":"room_closed"}]';

    const store = createLocalStorageRoomStore(
      memoryStorage({ "hospitality-coms.rooms": oldShape }),
    );

    expect(store.read()).toEqual([entry(VENUE), entry(SHIFT, "room_closed")]);
  });
});

/**
 * Both of these say what `localStorage` is rather than inheriting it, for the
 * reason `token-store.test.ts` sets out at length: which branch this function
 * takes depends on whether the runner provides web storage, so a test that read
 * the ambient global would cover one branch here and the other on another
 * machine, and report full coverage of a choice it never made.
 */
describe("choosing a store for the browser", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps the list in the browser's storage, so it survives a reload", () => {
    const storage = memoryStorage();
    vi.stubGlobal("localStorage", storage);
    const entries = [entry(VENUE), entry(SHIFT, "room_closed")];

    createBrowserRoomStore().write(entries);

    expect(storage.getItem("hospitality-coms.rooms")).not.toBeNull();

    // A second build against the same storage is the reload: `main.tsx` calls
    // this at module scope, and the bookmarks are still there.
    expect(createBrowserRoomStore().read()).toEqual(entries);
  });

  it("falls back to memory when there is no localStorage to reach", () => {
    // A runtime with no web storage leaves the property `undefined`, and
    // reading `.getItem` off it is a TypeError at module scope — which is the
    // whole surface rendering as a blank page rather than a lost bookmark list.
    vi.stubGlobal("localStorage", undefined);

    const store = createBrowserRoomStore();

    store.write([entry(VENUE)]);

    expect(store.read()).toEqual([entry(VENUE)]);
  });
});
