/**
 * The worker's own list of rooms, and what this client has learned about each.
 *
 * ## Why the list is local
 *
 * There is no endpoint that lists rooms and no channel event that enumerates
 * them; `room.ts` traces that through the router and both channels. So the list
 * is a bookmark file, held in this browser, and it is an **input** to every
 * join rather than a record of any authority. Nothing in it is believed: a room
 * in the list that this session may not read is refused at `join/3` like any
 * other, and a room removed from it is not thereby left — the removal follows
 * the leave, never the other way round.
 *
 * ## Why `barred` is stored, and why there is a way to clear it
 *
 * A shift room past its `closes_at` still **joins** and still reads: U6 keeps
 * readability and membership as separate questions, and KTD6b says no write
 * withdraws access a period already earned. The only thing that changes is that
 * a send is refused. Nothing on the wire says so in advance — `join/3` replies
 * with the room and the engagement and no window, and the shift-room list's
 * `closesAt` is an instant on the *server's* clock, which is offsettable and
 * which this browser must not compare against its own (see `room.ts`) — so the
 * **client learns a room is closed by being told, once, and remembers**. Otherwise the closed state is
 * something the worker has to rediscover by losing a message they typed, on
 * every reload.
 *
 * Remembering it is a guess about the future, and the guess can be wrong in
 * both directions: an employer can move a `closes_at`, and a manager can put
 * somebody back on a roster. So the surface offers an explicit way to clear the
 * bar and try again rather than trapping the worker in a state this client
 * inferred. That is the honest shape for a fact that was learned rather than
 * fetched.
 *
 * ## It is emptied when the session ends, and it is not keyed per person
 *
 * Hospitality is a shared-terminal industry. The list is bookmarks rather than
 * content and a re-join is refused server-side, but it still names **which
 * venues and shifts that person worked**, which is the class of thing this
 * product exists to keep from leaking sideways. So `SessionProvider` clears it
 * wherever it drops the token — the explicit log-out and the 401 alike.
 *
 * Keying it per person instead — `hospitality-coms.rooms.<personId>` — was
 * considered and **rejected**. It would let two people share a terminal without
 * overwriting each other's lists, which is a convenience, but it does so by
 * *retaining* the previous worker's list on the device, which is the exact
 * thing clearing it is for. It would move the disclosure out of the surface
 * and leave it in storage, where anything that can run script on this origin
 * still reads it. A shared terminal wants less on disk, not more of it filed
 * by owner.
 *
 * ## The storage contract
 *
 * `read`, `write` and `clear` must not throw, exactly as `TokenStore`'s do not
 * and for the same reason: private-mode Safari throws on write, storage
 * switched off throws on everything, and a runtime with no web storage at all
 * leaves `window.localStorage` `undefined`. A store that throws would take the
 * room list down with a blank page.
 *
 * A stored value that is not the shape this module writes is **discarded, not
 * repaired**. It is a bookmark list; losing it costs a paste, and half-reading
 * it would put a room reference with no kind on a socket.
 */

import { isRecord } from "../../api/decode";
import type { RoomEntry, RoomKind, RoomRef, SendBar } from "./room";
import { normaliseRoomId, roomKey, sameRoom } from "./room";

export type RoomStore = {
  read(): readonly RoomEntry[];
  write(entries: readonly RoomEntry[]): void;
  /**
   * Forgets everything this device remembers about the person who was signed
   * in. Called when a session ends — see `SessionProvider`.
   */
  clear(): void;
};

export const ROOM_LIST_KEY = "hospitality-coms.rooms";

const ROOM_KINDS: readonly RoomKind[] = ["venue", "shift"];
const SEND_BARS: readonly SendBar[] = ["room_closed", "not_rostered"];

