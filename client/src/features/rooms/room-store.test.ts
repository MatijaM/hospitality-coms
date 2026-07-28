import { describe, expect, it } from "vitest";

import type { RoomEntry, RoomRef } from "./room";
import {
  addRoom,
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

  it("reads a missing `barred` as no bar, so an older list still loads", () => {
    expect(
      decodeRoomEntries([{ kind: "venue", id: "11111111-1111-4111-8111-111111111111" }]),
    ).toEqual([entry(VENUE)]);
  });
});
