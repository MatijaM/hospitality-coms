/**
 * What to show somebody whose claim was refused.
 *
 * ## The sentence comes from the envelope, and here the requirement says so
 *
 * The standing rule (`src/app/failure-message.ts`) is that the server's
 * `message` is for a log and the copy lives client-side keyed on `code`. R6
 * asks for the opposite in as many words: *"a code that is unknown, already
 * claimed, or expired is refused with a sentence that distinguishes those
 * three"*. `HospitalityComsWeb.ClaimController` is the one place in this API
 * that is deliberately not flat, and it explains why — the holder of a code
 * already holds it, so "there is an offer behind this" is not news and whether
 * it was taken or lapsed is a fact about their own offer.
 *
 * **A switch keyed on the code cannot carry it.** `ErrorEnvelope`'s `code` *is*
 * the response's status atom, and that controller answers `409` twice with two
 * different sentences: `:already_claimed` — the offer was taken by somebody
 * else, and nothing will bring it back — and `:grant_not_live` — the code is
 * fine and **unspent**, and re-issuing the authority makes the same code good
 * again. Those are opposite instructions to the person reading them, and one
 * `conflict` case would have to pick one and be wrong about the other.
 *
 * So this surface renders `failure.message`. The consequence is written down
 * rather than left implicit: **this client no longer controls that copy**, and a
 * server-side rewording changes what a worker reads with nothing here to review
 * it. That is the price of the distinction R6 asks for, and it is the reason
 * `claim-panel.test.tsx` proves the sentence is *carried* rather than matched —
 * two refusals with the same code and different sentences, each rendered as it
 * arrived.
 *
 * ## Two failures are still this client's to word
 *
 * A network failure and a malformed body carry no sentence from this API at
 * all, and `unauthorized` comes from `HospitalityComsWeb.PersonAuth` rather
 * than from this route — it says the session is gone, which is not a fact about
 * the code and not something "that claim code" should be prefixed to.
 */

import type { RequestFailure } from "../../api/errors";

export function claimFailureMessage(failure: RequestFailure): string {
  switch (failure.kind) {
    case "network_error":
      return "The server could not be reached. Nothing was claimed; check your connection and try again.";
    case "malformed_response":
      return `The server answered in a way this client does not understand (${failure.status}). Nothing was claimed.`;
    case "api_error":
    case "api_field_error":
      return failure.code === "unauthorized"
        ? "Your session has ended. Sign in again, then paste the code."
        : failure.message;
  }
}
