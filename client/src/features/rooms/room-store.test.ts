import { afterEach, describe, expect, it, vi } from "vitest";

import type { RoomEntry, RoomRef } from "./room";
import {
  addRoom,
  createBrowserRoomStore,
  createLocalStorageRoomStore,
  decodeRoomEntries,
  findRoom,
  removeRoom,
  setRoomBar,
} from "./room-store";

const VENUE: RoomRef = { kind: "venue", id: "11111111-1111-4111-8111-111111111111" };
const SHIFT: RoomRef = { kind: "shift", id: "22222222-2222-4222-8222-222222222222" };

function entry(ref: RoomRef, barred: RoomEntry["barred"] = null): RoomEntry {
  return { ref, barred };
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
  it("adds a room", () => {
    expect(addRoom([], VENUE)).toEqual([entry(VENUE)]);
  });

  it("does not reset what was learned when a room is added twice", () => {
    // The bar is the only thing in the list that came from the server. A paste
    // of an id already present is not new information about it.
    const existing = [entry(SHIFT, "room_closed")];

    expect(addRoom(existing, SHIFT)).toBe(existing);
  });

  it("removes a room without touching the others", () => {
    expect(removeRoom([entry(VENUE), entry(SHIFT)], VENUE)).toEqual([entry(SHIFT)]);
  });

  it("sets and clears a bar on one room only", () => {
    const entries = [entry(VENUE), entry(SHIFT)];

    expect(setRoomBar(entries, SHIFT, "not_rostered")).toEqual([
      entry(VENUE),
      entry(SHIFT, "not_rostered"),
    ]);
    expect(setRoomBar([entry(SHIFT, "room_closed")], SHIFT, null)).toEqual([
      entry(SHIFT),
    ]);
  });

  it("finds a room by its topic, and answers null for one that is not there", () => {
    expect(
      findRoom([entry(VENUE)], "venue_room:11111111-1111-4111-8111-111111111111"),
    ).toEqual(entry(VENUE));
    expect(findRoom([entry(VENUE)], "shift_room:whatever")).toBeNull();
  });
});

describe("what survives a reload", () => {
  it("round-trips a list with and without a bar", () => {
    const storage = memoryStorage();
    const store = createLocalStorageRoomStore(storage);
    const entries = [entry(VENUE), entry(SHIFT, "room_closed")];

    store.write(entries);

    expect(store.read()).toEqual(entries);
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
    ]) {
      const store = createLocalStorageRoomStore(
        memoryStorage({ "hospitality-coms.rooms": stored }),
      );

      expect(store.read()).toEqual([]);
    }
  });

  it("holds the same rule about ids that the form does", () => {
    // `AddRoomForm` requires a uuid; this path took any string at all. Two
    // paths disagreeing about one rule means the loose one is reachable — a
    // list written by an older build, or edited by hand in devtools — and it
    // ends up as a topic suffix the server can only answer with the same
    // refusal it gives an unknown room.
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
