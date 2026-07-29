/**
 * One fetched answer, held as a state machine, for any surface that reads a
 * list over HTTP.
 *
 * It was `features/rooms/use-room-lists.ts`'s private `useFetched`, and the
 * employer surface is the second caller — two lists there and two here, all
 * four with the same three hazards and the same three non-answers. Copying it
 * would have been forty lines of stale-answer discipline duplicated in a
 * feature directory, which is the thing this project un-duplicates rather than
 * the thing it tolerates (`src/socket/topic-id.ts` is the precedent, hoisted
 * when its second copy appeared).
 *
 * It lives here rather than in `src/api/` because it is React state.
 * **Nothing in `src/api/` imports React**, and that is what lets the client and
 * its decoders be tested with no renderer at all; a hook there would end it for
 * a filing convenience.
 *
 * ## `idle` is a state, and it is not `ready` with nothing in it
 *
 * `useFetched(null)` is "nothing has been asked" — no venue chosen, no session
 * yet. Collapsing it into an empty answer makes an unopened panel and a genuinely
 * empty one render identically, and the empty one is the sentence AE10 asks for.
 *
 * ## Aborted rather than cancelled
 *
 * `AbortController` is not used and a request in flight is not stopped; the
 * effect's cleanup sets a flag and the answer is dropped. `session-context.tsx`
 * takes the same shape for `GET /api/me` and for the same reason: `FetchLike`
 * is the whole test seam, and threading a signal through it would make every
 * fake in the suite implement one.
 */

import { useCallback, useEffect, useState } from "react";

import type { ApiResult } from "../api/client";
import type { RequestFailure } from "../api/errors";

export type Loaded<T> =
  /** Nothing has been asked — no venue chosen, or no session to ask with. */
  | { readonly status: "idle" }
  | { readonly status: "loading" }
  | { readonly status: "ready"; readonly value: T }
  | { readonly status: "failed"; readonly failure: RequestFailure };

export type Fetched<T> = {
  readonly state: Loaded<T>;
  readonly reload: () => void;
};

const LOADING: Loaded<never> = { status: "loading" };
const IDLE: Loaded<never> = { status: "idle" };

export type Ask<T> = () => Promise<ApiResult<T>>;

/** An answer, stamped with the request it answers. */
type Outcome<T> = {
  readonly ask: Ask<T>;
  readonly attempt: number;
  readonly state: Loaded<T>;
};

/**
 * Runs `ask` whenever it changes, and answers with the outcome. `null` is the
 * idle state and asks nothing.
 *
 * `ask` is a `useMemo` from the caller, so this effect's dependency is the
 * caller's own memoisation — a caller that rebuilt it on every render would
 * re-ask on every render, which is why every hook below builds theirs from
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
export function useFetched<T>(ask: Ask<T> | null): Fetched<T> {
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
): Loaded<T> {
  if (ask === null) return IDLE;
  if (outcome === null) return LOADING;
  if (outcome.ask !== ask || outcome.attempt !== attempt) return LOADING;

  return outcome.state;
}
