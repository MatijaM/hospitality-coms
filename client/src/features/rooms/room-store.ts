/**
 * The rooms this browser has opened most recently, and what this client has
 * learned about each.
 *
 * ## It is a recency list now, and the two halves of that arrived together
 *
 * It was a hand-curated set: a room was added by opening it and removed with a
 * "Forget" control beside every row. The control went because a list of chats
 * wants one action per row and the second one was noise on a surface a worker
 * reads mid-shift — and removing the only way to shrink the list is what makes
 * `RECENT_ROOM_LIMIT` mandatory rather than tidy. Nothing else evicts.
 *
 * With no curation left, order has to carry the claim the heading makes.
 * `recordOpening` puts the room just opened at the front, so position **is** the
 * recency; nothing stores an instant, which is deliberate — this browser's clock
 * and `HospitalityComs.Clock` are different clocks (see `room.ts`), and a
 * persisted local timestamp would be the one value here that could not be
 * checked against anything.
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
 *
 * **`name` is the one field that may be absent**, and that is a compatibility
 * rule rather than a softening of the one above: entries written before names
 * were stored carry no `name` key, and a decoder that required one would empty
 * every real browser's list on the deploy that added it. See `decodeName`.
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

/**
 * A stored bar, `null` for an entry that carries none, and `undefined` for a
 * value this module did not write — which discards the whole entry.
 */
function decodeBar(value: unknown): SendBar | null | undefined {
  if (value === null || value === undefined) return null;

  return SEND_BARS.find((candidate) => candidate === value);
}

/**
 * A stored name, on the same three-way contract as `decodeBar`.
 *
 * **A missing one is `null` rather than a discard**, and that is the whole of
 * what keeps a real browser's list alive across this change: every entry
 * written before names were stored has no `name` key, and requiring one would
 * empty everybody's list on the deploy that added it. A `name` that is present
 * and is not a string is still a discard — that is the module's "not repaired"
 * rule, and no build of this client ever wrote one.
 */
function decodeName(value: unknown): string | null | undefined {
  if (value === null || value === undefined) return null;

  return typeof value === "string" ? value : undefined;
}

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

  const barred = decodeBar(value.barred);
  if (barred === undefined) return null;

  const name = decodeName(value.name);
  if (name === undefined) return null;

  return { ref: { kind, id }, barred, name };
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
      name: entry.name,
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
 * How many rooms the list keeps.
 *
 * **The bound is only mandatory because there is no longer a way to remove an
 * entry.** While the list was curated by hand it could be as long as somebody
 * chose to make it; with every open adding a row and nothing taking one away it
 * would grow for as long as the session lasted, in `localStorage`, where the
 * cost is paid on every read by every page load.
 *
 * Twelve, and the reasoning is about what the list is *for* rather than about
 * storage. It is a shortcut back to a conversation, not a record of anything:
 * every room in it that still exists is also in "Rooms you are in" above, which
 * is the server's answer and is complete. So the number wants to be larger than
 * the rooms one worker touches across a couple of shifts — a venue room and a
 * shift room at each of two or three places is six to eight — and small enough
 * that the list is still scannable at a glance on a phone, which is where this
 * is read. Past a dozen rows, finding a room by scrolling this list is slower
 * than finding it in the one above.
 *
 * **It lives here and no caller may pass one**, which is the rule
 * `HospitalityComs.Rooms.recent_message_limit/0` and `recent_shift_room_limit/0`
 * hold on the server. As there, **no relationship to either of those numbers is
 * asserted** and none should be: they bound how much of a room's history one
 * request carries, and this bounds how many rooms one browser remembers.
 */
export const RECENT_ROOM_LIMIT = 12;

/**
 * Records that a room was just opened: newest first, once each, bounded.
 *
 * **Move to the front rather than append**, because "recently opened" is a
 * claim about order and the list is the only thing that can make it true —
 * nothing stores an instant, so position *is* the recency. Opening a room
 * already listed therefore reorders it rather than duplicating it, which is the
 * same call and the same guarantee the old `addRoom` gave by refusing to add
 * twice.
 *
 * **What was learned survives the reorder.** `barred` is the one thing in this
 * list that came from the server, and re-opening a room is not new information
 * about whether it takes messages. The name survives too when the caller has
 * none to offer: a room re-opened from this list while its venue is collapsed
 * passes `null`, and wiping the stored name there would put the uuid back on
 * screen at the exact moment the worker used the shortcut.
 *
 * It answers the **same array** when nothing about the list changed, so that
 * re-opening the room already at the front is not a `localStorage` write per
 * click. `RoomsRoute` leans on that identity — see `update` there.
 */
export function recordOpening(
  entries: readonly RoomEntry[],
  ref: RoomRef,
  name: string | null = null,
): readonly RoomEntry[] {
  const existing = entries.find((entry) => sameRoom(entry.ref, ref)) ?? null;
  const opened: RoomEntry = {
    ref,
    barred: existing?.barred ?? null,
    name: name ?? existing?.name ?? null,
  };

  if (existing !== null && entries[0] === existing && existing.name === opened.name) {
    return entries;
  }

  return [opened, ...entries.filter((entry) => !sameRoom(entry.ref, ref))].slice(
    0,
    RECENT_ROOM_LIMIT,
  );
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
    sameRoom(entry.ref, ref) ? { ...entry, barred } : entry,
  );
}

export function findRoom(entries: readonly RoomEntry[], key: string): RoomEntry | null {
  return entries.find((entry) => roomKey(entry.ref) === key) ?? null;
}
