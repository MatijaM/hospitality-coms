/**
 * Where a new starter turns a code somebody handed them into a job.
 *
 * One field and one button. Everything about the engagement — the venue, the
 * role, the term — comes off the invitation, so there is nothing else to ask
 * for and nothing this panel could offer that would not be a claim rewriting
 * its own offer.
 *
 * ## The empty submission never reaches the API
 *
 * `POST /api/claims` with no code answers `400 "claim_code is required"`, which
 * names a wire field rather than anything the worker did. So the guard is here,
 * with a sentence that is about the box in front of them — and the request is
 * not sent at all, which `claim-panel.test.tsx` asserts against the call count
 * rather than against what is on screen.
 *
 * ## The submit closes while an answer is outstanding
 *
 * A claim code is single use and the second attempt is refused
 * `409 already_claimed`. Without the guard, the second half of a double-click
 * writes "that claim code has already been redeemed" over the engagement the
 * first half just produced — the worker is told their successful claim failed,
 * about a code that has now genuinely gone.
 *
 * ## The venue arrives as an id, and the panel says where its name is
 *
 * `ClaimController` renders `venue_id` and no name; `features/claim/claim.ts`
 * records why that is left alone. A uuid on screen with no explanation is the
 * thing the room list was rebuilt to stop, so this one is labelled and pointed
 * at the list that does carry the name.
 */

import { useState } from "react";
import { Link } from "react-router";

import type { RequestFailure } from "../../api/errors";
import { SessionBar } from "../../app/session-bar";
import { useSession } from "../../session/session-context";
import { instantLabel, termLabel } from "../rooms/room";
import type { ClaimedEngagement } from "./claim";
import { isSubmittable } from "./claim";
import { claimInvitation } from "./claim-api";
import { claimFailureMessage } from "./refusal-message";

export function ClaimPanel() {
  const { state, api } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  const [code, setCode] = useState("");
  const [claiming, setClaiming] = useState(false);
  const [claimed, setClaimed] = useState<ClaimedEngagement | null>(null);
  const [problem, setProblem] = useState<RequestFailure | null>(null);
  const [blank, setBlank] = useState(false);

  async function submit(): Promise<void> {
    if (token === null || claiming) return;

    if (!isSubmittable(code)) {
      setBlank(true);

      return;
    }

    setBlank(false);
    setClaiming(true);
    setClaimed(null);
    setProblem(null);

    const result = await claimInvitation(api, token, code.trim());

    setClaiming(false);

    if (result.ok) {
      setClaimed(result.value);
      setCode("");
    } else {
      setProblem(result.failure);
    }
  }

  return (
    <section>
      <h1>Claim a job</h1>
      <SessionBar />
      <p>
        <Link to="/">Back to your rooms, peers and record</Link>
      </p>

      <p>
        Paste the code a manager gave you. Nobody sent it to you through this product — it
        holds no address for you and no way to reach you — so it arrived however you two
        already talk.
      </p>

      <form
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <label htmlFor="claim-code">Claim code</label>
        <input
          id="claim-code"
          name="claim-code"
          type="text"
          value={code}
          onChange={(event) => {
            setCode(event.target.value);
          }}
        />
        <button type="submit" disabled={claiming}>
          Claim this job
        </button>
      </form>

      {blank && <p role="alert">Paste the code into the box first.</p>}

      {problem !== null && <p role="alert">{claimFailureMessage(problem)}</p>}

      {claimed !== null && <Claimed engagement={claimed} />}
    </section>
  );
}

/**
 * What the claim produced.
 *
 * Both instants are here because they answer different questions (KTD13): a
 * term that opens later is confirmed and not yet active, and a panel showing
 * only one of them could not say which.
 */
function Claimed({ engagement }: { readonly engagement: ClaimedEngagement }) {
  return (
    <div role="status">
      <h2>You are on</h2>
      <p>
        <strong>{engagement.roleLabel}</strong>,{" "}
        {termLabel(engagement.startsAt, engagement.endsAt)}.
      </p>
      <p>Accepted {instantLabel(engagement.acceptedAt)}.</p>
      <p>
        The venue is <code>{engagement.venueId}</code>. Its name is not on this reply — it
        appears under <Link to="/rooms">your rooms</Link> once the term is open, and the
        venue room comes with it.
      </p>
      <p>
        Engagement <code>{engagement.engagementId}</code>. That id belongs to this venue
        alone.
      </p>
    </div>
  );
}
