/**
 * One shift's roster: who is on it, putting somebody on, and taking them off.
 *
 * ## Both writes re-read rather than editing what is on screen
 *
 * The roster is *"entries whose period contains the instant"*, answered by the
 * server at the instant it answers — so it is not a list this side may keep and
 * amend. Adding hands back the entry it created and removing hands back
 * nothing; either way the next truth is a read. Editing local state instead
 * would make the screen a second opinion about a set the server derives.
 *
 * ## The removal is the one call in this client that succeeds with no body
 *
 * `remove_from_roster/3` closes the period and keeps the row (KTD6b), so `204`
 * with no body is the honest answer — handing back a closed entry would give
 * this side a row it must not render. `removeFromRoster` therefore passes no
 * decoder, which is what `write`'s optional one exists for.
 *
 * ## `busy` closes both writes, not one
 *
 * A removal in flight closes the add form too, and every other row's button.
 * That is deliberate rather than lazy: both writes are answered by re-reading
 * one list, so two in flight would race to decide which answer is the current
 * one — and the loser's read would show a roster that is one write out of date
 * with nothing saying so.
 *
 * **The guard is behind each button's `disabled`**, which is `useOfferDesk`'s
 * arrangement. The attribute is what a manager sees; this is what the hook
 * promises a caller. The race it prevents is a second `DELETE` after a
 * successful one, which answers `404` — so the manager is told the removal
 * failed, for the removal that worked.
 *
 * ## `busy` is not what stops a duplicate add, and this one has a server behind it
 *
 * It covers two clicks on one outstanding request; once the answer is back it
 * is `false` again and the picker still holds whoever was chosen. So `add`
 * answers whether the write was accepted and `RosterPanel` forgets the choice
 * on that branch alone.
 *
 * Unlike the shift form there **is** a guard underneath — a second add of one
 * engagement to one shift meets `roster_entries_no_overlap`, and `Rosters`'
 * own `unrostered/3` check in front of it — so nothing duplicate is stored.
 * What arrives instead is R15's flat `404`, one sentence covering four
 * conditions, which a manager cannot tell from the shift room having gone away.
 * The clearing is what stops that refusal being reachable by accident at all.
 */

import { useCallback, useMemo, useState } from "react";

import type { RequestFailure } from "../../api/errors";
import type { Ask, Loaded } from "../../app/use-fetched";
import { useFetched } from "../../app/use-fetched";
import { useSession } from "../../session/session-context";
import type { RosterEntry } from "./employer";
import { addToRoster, fetchRoster, removeFromRoster } from "./employer-api";

export type RosterDesk = {
  readonly state: Loaded<readonly RosterEntry[]>;
  readonly problem: RequestFailure | null;
  /** True while either write is outstanding. Both controls are closed on it. */
  readonly busy: boolean;
  /**
   * Answers whether the server accepted it, so the picker can forget the
   * chosen engagement on that branch alone.
   *
   * `remove` answers nothing, and the asymmetry is the point rather than an
   * omission: a removal is driven by a button on the row it removes, so there
   * is no input holding a value that has already been spent.
   */
  readonly add: (engagementId: string) => Promise<boolean>;
  readonly remove: (engagementId: string) => Promise<void>;
};

export function useRoster(venueId: string, shiftRoomId: string): RosterDesk {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const [problem, setProblem] = useState<RequestFailure | null>(null);
  const [busy, setBusy] = useState(false);

  const ask = useMemo<Ask<readonly RosterEntry[]> | null>(
    () => (token === null ? null : () => fetchRoster(api, token, venueId, shiftRoomId)),
    [api, token, venueId, shiftRoomId],
  );

  const fetched = useFetched(ask);
  const { reload } = fetched;

  const add = useCallback(
    async (engagementId: string) => {
      if (token === null || engagementId === "" || busy) return false;

      setBusy(true);
      setProblem(null);

      const result = await addToRoster(api, token, venueId, shiftRoomId, engagementId);

      setBusy(false);

      if (result.ok) reload();
      else setProblem(result.failure);

      return result.ok;
    },
    [api, token, venueId, shiftRoomId, busy, reload],
  );

  const remove = useCallback(
    async (engagementId: string) => {
      if (token === null || busy) return;

      setBusy(true);
      setProblem(null);

      const result = await removeFromRoster(
        api,
        token,
        venueId,
        shiftRoomId,
        engagementId,
      );

      setBusy(false);

      if (result.ok) reload();
      else setProblem(result.failure);
    },
    [api, token, venueId, shiftRoomId, busy, reload],
  );

  return { state: fetched.state, problem, busy, add, remove };
}
