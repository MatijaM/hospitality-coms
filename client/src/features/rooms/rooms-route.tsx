/**
 * The rooms surface: the list, and the one room that is open.
 *
 * ## One room is joined at a time, on purpose
 *
 * `max_channels_per_transport` is at Phoenix's default of 100, and
 * `endpoint.ex` records that KTD10's argument for that number is wrong — a
 * person's readable shift-room set is unbounded and grows with every shift ever
 * rostered, so "clients must open shift rooms on demand rather than joining the
 * list". A list that joined every room in order to render it would be exactly
 * what that note warns against.
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
 */

import { useCallback, useState } from "react";

import type { RoomClosure, RoomEntry, RoomKind, RoomRef, SendBar } from "./room";
import { isRoomId, roomKey, roomKindLabel } from "./room";
import type { RoomStore } from "./room-store";
import { addRoom, findRoom, removeRoom, setRoomBar } from "./room-store";
import { RoomView } from "./room-view";

export type RoomsRouteProps = {
  readonly store: RoomStore;
};

export function RoomsRoute({ store }: RoomsRouteProps) {
  const [entries, setEntries] = useState<readonly RoomEntry[]>(() => store.read());
  const [openKey, setOpenKey] = useState<string | null>(null);

  // Every mutation goes through one function, in the functional form, because
  // several of them are called from channel callbacks that fire long after the
  // render that registered them.
  const update = useCallback(
    (change: (current: readonly RoomEntry[]) => readonly RoomEntry[]) => {
      setEntries((current) => {
        const next = change(current);
        store.write(next);

        return next;
      });
    },
    [store],
  );

  const closeIfOpen = useCallback((ref: RoomRef) => {
    setOpenKey((current) => (current === roomKey(ref) ? null : current));
  }, []);

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
      <p>
        This list lives in this browser. There is no endpoint that serves it — the API has
        four routes and none of them lists rooms — so a room is added by its id, and
        everything <em>about</em> a room still comes from the server on every join.
      </p>

      <AddRoomForm
        onAdd={(ref) => {
          update((current) => addRoom(current, ref));
          setOpenKey(roomKey(ref));
        }}
      />

      <RoomList
        entries={entries}
        openKey={openKey}
        onOpen={setOpenKey}
        onForget={(entry) => {
          update((current) => removeRoom(current, entry.ref));
          closeIfOpen(entry.ref);
        }}
      />

      {open !== null && (
        <RoomView
          key={roomKey(open.ref)}
          entry={open}
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

function RoomList({
  entries,
  openKey,
  onOpen,
  onForget,
}: {
  readonly entries: readonly RoomEntry[];
  readonly openKey: string | null;
  readonly onOpen: (key: string) => void;
  readonly onForget: (entry: RoomEntry) => void;
}) {
  if (entries.length === 0) {
    return <p>No rooms yet. Add one by its id.</p>;
  }

  return (
    <ul aria-label="Your rooms">
      {entries.map((entry) => (
        <li key={roomKey(entry.ref)}>
          <button
            type="button"
            aria-current={roomKey(entry.ref) === openKey}
            onClick={() => {
              onOpen(roomKey(entry.ref));
            }}
          >
            Open {roomKindLabel(entry.ref.kind).toLowerCase()} {entry.ref.id}
          </button>
          <button
            type="button"
            onClick={() => {
              onForget(entry);
            }}
          >
            Forget {entry.ref.id}
          </button>
        </li>
      ))}
    </ul>
  );
}

function AddRoomForm({ onAdd }: { readonly onAdd: (ref: RoomRef) => void }) {
  const [kind, setKind] = useState<RoomKind>("venue");
  const [id, setId] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        const trimmed = id.trim();

        // Checked here for the worker's benefit, not the server's: the server
        // answers a malformed suffix with exactly what it answers an unknown
        // room (AE1), so it can say nothing usable about somebody's own typo.
        if (!isRoomId(trimmed)) {
          setProblem("That is not an id. It should look like a uuid.");

          return;
        }

        setProblem(null);
        setId("");
        onAdd({ kind, id: trimmed });
      }}
    >
      <label htmlFor="room-kind">Kind</label>
      <select
        id="room-kind"
        name="room-kind"
        value={kind}
        onChange={(event) => {
          setKind(event.target.value === "shift" ? "shift" : "venue");
        }}
      >
        <option value="venue">Venue room (the venue&rsquo;s id)</option>
        <option value="shift">Shift room (the shift room&rsquo;s id)</option>
      </select>

      <label htmlFor="room-id">Id</label>
      <input
        id="room-id"
        name="room-id"
        type="text"
        value={id}
        onChange={(event) => {
          setId(event.target.value);
        }}
      />
      {problem !== null && <p role="alert">{problem}</p>}
      <button type="submit">Add this room</button>
    </form>
  );
}
