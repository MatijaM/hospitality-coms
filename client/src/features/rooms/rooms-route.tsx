/**
 * The rooms surface: what the server says this worker can reach, what this
 * browser remembers, and the one room that is open.
 *
 * ## Two lists, and they are not the same list
 *
 * **Rooms you are in** is the server's answer at this instant —
 * `GET /api/venue-rooms`, and `GET /api/venues/:venue_id/shift-rooms` once a
 * venue is chosen. It is where a room is *found*: venue rooms carry the venue's
 * name and shift rooms carry the shift type's, so nothing in it is a uuid
 * prefix. Before U12 there was no such endpoint at all, and a room could only
 * be reached by typing its id into the box the section below records.
 *
 * **Recently opened chats** is this browser's own, newest first. It is kept,
 * and it is not a stale copy of the first: it holds `barred`, the one thing on
 * this surface that was *learned* rather than fetched — nothing on the wire
 * says in advance that a shift room is past its `closes_at` — and it is what
 * survives a reload. Both lists open a room through `openAndKeep`, so a room
 * reached from either takes the same path into a channel and lands in this one.
 *
 * ## There is no paste box, and the argument that kept one was checkable
 *
 * There was a third control: a **Kind** select, an **Id** text box and an "Add
 * this room" button, and this header used to defend it — *"it is the only way
 * into a room the browse list does not show"*. That is a claim about the two
 * reads above rather than a matter of taste, and it does not survive being
 * checked (#80). `Rooms.list_venue_rooms/1` and `list_readable_shift_rooms/2`
 * carry **no limit and no extent** — unlike the message reads on the same four
 * routes, and unlike the employer's `list_shift_rooms/1`, which is bounded at
 * 30 — so there is no page for a box to be a way past. And a readable shift
 * room needs an engagement active *now* at that venue, which is the venue
 * room's own roll, so a venue holding one is always in the first list.
 *
 * Deleted rather than hidden, which is `profile-route.tsx`'s rule from #73: a
 * component still mounted still leaves a focusable uuid box in the
 * accessibility tree that a screen reader finds and a sighted worker does not.
 *
 * **One gap is real, and it is an obligation on a control that does not exist
 * yet.** `Browse` nests a venue's shift rooms under its *venue room*, and the
 * server route deliberately does not — `GET /api/venues/:venue_id/shift-rooms`
 * hangs off the venue, and `RoomController`'s moduledoc says a path under the
 * venue room "would invite a membership gate in front of it, and that gate
 * would quietly extend suspension to shift rooms" (KTD18). This panel
 * reintroduces at the render layer the coupling that route refused: a worker
 * suspended from a venue room loses its row, and with it the way to expand
 * shift rooms they are still rostered on. Nothing in the tree can put them
 * there — `Rooms.suspend_venue_room/2` has no caller outside the test suite,
 * no route and no channel event — so whoever builds the opt-out builds the way
 * to those rooms with it. A uuid box shipped against a state nothing can
 * produce is not that way.
 *
 * ## One control per row, and what that cost
 *
 * The row was `[Open <uuid>] [Forget <uuid>]`. It is one button now and it
 * carries the room's **name**, which is the whole of what was reported. Two
 * consequences, neither cosmetic:
 *
 *   * With no "Forget" there is nothing that shrinks the list, so the store
 *     bounds it and evicts the oldest — `RECENT_ROOM_LIMIT` in `room-store.ts`
 *     carries the number and the reasoning. Nothing here may pass one.
 *   * "Recently opened" is a claim about order, so opening a room reorders this
 *     list. Both entry points therefore go through `openAndKeep` rather than
 *     only the browse one, which is why `RoomList` hands back a `RoomRef` where
 *     it used to hand back a key.
 *
 * Both entry points are now the browse list and this one, and every id either
 * hands over came from the server or from the store's own decoder — which is
 * why `normaliseRoomId` moved from being one of two agreeing checks to being
 * the only one. `room-store.ts` says so where it calls it.
 *
 * ## Where a row's name comes from, and why the lists are fetched up here
 *
 * A row prefers the **live** name — the browse list's answer at this instant,
 * so a renamed venue corrects itself — then the one stored when it was last
 * opened, then `roomFallbackLabel`. `roomLabel` is that order and the reasoning.
 *
 * The stored name is not a cache of the live one and cannot be dropped: a
 * venue room's name arrives with the venue-room list and is therefore always
 * available, but a **shift** room's arrives only for the venue currently
 * expanded, so a bookmarked shift room met after a reload has no live name at
 * all. That is why `useVenueRooms` and `useShiftRooms` are called here rather
 * than inside `Browse`, where they used to be: two lists on this screen need
 * their answers and only one of them is `Browse`.
 *
 * **Three now, and the third is the open room's own header** (#73). It rendered
 * `<code>{ref.id}</code>` under a heading that was the kind, which was the last
 * uuid on this surface and the biggest — over the conversation rather than in a
 * list. `RoomView` takes the live name as a prop and calls the same `roomLabel`
 * the rows do; nothing in that component fetches a list or re-decides the
 * order.
 *
 * ## One room is joined at a time, on purpose
 *
 * `max_channels_per_transport` is at Phoenix's default of 100, and
 * `endpoint.ex` records that KTD10's argument for that number is wrong — a
 * person's readable shift-room set is unbounded and grows with every shift ever
 * rostered, so "clients must open shift rooms on demand rather than joining the
 * list". A list that joined every room in order to render it would be exactly
 * what that note warns against, and the browse list makes that easier to get
 * wrong rather than harder: it now *has* every room in it.
 *
 * The consequence is stated rather than hidden: a revocation is noticed while
 * the room is open, and on the next join otherwise — which is where KTD8 puts
 * the enforcement anyway.
 *
 * ## Removal follows the leave
 *
 * `RoomView` leaves the topic and *then* calls back here, so this component
 * never drops a room that is still subscribed. The order matters: dropping the
 * entry first would unmount the view, and the leave would happen in a cleanup
 * racing whatever else the unmount triggered.
 *
 * A **revocation** removes the room. A **suspension** does not: the person did
 * it, possibly from another device, and they can undo it — so the bookmark
 * stays and the next attempt to open it meets the refusal
 * `fetch_venue_room_membership/2` gives a suspended member, which is the truth
 * from the server rather than a state this client remembered.
 *
 * ## Why the browse panel's status line is not `role="status"`
 *
 * It is `aria-live="polite"`, which announces the same way without claiming the
 * `status` role. This screen already has exactly one thing whose state a worker
 * is waiting on — the open room — and two competing status regions make the
 * important one harder to find rather than the secondary one easier.
 */

