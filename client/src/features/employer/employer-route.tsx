/**
 * The employer's half of the handshake: pick a venue, see who is on it, offer
 * somebody a job, and copy the code once.
 *
 * ## The picker is a different list from the rooms surface's, on purpose
 *
 * It reads `GET /api/employer/venues` — venues where this person holds an
 * engagement carrying a grant the venue has not revoked, **suspensions not
 * consulted**. `GET /api/venue-rooms` looks like the same list and subtracts
 * suspensions, so a manager who opted out of their own venue room would keep
 * every authority they had and disappear from this page. `employer-api.ts`
 * carries the argument.
 *
 * The page says so out loud, because a manager who suspended a room and still
 * sees the venue here should be able to tell that it is deliberate.
 *
 * ## Nothing on this page names a human
 *
 * `GET /api/employer/venues/:venue_id/engagements` renders `{engagement_id,
 * role_label, starts_at, ends_at}` and nothing else — no `person_id`, no email,
 * and there is no name column anywhere in the schema to omit. So a worker here
 * is a role, a term, and an id that means nothing at any other venue, and the
 * page states that rather than leaving it as an absence somebody might read as
 * an oversight. It is the sentence the demo audience is meant to be able to
 * repeat back.
 *
 * ## The people list is a moment, not a membership
 *
 * `list_engagements/1` is active-at-instant and nothing stores membership, so
 * this list shrinks by itself when a term's upper bound passes and no job ran.
 * Hence a **Refresh** control that is always there rather than only after a
 * failure, and hence the reload after an offer is claimed in the other window —
 * which is F1's last step and the moment the surface exists to show.
 *
 * ## The claim code is shown once and this page is the only place it exists
 *
 * `useOfferDesk` holds it in component state and nothing else touches it: no
 * store, no URL, no log. Dismissing loses it, which is why the warning sits
 * beside the code rather than appearing after it is gone (R2), and why nothing
 * on this page offers to show it again.
 */

import { useState } from "react";
import { Link } from "react-router";

import { SessionBar } from "../../app/session-bar";
import type { Loaded } from "../../app/use-fetched";
import type { IssuedOffer, ManagedVenue } from "./employer";
import { engagementLabel, expiryLabel, offerLabel } from "./employer";
import { employerFailureMessage, fieldProblems } from "./refusal-message";
import type { OfferDesk } from "./use-employer-venue";
import {
  useManagedVenues,
  useOfferDesk,
  useVenueEngagements,
} from "./use-employer-venue";

export function EmployerRoute() {
  const venues = useManagedVenues();
  const [chosenId, setChosenId] = useState<string | null>(null);

  const chosen =
    venues.state.status === "ready"
      ? (venues.state.value.find((venue) => venue.venueId === chosenId) ?? null)
      : null;

  return (
    <section>
      <h1>Venues you manage</h1>
      <SessionBar />
      <p>
        <Link to="/">Back to your rooms, peers and record</Link>
      </p>

      <p>
        These are the venues you hold a live authority at, right now. A venue whose room
        you have suspended is still here — suspending a room is about your own reading of
        it and takes nothing away from what you can do on this page.
      </p>

      <Unlisted
        state={venues.state}
        onRetry={venues.reload}
        empty="You cannot act for any venue. That is not an error: an authority is granted at one venue at a time, and nobody has granted you one. Ask somebody who already manages a venue to send you an offer that carries it."
      />

      {venues.state.status === "ready" && venues.state.value.length > 0 && (
        <ul aria-label="Venues you can act for">
          {venues.state.value.map((venue) => (
            <li key={venue.venueId}>
              <button
                type="button"
                aria-current={venue.venueId === chosenId}
                onClick={() => {
                  setChosenId((current) =>
                    current === venue.venueId ? null : venue.venueId,
                  );
                }}
              >
                {venue.name}
              </button>
            </li>
          ))}
        </ul>
      )}

      {chosen !== null && <VenueDesk key={chosen.venueId} venue={chosen} />}
    </section>
  );
}

/**
 * One venue: who is on it, and the form that brings somebody new.
 *
 * Keyed on the venue in `EmployerRoute`, so switching venue remounts rather
 * than re-rendering — which is what drops a claim code issued at the venue
 * being left. A code belongs to one offer at one venue and carrying it across
 * would put it beside the wrong venue's name.
 */
