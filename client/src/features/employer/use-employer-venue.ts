/**
 * The three things the employer surface asks the server: which venues, who is
 * here, and one offer.
 *
 * ## Nothing is cached, and that is R16 rather than laziness
 *
 * Every employer request resolves its grant against the database at that
 * request's instant — `EmployerAuth.employer_scope/2` is called inside each
 * action and nothing is kept on the connection. This side keeps nothing either:
 * no store, no `localStorage` key, and nothing added to `SessionProvider`'s
 * `onSessionEnded`, because there is nothing here that would survive to be
 * cleared. A remembered venue list would be a remembered *authority*, and a
 * revoked grant would leave it on screen offering a venue every request against
 * it now refuses.
 *
 * The people list is the same answer one layer in: `list_engagements/1` is
 * active-at-instant and membership is stored nowhere, so the list is the
 * server's answer to one question at one moment. `reload` is offered and
 * nothing polls.
 *
 * ## The offer is a write, so it has an in-flight guard
 *
 * `issue` is closed while an answer is outstanding. Two clicks are two
 * invitations — an offer is an offer and nothing deduplicates them (AE2) — so a
 * double-click mints a second claim code, shows the manager the second, and
 * silently loses the first, which is a live credential for a job at their venue
 * that nothing can ever show them again.
 */

import { useCallback, useMemo, useState } from "react";

import type { RequestFailure } from "../../api/errors";
import type { Ask, Fetched } from "../../app/use-fetched";
import { useFetched } from "../../app/use-fetched";
import { useSession } from "../../session/session-context";
import type { IssuedOffer, ManagedVenue, VenueEngagement } from "./employer";
import {
  fetchManagedVenues,
  fetchVenueEngagements,
  issueInvitation,
} from "./employer-api";

/** The venues this session may act for. */
export function useManagedVenues(): Fetched<readonly ManagedVenue[]> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<readonly ManagedVenue[]> | null>(
    () => (token === null ? null : () => fetchManagedVenues(api, token)),
    [api, token],
  );

  return useFetched(ask);
}

/**
 * The people engaged at `venueId`, or nothing if no venue is chosen.
 *
 * `null` is idle rather than empty, for `use-fetched.ts`'s reason: a venue
 * nobody has picked and a venue with nobody at it are two different sentences.
 */
export function useVenueEngagements(
  venueId: string | null,
): Fetched<readonly VenueEngagement[]> {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const ask = useMemo<Ask<readonly VenueEngagement[]> | null>(
    () =>
      token === null || venueId === null
        ? null
        : () => fetchVenueEngagements(api, token, venueId),
    [api, token, venueId],
  );

  return useFetched(ask);
}

export type OfferDesk = {
  /** The code and its invitation, until the manager dismisses them. */
  readonly issued: IssuedOffer | null;
  readonly problem: RequestFailure | null;
  /** True while an answer is outstanding. The form is closed on it. */
  readonly issuing: boolean;
  readonly issue: (roleLabel: string) => Promise<void>;
  readonly dismiss: () => void;
};

/**
 * Issuing one offer at one venue, and holding its code until it is dismissed.
 *
 * **`dismiss` is destructive and is the only exit.** The plaintext code exists
 * in this hook's state and nowhere else in the world — the row keeps a SHA-256
 * digest, no route renders one, and `Engagements.list_invitations/1` could not
 * produce it if one did. So dismissing does not hide it; it loses it, which is
 * what R2 asks the interface to say **before** it happens rather than after.
 *
 * A refusal clears any code still on screen, because the two together would say
 * an offer both succeeded and failed. A new offer clears the previous one for
 * the same reason, and that is the one place this can lose a code the manager
 * had not copied — deliberate, because the alternative is a growing pile of
 * live credentials on a shared terminal.
 *
 * **The `issuing` guard below is deliberately behind the button's `disabled`,
 * and that is measured rather than assumed.** Removing it alone kills no test,
 * because a disabled submit cannot be clicked a second time; removing the
 * attribute is what turns "issues once however fast the button is clicked" red.
 * It is kept because the two answer different questions — the attribute is what
 * a manager sees, this is what the hook promises a caller — and because the
 * cost of the race it prevents is a second live claim code nothing can ever
 * show again. A **third** copy in the form's `onSubmit` was removed, since a
 * guard behind two others is one no mutation can reach.
 */
export function useOfferDesk(venueId: string | null): OfferDesk {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const [issued, setIssued] = useState<IssuedOffer | null>(null);
  const [problem, setProblem] = useState<RequestFailure | null>(null);
  const [issuing, setIssuing] = useState(false);

  const dismiss = useCallback(() => {
    setIssued(null);
    setProblem(null);
  }, []);

  const issue = useCallback(
    async (roleLabel: string) => {
      if (token === null || venueId === null || issuing) return;

      setIssuing(true);
      setIssued(null);
      setProblem(null);

      const result = await issueInvitation(api, token, venueId, roleLabel);

      setIssuing(false);

      if (result.ok) setIssued(result.value);
      else setProblem(result.failure);
    },
    [api, token, venueId, issuing],
  );

  return { issued, problem, issuing, issue, dismiss };
}
