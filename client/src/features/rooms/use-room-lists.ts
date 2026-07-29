/**
 * The two lists a worker needs before a room channel is any use to them.
 *
 * ## Fetched, not remembered
 *
 * Neither list is written to the room store. The store holds the worker's own
 * bookmarks and the one fact this client *learned* rather than fetched
 * (`barred`); these two are the server's answer at the request's instant, and
 * caching them would be caching an authorisation — a venue room leaves the list
 * the moment an engagement ends or the person suspends it, and a stale copy on
 * this device would offer a room the next join refuses.
 *
 * So they are asked for again on mount, and `reload` is offered rather than
 * assumed: nothing here polls, and nothing re-asks on its own.
 *
 * ## The shift-room list is per venue, and `null` is a state
 *
 * `useShiftRooms(null)` is "no venue chosen", which is not the same as "chosen,
 * and it has no rooms". Collapsing them would make an unopened panel and an
 * empty one render identically, and the empty one is the answer a person gets
 * at a venue they have never been rostered at — which is worth a sentence.
 *
 * ## The machinery underneath is `src/app/use-fetched.ts`
 *
 * It was written here and moved when the employer surface became its second
 * caller — unchanged, except that it now takes any answer rather than only a
 * list. `Loaded` is re-exported because `rooms-route.tsx` names it and it is
 * the same type; there is still exactly one spelling of it.
 */

import { useMemo } from "react";

import type { Ask, Loaded } from "../../app/use-fetched";
import { useFetched } from "../../app/use-fetched";
import { useSession } from "../../session/session-context";
import type { ShiftRoomListing, VenueRoomListing } from "./room";
import { fetchShiftRooms, fetchVenueRooms } from "./rooms-api";

export type { Loaded };

export type RoomList<T> = {
  readonly state: Loaded<readonly T[]>;
  readonly reload: () => void;
};

/** The venue rooms this session is in. */
export function useVenueRooms(): RoomList<VenueRoomListing> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<readonly VenueRoomListing[]> | null>(
    () => (token === null ? null : () => fetchVenueRooms(api, token)),
    [api, token],
  );

  return useFetched(ask);
}

/** The shift rooms this session may read at `venueId`, or nothing if none is chosen. */
export function useShiftRooms(venueId: string | null): RoomList<ShiftRoomListing> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<readonly ShiftRoomListing[]> | null>(
    () =>
      token === null || venueId === null
        ? null
        : () => fetchShiftRooms(api, token, venueId),
    [api, token, venueId],
  );

  return useFetched(ask);
}