function VenueDesk({ venue }: { readonly venue: ManagedVenue }) {
  const people = useVenueEngagements(venue.venueId);
  const desk = useOfferDesk(venue.venueId);

  return (
    <section aria-label={venue.name}>
      <h2>{venue.name}</h2>

      <h3>People here now</h3>
      <p>
        Everyone whose term is open at this moment. No name and no address: this API has
        neither, and the engagement id below is this venue&rsquo;s alone — it says nothing
        about where else somebody works.
      </p>

      <Unlisted
        state={people.state}
        onRetry={people.reload}
        empty="Nobody is engaged here at the moment. An offer claimed in the other window shows up on this list as soon as you refresh it."
      />

      {people.state.status === "ready" && people.state.value.length > 0 && (
        <ul aria-label="People here now">
          {people.state.value.map((engagement) => (
            <li key={engagement.engagementId}>
              {engagementLabel(engagement)} <code>{engagement.engagementId}</code>
            </li>
          ))}
        </ul>
      )}

      <button type="button" onClick={people.reload}>
        Refresh this list
      </button>

      <h3>Offer a job</h3>
      <OfferForm desk={desk} />
    </section>
  );
}

/**
 * The role label, and nothing else.
 *
 * The term and the code&rsquo;s expiry are optional on the route and defaulted
 * from the request&rsquo;s instant, and this form deliberately does not ask for
 * them: a browser computing "ninety days from now" would be a second clock, and
 * the server&rsquo;s is the one U11&rsquo;s demo controls move.
 *
 * The submit is closed while an answer is outstanding **and** while the field is
 * blank. The first is because two clicks are two live claim codes and the
 * manager would only ever be shown the second; the second is so a mistake costs
 * a sentence here rather than a round trip and a `422`.
 */
function OfferForm({ desk }: { readonly desk: OfferDesk }) {
  const [roleLabel, setRoleLabel] = useState("");
  const problem = desk.problem;
  const fields = problem === null ? null : fieldProblems(problem);

  return (
    <>
      <form
        onSubmit={(event) => {
          event.preventDefault();

          // No `issuing` check here. It would be a third spelling of the same
          // guard — the button carries it as the affordance and `useOfferDesk`
          // carries it as the rule — and measured, a guard behind two others
          // is one no mutation can kill.
          if (roleLabel.trim() === "") return;

          void desk.issue(roleLabel.trim());
        }}
      >
        <label htmlFor="role-label">Role</label>
        <input
          id="role-label"
          name="role-label"
          type="text"
          value={roleLabel}
          onChange={(event) => {
            setRoleLabel(event.target.value);
          }}
        />
        <button type="submit" disabled={desk.issuing || roleLabel.trim() === ""}>
          Offer this job
        </button>
      </form>

      {problem !== null && (
        <div role="alert">
          <p>{employerFailureMessage(problem)}</p>
          {fields !== null && (
            <ul>
              {Object.entries(fields).map(([field, messages]) => (
                <li key={field}>
                  {field}: {messages.join(", ")}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {desk.issued !== null && (
        <ClaimCode issued={desk.issued} onDismiss={desk.dismiss} />
      )}
    </>
  );
}

/**
 * The code, the warning, and the one control that loses it.
 *
 * The warning is above the code rather than below it: R2 asks the interface to
 * say the code is unrepeatable **before** it is lost, and a caution underneath a
 * button somebody already pressed is a caution nobody read.
 */
function ClaimCode({
  issued,
  onDismiss,
}: {
  readonly issued: IssuedOffer;
  readonly onDismiss: () => void;
}) {
  return (
    <div role="status">
      <h4>Claim code</h4>
      <p>
        <strong>Copy this now — it is shown once and nothing can show it again.</strong>{" "}
        The server keeps only a one-way digest of it, so no page, no route and no backup
        can produce it a second time. Send it to the new starter however you already talk
        to them; this product holds no address for them and never will.
      </p>
      <p>
        <code>{issued.claimCode}</code>
      </p>
      <p>
        {offerLabel(issued.invitation)}. The code stops working{" "}
        {expiryLabel(issued.invitation)}.
      </p>
      <button type="button" onClick={onDismiss}>
        I have copied it — hide it
      </button>
    </div>
  );
}

/**
 * The three states a fetched list has before it has rows, and nothing when it
 * has them.
 *
 * `aria-live="polite"` without `role="status"`, which is
 * `features/rooms/rooms-route.tsx`&rsquo;s choice for its reason: this page
 * already has one region a manager is waiting on — the claim code — and two
 * competing status regions make the important one harder to find.
 */
function Unlisted<T>({
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
          <p aria-live="polite">{employerFailureMessage(state.failure)}</p>
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