import { useCallback, useMemo, useState } from "react";

import type {
  RoomClosure,
  RoomEntry,
  RoomRef,
  SendBar,
  ShiftRoomListing,
  VenueRoomListing,
} from "./room";
import { instantLabel, roomKey, roomLabel, shiftRoomLabel } from "./room";
import type { RoomStore } from "./room-store";
import { findRoom, recordOpening, removeRoom, setRoomBar } from "./room-store";
import { RoomView } from "./room-view";
import { readFailureMessage } from "./refusal-message";
// `RoomList` is this file's own component, so the hook's type of that name
// comes in under the one it is: a fetched list plus its `reload`.
import type { Loaded, RoomList as FetchedList } from "./use-room-lists";
import { useShiftRooms, useVenueRooms } from "./use-room-lists";

export type RoomsRouteProps = {
  readonly store: RoomStore;
};

export function RoomsRoute({ store }: RoomsRouteProps) {
  const [entries, setEntries] = useState<readonly RoomEntry[]>(() => store.read());
  const [openKey, setOpenKey] = useState<string | null>(null);

  // The browse lists, and the venue whose shift rooms are showing. Both live
  // here rather than in `Browse` because the recently-opened list needs their
  // names too — see this file's header.
  const [chosen, setChosen] = useState<string | null>(null);
  const venueRooms = useVenueRooms();
  const shiftRooms = useShiftRooms(chosen);

  const liveNames = useMemo(
    () => currentNames(venueRooms.state, shiftRooms.state),
    [venueRooms.state, shiftRooms.state],
  );

  // Counts opens rather than naming a room, and it is part of `RoomView`'s
  // `key`. Without it, opening the room already open set `openKey` to the value
  // it already had, React kept the mount, and nothing re-joined — so every
  // "open it again to check" correction this surface offers was a dead end,
  // including the one after a refused join and the one after a send refused
  // `unauthorized`. It is also what re-fetches a room's history.
  const [openAttempt, setOpenAttempt] = useState(0);

  const openRoom = useCallback((key: string) => {
    setOpenKey(key);
    setOpenAttempt((previous) => previous + 1);
  }, []);

  // Every mutation goes through one function, in the functional form, because
  // several of them are called from channel callbacks that fire long after the
  // render that registered them.
  const update = useCallback(
    (change: (current: readonly RoomEntry[]) => readonly RoomEntry[]) => {
      setEntries((current) => {
        const next = change(current);

        // `recordOpening` answers the identical array when re-opening the room
        // already at the front changes nothing about the list, and every open
        // now goes through it. Writing regardless would be a `localStorage`
        // write on every click and a store callback with nothing in it.
        if (next === current) return current;

        store.write(next);

        return next;
      });
    },
    [store],
  );

  const closeIfOpen = useCallback((ref: RoomRef) => {
    setOpenKey((current) => (current === roomKey(ref) ? null : current));
  }, []);

  // Bookmarking and opening are one action, so a room found in the browse list
  // is in the local list from the moment it is first opened — which is what
  // makes `barred` and the reload survival apply to it too. **Every** open goes
  // through here, the recently-opened list's own included, because opening is
  // what that list orders itself by.
  //
  // The name is taken at this instant and stored, which is the only chance:
  // a shift room's is on screen while its venue is expanded and nowhere at all
  // afterwards. `null` when there is none, which leaves whatever was stored.
  const openAndKeep = useCallback(
    (ref: RoomRef) => {
      const name = liveNames.get(roomKey(ref)) ?? null;

      update((current) => recordOpening(current, ref, name));
      openRoom(roomKey(ref));
    },
    [update, openRoom, liveNames],
  );

  const onEnded = useCallback(
    (entry: RoomEntry, closure: RoomClosure) => {
      switch (closure.reason) {
        case "revoked":
          update((current) => removeRoom(current, entry.ref));
          closeIfOpen(entry.ref);

          return;
        case "suspended":
          // Kept, and left open so the notice can be read. Re-opening it later
          // asks the server, which refuses a suspended member's join.
          return;
      }
    },
    [update, closeIfOpen],
  );

  const open = openKey === null ? null : findRoom(entries, openKey);

  return (
    <section>
      <h1>Rooms</h1>

      <Browse
        venueRooms={venueRooms}
        shiftRooms={shiftRooms.state}
        chosen={chosen}
        onChoose={setChosen}
        onOpen={openAndKeep}
      />

      <h2>Recently opened chats</h2>
      <p>
        This list lives in this browser, newest first. It is a shortcut back — everything
        you can reach is in the list above.
      </p>

      <RoomList
        entries={entries}
        openKey={openKey}
        liveNames={liveNames}
        onOpen={openAndKeep}
      />

      {open !== null && (
        <RoomView
          key={`${roomKey(open.ref)}#${openAttempt.toString()}`}
          entry={open}
          liveName={liveNames.get(roomKey(open.ref)) ?? null}
          onEnded={onEnded}
          onBarred={(entry, bar: SendBar) => {
            update((current) => setRoomBar(current, entry.ref, bar));
          }}
          onClearBar={(entry) => {
            update((current) => setRoomBar(current, entry.ref, null));
          }}
        />
      )}
    </section>
  );
}

