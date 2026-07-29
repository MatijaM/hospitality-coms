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
 * ## Aborted rather than cancelled
 *
 * `AbortController` is not used and a request in flight is not stopped; the
 * effect's cleanup sets a flag and the answer is dropped. `session-context.tsx`
 * takes the same shape for `GET /api/me` and for the same reason: `FetchLike`
 * is the whole test seam, and threading a signal through it would make every
 * fake in the suite implement one.
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import type { ApiResult } from "../../api/client";
import type { RequestFailure } from "../../api/errors";
import { useSession } from "../../session/session-context";
import type { ShiftRoomListing, VenueRoomListing } from "./room";
import { fetchShiftRooms, fetchVenueRooms } from "./rooms-api";

export type Loaded<T> =
  /** No venue has been chosen, so nothing has been asked. */
  | { readonly status: "idle" }
  | { readonly status: "loading" }
  | { readonly status: "ready"; readonly value: T }
  | { readonly status: "failed"; readonly failure: RequestFailure };

export type RoomList<T> = {
  readonly state: Loaded<readonly T[]>;
  readonly reload: () => void;
};

const LOADING: Loaded<never> = { status: "loading" };
const IDLE: Loaded<never> = { status: "idle" };

type Ask<T> = () => Promise<ApiResult<readonly T[]>>;

/** An answer, stamped with the request it answers. */
type Outcome<T> = {
  readonly ask: Ask<T>;
  readonly attempt: number;
  readonly state: Loaded<readonly T[]>;
};

/**
 * Runs `ask` whenever it changes, and answers with the outcome. `null` is the
 * idle state and asks nothing.
 *
 * `ask` is a `useMemo` from the caller, so this effect's dependency is the
 * caller's own memoisation — a caller that rebuilt it on every render would
 * re-ask on every render, which is why both hooks below build theirs from
 * primitives.
 *
 * ## `idle` and `loading` are derived, not stored
 *
 * `use-room.ts`'s rule, for its reason: "storing it would need a write from the
 * effect body to get in and another to get out", and a synchronous `setState`
 * in an effect body is a cascading render the linter refuses. So the **only**
 * write here happens in the promise's callback, and it carries the request it
 * answers. Anything else is derived: no `ask` is idle, and an outcome that does
 * not match the current request is a request still in flight.
 *
 * That also makes a stale answer unrenderable rather than merely discarded —
 * the `abandoned` flag stops a torn-down effect writing, and the stamp stops an
 * answer that got through being shown for a request nobody made.
 */
function useFetched<T>(ask: Ask<T> | null): RoomList<T> {
  const [outcome, setOutcome] = useState<Outcome<T> | null>(null);
  const [attempt, setAttempt] = useState(0);

  const reload = useCallback(() => {
    setAttempt((previous) => previous + 1);
  }, []);

  useEffect(() => {
    if (ask === null) return;

    let abandoned = false;

    void ask().then((result) => {
      if (abandoned) return;

      setOutcome({
        ask,
        attempt,
        state: result.ok
          ? { status: "ready", value: result.value }
          : { status: "failed", failure: result.failure },
      });
    });

    return () => {
      abandoned = true;
    };
  }, [ask, attempt]);

  return { state: settled(ask, attempt, outcome), reload };
}

function settled<T>(
  ask: Ask<T> | null,
  attempt: number,
  outcome: Outcome<T> | null,
): Loaded<readonly T[]> {
  if (ask === null) return IDLE;
  if (outcome === null) return LOADING;
  if (outcome.ask !== ask || outcome.attempt !== attempt) return LOADING;

  return outcome.state;
}

/** The venue rooms this session is in. */
export function useVenueRooms(): RoomList<VenueRoomListing> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<VenueRoomListing> | null>(
    () => (token === null ? null : () => fetchVenueRooms(api, token)),
    [api, token],
  );

  return useFetched(ask);
}

/** The shift rooms this session may read at `venueId`, or nothing if none is chosen. */
export function useShiftRooms(venueId: string | null): RoomList<ShiftRoomListing> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<ShiftRoomListing> | null>(
    () =>
      token === null || venueId === null
        ? null
        : () => fetchShiftRooms(api, token, venueId),
    [api, token, venueId],
  );

  return useFetched(ask);
}
