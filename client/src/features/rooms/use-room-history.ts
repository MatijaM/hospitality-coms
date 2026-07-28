/**
 * What was said in a room before this session opened it.
 *
 * ## Bounded by the server, and this client does not know the number
 *
 * `HospitalityComs.Rooms.recent_message_limit/0` is the bound and it lives in
 * the context. There is no `limit` on the wire and this hook must never grow
 * one: a caller that could pass a number would put the unbounded read one
 * forgetful caller away, which is what both history functions were before U12.
 *
 * So the extent is a word. `"recent"` on mount, `"all"` once `loadAll` is
 * called, and the reply's `complete` is what says whether the second is worth
 * offering. A control offered unconditionally would tell somebody whose room
 * holds three messages that there are more.
 *
 * ## It is a fetch, not a subscription, and the join is separate
 *
 * `use-room.ts` joins the channel and collects what arrives afterwards. These
 * two overlap: a message sent between the fetch and the join arrives on both
 * paths, so `mergeMessages` keys on the id. Neither hook waits for the other,
 * because a history that waited for a join would show nothing at all in a room
 * whose join was refused — and a refused join is exactly when a worker wants to
 * know what they are missing... which, in this design, they do not get: the
 * history route re-derives the same authorisation the join does and answers the
 * same `404`. That symmetry is deliberate and it is the server's, not this
 * file's.
 *
 * ## Nothing re-fetches on its own
 *
 * Not on a rejoin, not on a reconnect, not on a timer. The gap that leaves is
 * the one `use-peer-surface.ts` closed with `joinGeneration`: a message sent
 * while this socket was down arrives on nobody's push and is not in a history
 * fetched before it. It is smaller here — a room is remounted by opening it,
 * which is `rooms-route.tsx`'s `openAttempt`, and every open re-fetches — and
 * it is recorded rather than closed, because closing it means this hook
 * depending on the channel's join count, which is the coupling the two files
 * exist without.
 */

import { useCallback, useEffect, useMemo, useState } from "react";

import type { ApiResult } from "../../api/client";
import type { RequestFailure } from "../../api/errors";
import { useSession } from "../../session/session-context";
import type { HistoryExtent, MessagePage, RoomRef } from "./room";
import { fetchShiftRoomHistory, fetchVenueRoomHistory } from "./rooms-api";

export type HistoryState =
  /** Nobody is signed in, so there is nothing to ask with. */
  | { readonly status: "idle" }
  | { readonly status: "loading" }
  | { readonly status: "ready"; readonly page: MessagePage }
  | { readonly status: "failed"; readonly failure: RequestFailure };

export type RoomHistory = {
  readonly state: HistoryState;
  /** Which extent produced `state`, so the control knows what it already asked. */
  readonly extent: HistoryExtent;
  /** Asks again for the whole history. Idempotent; a no-op once it has. */
  readonly loadAll: () => void;
};

const IDLE: HistoryState = { status: "idle" };
const LOADING: HistoryState = { status: "loading" };

type Ask = () => Promise<ApiResult<MessagePage>>;

/** An answer, stamped with the request it answers. */
type Outcome = { readonly ask: Ask; readonly state: HistoryState };

/**
 * `idle` and `loading` are derived rather than stored, for `use-room.ts`'s
 * reason and `use-room-lists.ts`'s: the only write happens in the promise's
 * callback, and it carries the request it answers. A synchronous `setState` in
 * an effect body is a cascading render, and an outcome that does not match the
 * current request is a request still in flight — which is exactly what
 * `loadAll` produces for one render.
 */
export function useRoomHistory(ref: RoomRef): RoomHistory {
  const { state: session, api } = useSession();
  const token = session.status === "authenticated" ? session.token : null;

  const [extent, setExtent] = useState<HistoryExtent>("recent");
  const [outcome, setOutcome] = useState<Outcome | null>(null);

  // The two primitives rather than the object, so a parent that rebuilds the
  // reference on every render does not re-fetch on every render.
  const { kind, id } = ref;

  const ask = useMemo<Ask | null>(() => {
    if (token === null) return null;

    switch (kind) {
      case "venue":
        return () => fetchVenueRoomHistory(api, token, id, extent);
      case "shift":
        return () => fetchShiftRoomHistory(api, token, id, extent);
    }
  }, [api, token, kind, id, extent]);

  useEffect(() => {
    if (ask === null) return;

    let abandoned = false;

    void ask().then((result) => {
      if (abandoned) return;

      setOutcome({
        ask,
        state: result.ok
          ? { status: "ready", page: result.value }
          : { status: "failed", failure: result.failure },
      });
    });

    return () => {
      abandoned = true;
    };
  }, [ask]);

  const loadAll = useCallback(() => {
    setExtent("all");
  }, []);

  return { state: settled(ask, outcome), extent, loadAll };
}

function settled(ask: Ask | null, outcome: Outcome | null): HistoryState {
  if (ask === null) return IDLE;
  if (outcome?.ask !== ask) return LOADING;

  return outcome.state;
}