/**
 * Every name this client currently has from the server, keyed the way the
 * stored list is keyed.
 *
 * Venue rooms are always in it once that list has loaded; shift rooms are in it
 * only for the venue expanded right now, which is exactly why the store keeps a
 * copy. A shift room is named the way the browse list names it, through
 * `shiftRoomLabel`, so one room does not read two ways on one screen.
 */
function currentNames(
  venueRooms: Loaded<readonly VenueRoomListing[]>,
  shiftRooms: Loaded<readonly ShiftRoomListing[]>,
): ReadonlyMap<string, string> {
  const names = new Map<string, string>();

  if (venueRooms.status === "ready") {
    for (const room of venueRooms.value) {
      names.set(roomKey({ kind: "venue", id: room.venueId }), room.name);
    }
  }

  if (shiftRooms.status === "ready") {
    for (const room of shiftRooms.value) {
      names.set(roomKey({ kind: "shift", id: room.shiftRoomId }), shiftRoomLabel(room));
    }
  }

  return names;
}

/**
 * The server's list: the venue rooms this person is in, and one venue's shift
 * rooms at a time.
 *
 * One venue expanded at a time, because a shift-room list is a request per
 * venue and expanding all of them on arrival would be a request per venue on
 * arrival. Choosing is the asking.
 *
 * Both answers and the chosen venue are the route's state rather than this
 * component's, because the recently-opened list needs the names too. Nothing
 * else about the panel moved.
 */
function Browse({
  venueRooms,
  shiftRooms,
  chosen,
  onChoose,
  onOpen,
}: {
  readonly venueRooms: FetchedList<VenueRoomListing>;
  readonly shiftRooms: Loaded<readonly ShiftRoomListing[]>;
  readonly chosen: string | null;
  readonly onChoose: (venueId: string | null) => void;
  readonly onOpen: (ref: RoomRef) => void;
}) {
  return (
    <section aria-label="Rooms you are in">
      <h2>Rooms you are in</h2>

      <ListState
        state={venueRooms.state}
        onRetry={venueRooms.reload}
        empty="You are not in any venue rooms. A venue room appears here while an engagement at that venue is active."
      />

      {venueRooms.state.status === "ready" && venueRooms.state.value.length > 0 && (
        <ul aria-label="Venue rooms">
          {venueRooms.state.value.map((room) => (
            <VenueRoomItem
              key={room.venueId}
              room={room}
              chosen={chosen === room.venueId}
              shiftRooms={shiftRooms}
              onOpen={onOpen}
              onChoose={() => {
                onChoose(chosen === room.venueId ? null : room.venueId);
              }}
            />
          ))}
        </ul>
      )}
    </section>
  );
}

