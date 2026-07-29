/**
 * The venue's shift types, its shift rooms, and the form that creates one.
 *
 * ## The bound is the server's and this side asks with a word
 *
 * `Rooms.recent_shift_room_limit/0` is 30 and lives in the context. There is no
 * `limit` on the wire and this hook must never grow one, for
 * `use-room-history.ts`'s reason: a caller that could pass a number would put
 * the unbounded read one forgetful caller away, which is what both of `Rooms`'
 * history functions were before U12.
 *
 * So the extent is a word — `"recent"` on mount, `"all"` once `loadAll` is
 * called — and the reply's `complete` is what says whether the second is worth
 * offering. `room-view.tsx` states the rule the surface follows: a control
 * offered unconditionally tells somebody whose venue holds three shifts that
 * there are more.
 *
 * ## Nothing here sorts, and that is not laziness
 *
 * `Records.most_recent_rooms/2` scans descending on `starts_at` with a
 * `limit + 1` probe and re-orders ascending in SQL around it, precisely so the
 * bounded page contains the shift a manager created a minute ago. A client-side
 * sort would satisfy every count assertion while hiding exactly the defect that
 * split exists to prevent.
 *
 * ## Nothing is cached
 *
 * R16 from this side, as `use-employer-venue.ts` has it: the server resolves the
 * acting grant on every request and this side keeps no list past the component
 * holding it. The shift list is re-read after a create rather than being
 * appended to — the server decides which rooms are in the page, and appending
 * would put a room in a page the bound may not have included.
 */

import { useCallback, useMemo, useState } from "react";

import type { RequestFailure } from "../../api/errors";
import type { ListExtent } from "../../api/types";
import type { Ask, Fetched, Loaded } from "../../app/use-fetched";
import { useFetched } from "../../app/use-fetched";
import { useSession } from "../../session/session-context";
import type { ShiftRoomPage, ShiftType } from "./employer";
import { createShiftRoom, fetchShiftRooms, fetchShiftTypes } from "./employer-api";

/** The kinds of shift this venue runs. */
export function useShiftTypes(venueId: string): Fetched<readonly ShiftType[]> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<readonly ShiftType[]> | null>(
    () => (token === null ? null : () => fetchShiftTypes(api, token, venueId)),
    [api, token, venueId],
  );

  return useFetched(ask);
}

export type ShiftRooms = {
  readonly state: Loaded<ShiftRoomPage>;
  /** Which extent produced `state`, so the control knows what it already asked. */
  readonly extent: ListExtent;
  /** Asks again for every shift. Idempotent; a no-op once it has. */
  readonly loadAll: () => void;
  readonly reload: () => void;
};

/** The venue's shift rooms, bounded until `loadAll` is called. */
export function useShiftRooms(venueId: string): ShiftRooms {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;
  const [extent, setExtent] = useState<ListExtent>("recent");

  const ask = useMemo<Ask<ShiftRoomPage> | null>(
    () => (token === null ? null : () => fetchShiftRooms(api, token, venueId, extent)),
    [api, token, venueId, extent],
  );

  const fetched = useFetched(ask);

  const loadAll = useCallback(() => {
    setExtent("all");
  }, []);

  return { state: fetched.state, extent, loadAll, reload: fetched.reload };
}

export type ShiftDesk = {
  readonly problem: RequestFailure | null;
  /** True while an answer is outstanding. The form is closed on it. */
  readonly creating: boolean;
  /**
   * Answers whether the server accepted it.
   *
   * The caller needs that and cannot derive it: `problem` is state this hook
   * sets *after* the promise settles, so a form reading it back would be
   * reading the previous render's answer. It is a boolean rather than the
   * failure because the failure is already on `problem`, rendered by the same
   * component — two ways to reach one refusal is the divergence this tree keeps
   * finding.
   */
  readonly create: (shift: {
    readonly shiftTypeId: string;
    readonly startsAt: string;
    readonly endsAt: string;
  }) => Promise<boolean>;
};

/**
 * Creating one shift at one venue.
 *
 * **The `creating` guard is deliberately behind the button's `disabled`**, which
 * is `useOfferDesk`'s arrangement and is measured there: removing this alone
 * kills no test, because a disabled submit cannot be clicked a second time. It
 * is kept because the two answer different questions — the attribute is what a
 * manager sees, this is what the hook promises a caller — and because the cost
 * of the race is two shift rooms at overlapping times, which nothing
 * deduplicates and which the manager then has to un-create by hand.
 *
 * `onCreated` re-reads the list rather than this hook appending to it: the
 * server decides which rooms are in the bounded page, and a client that
 * appended would show a room in a page the bound did not include.
 *
 * **The in-flight guard is not what stops a duplicate; clearing the form is.**
 * `creating` covers two clicks landing on one outstanding request and nothing
 * else — once the answer is back it is `false` again, and the values a manager
 * typed are still in the three inputs. `ShiftForm` therefore empties them on
 * the success branch alone, off this function's answer. That guard cannot be
 * dropped in favour of a server-side one, because **there is none**: two shift
 * rooms of one type over one term are legitimately creatable, so nothing
 * downstream refuses the second, and the manager's remedy for one created by
 * accident is to notice it in the list below and un-create it by hand.
 */
export function useShiftDesk(venueId: string, onCreated: () => void): ShiftDesk {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const [problem, setProblem] = useState<RequestFailure | null>(null);
  const [creating, setCreating] = useState(false);

  const create = useCallback(
    async (shift: {
      readonly shiftTypeId: string;
      readonly startsAt: string;
      readonly endsAt: string;
    }) => {
      if (token === null || creating) return false;

      setCreating(true);
      setProblem(null);

      const result = await createShiftRoom(api, token, venueId, shift);

      setCreating(false);

      if (result.ok) onCreated();
      else setProblem(result.failure);

      return result.ok;
    },
    [api, token, venueId, creating, onCreated],
  );

  return { problem, creating, create };
}