function decodeEntry(value: unknown): RoomEntry | null {
  if (!isRecord(value)) return null;
  if (typeof value.id !== "string") return null;

  const kind = ROOM_KINDS.find((candidate) => candidate === value.kind);
  if (kind === undefined) return null;

  // The same rule `AddRoomForm` applies, through the same function. These two
  // paths used to disagree — the form required a uuid and this took any string
  // at all — so a list from an older build, or one edited by hand in devtools,
  // took the loose path and put whatever it held on a socket.
  const id = normaliseRoomId(value.id);
  if (id === null) return null;

  if (value.barred === null || value.barred === undefined) {
    return { ref: { kind, id }, barred: null };
  }

  const barred = SEND_BARS.find((candidate) => candidate === value.barred);
  if (barred === undefined) return null;

  return { ref: { kind, id }, barred };
}

export function decodeRoomEntries(value: unknown): readonly RoomEntry[] | null {
  if (!Array.isArray(value)) return null;

  const entries: RoomEntry[] = [];

  for (const candidate of value) {
    const entry = decodeEntry(candidate);
    if (entry === null) return null;
    entries.push(entry);
  }

  return entries;
}

function encodeEntries(entries: readonly RoomEntry[]): string {
  return JSON.stringify(
    entries.map((entry) => ({
      kind: entry.ref.kind,
      id: entry.ref.id,
      barred: entry.barred,
    })),
  );
}

export function createLocalStorageRoomStore(
  storage: Storage,
  key: string = ROOM_LIST_KEY,
): RoomStore {
  return {
    read: () => {
      try {
        const raw = storage.getItem(key);
        if (raw === null) return [];

        return decodeRoomEntries(JSON.parse(raw)) ?? [];
      } catch {
        // Unreadable storage and unparseable JSON are the same answer: this
        // browser has no bookmarks, which is where every browser starts.
        return [];
      }
    },
    write: (entries) => {
      try {
        storage.setItem(key, encodeEntries(entries));
      } catch {
        // The list lives for this page load only. Documented above.
      }
    },
    clear: () => {
      try {
        storage.removeItem(key);
      } catch {
        // Nothing was persisted, so there is nothing to remove.
      }
    },
  };
}

/** Storage if the browser has it, memory if it does not. See `TokenStore`. */
export function createBrowserRoomStore(): RoomStore {
  try {
    const storage = globalThis.localStorage;
    // Use it rather than test for it, exactly as `createBrowserTokenStore`
    // does: absent it is a TypeError, blocked it is a SecurityError, and both
    // are caught here rather than at module scope in `main.tsx`.
    storage.getItem(ROOM_LIST_KEY);

    return createLocalStorageRoomStore(storage);
  } catch {
    return createMemoryRoomStore();
  }
}

export function createMemoryRoomStore(initial: readonly RoomEntry[] = []): RoomStore {
  let entries = initial;

  return {
    read: () => entries,
    write: (next) => {
      entries = next;
    },
    clear: () => {
      entries = [];
    },
  };
}

/**
 * Adds a room, or leaves the list alone if it is already there.
 *
 * Adding an existing room must not reset what has been learned about it: the
 * bar is the only thing in the list that came from the server, and a paste of
 * an id already present is not new information about it.
 */
export function addRoom(
  entries: readonly RoomEntry[],
  ref: RoomRef,
): readonly RoomEntry[] {
  if (entries.some((entry) => sameRoom(entry.ref, ref))) return entries;

  return [...entries, { ref, barred: null }];
}

export function removeRoom(
  entries: readonly RoomEntry[],
  ref: RoomRef,
): readonly RoomEntry[] {
  return entries.filter((entry) => !sameRoom(entry.ref, ref));
}

export function setRoomBar(
  entries: readonly RoomEntry[],
  ref: RoomRef,
  barred: SendBar | null,
): readonly RoomEntry[] {
  return entries.map((entry) =>
    sameRoom(entry.ref, ref) ? { ref: entry.ref, barred } : entry,
  );
}

export function findRoom(entries: readonly RoomEntry[], key: string): RoomEntry | null {
  return entries.find((entry) => roomKey(entry.ref) === key) ?? null;
}