function VenueRoomItem({
  room,
  chosen,
  shiftRooms,
  onOpen,
  onChoose,
}: {
  readonly room: VenueRoomListing;
  readonly chosen: boolean;
  readonly shiftRooms: Loaded<readonly ShiftRoomListing[]>;
  readonly onOpen: (ref: RoomRef) => void;
  readonly onChoose: () => void;
}) {
  return (
    <li>
      <strong>{room.name}</strong>
      <button
        type="button"
        onClick={() => {
          onOpen({ kind: "venue", id: room.venueId });
        }}
      >
        Open {room.name}
      </button>
      <button type="button" aria-expanded={chosen} onClick={onChoose}>
        Shift rooms at {room.name}
      </button>

      {chosen && (
        <>
          <ListState
            state={shiftRooms}
            empty="No shift rooms here. A shift room appears once you have been on its roster."
          />
          {shiftRooms.status === "ready" && shiftRooms.value.length > 0 && (
            <ul aria-label={`Shift rooms at ${room.name}`}>
              {shiftRooms.value.map((shift) => (
                <li key={shift.shiftRoomId}>
                  <button
                    type="button"
                    onClick={() => {
                      onOpen({ kind: "shift", id: shift.shiftRoomId });
                    }}
                  >
                    Open {shiftRoomLabel(shift)}
                  </button>
                  {/*
                    The attribute keeps the instant a machine can read and the
                    text is for the person, which is what `<time>` is for. Not
                    comparing `closes_at` against this browser's clock is the
                    rule (see `ShiftRoomListing`); not *formatting* it never
                    was, and rendering it raw put `2026-03-09T21:30:00Z` on
                    screen next to a term this client had already formatted.
                  */}
                  <time dateTime={shift.closesAt}>
                    closes {instantLabel(shift.closesAt)}
                  </time>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </li>
  );
}

/**
 * The three non-list states a fetched list has, and nothing when it has rows.
 *
 * `aria-live` without `role="status"` — see this file's header.
 */
function ListState<T>({
  state,
  empty,
  onRetry,
}: {
  readonly state: Loaded<readonly T[]>;
  readonly empty: string;
  readonly onRetry?: () => void;
}) {
  switch (state.status) {
    case "idle":
      return null;
    case "loading":
      return <p aria-live="polite">Loading…</p>;
    case "failed":
      return (
        <div>
          <p aria-live="polite">{readFailureMessage(state.failure)}</p>
          {onRetry !== undefined && (
            <button type="button" onClick={onRetry}>
              Try again
            </button>
          )}
        </div>
      );
    case "ready":
      return state.value.length === 0 ? <p aria-live="polite">{empty}</p> : null;
  }
}

/**
 * The recently-opened list: one row per room, one control on it, named.
 *
 * **The empty-state sentence is load-bearing beyond this file.**
 * `app/app.test.tsx` names the rooms panel by it — it is the one sentence only
 * this surface renders — so moving it means moving that sentinel with it, and
 * the failure looks like the tab strip breaking rather than like copy changing.
 * It still says "rooms" rather than "chats" because every other string on this
 * screen does; the heading is the user's word and the vocabulary underneath it
 * did not change. It stopped offering "or add one by its id" when the box that
 * sentence pointed at went (#80), so the list above is now the whole of the
 * answer — which it already was.
 */
function RoomList({
  entries,
  openKey,
  liveNames,
  onOpen,
}: {
  readonly entries: readonly RoomEntry[];
  readonly openKey: string | null;
  readonly liveNames: ReadonlyMap<string, string>;
  readonly onOpen: (ref: RoomRef) => void;
}) {
  if (entries.length === 0) {
    return <p>No rooms yet. Open one from the list above.</p>;
  }

  return (
    <ul aria-label="Recently opened chats">
      {entries.map((entry) => (
        <li key={roomKey(entry.ref)}>
          <button
            type="button"
            aria-current={roomKey(entry.ref) === openKey}
            onClick={() => {
              onOpen(entry.ref);
            }}
          >
            Open {roomLabel(entry, liveNames.get(roomKey(entry.ref)) ?? null)}
          </button>
        </li>
      ))}
    </ul>
  );
}
