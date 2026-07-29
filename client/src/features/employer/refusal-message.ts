/**
 * What to show a manager when an employer request fails.
 *
 * ## This surface renders the server's sentence, and it is the first that does
 *
 * `src/app/failure-message.ts` states the client's standing rule — *"the
 * envelope's own documentation says `code` is the machine-readable
 * discriminator and `message` is for a human reading a log"*, so the copy lives
 * client-side keyed on the code. The rooms, peers and profile surfaces each
 * carry a switch built that way. **This surface deliberately does the
 * opposite**, and the reason is a measurement rather than a preference.
 *
 * **The code is not a sufficient discriminator on these routes.**
 * `HospitalityComsWeb.ErrorEnvelope`'s `code` *is* the response's status atom,
 * and `HospitalityComsWeb.ClaimController` answers `409` for two different
 * refusals with two different sentences on purpose: `:already_claimed` ("that
 * claim code has already been redeemed") and `:grant_not_live` ("the authority
 * this offer confers is no longer live"), the second of which is explicitly
 * *not* given a status of its own because it "would claim a precision the
 * requirement does not ask for". A switch keyed on `conflict` can say one of
 * those two things and must be wrong about the other. There is no client-side
 * copy that fixes that; the sentence is the only place the distinction exists.
 *
 * **And these sentences are written for the person reading the screen.** *"no
 * such venue, or it is not one you can act for"*, *"that claim code has
 * expired"*, *"the offer was not accepted"* — compare `SessionController`'s
 * *"the log-in request could not be recorded"*, which is the kind of sentence
 * the standing rule was written about. R6 asks in as many words for a refusal
 * "with a sentence that distinguishes those three", which is a requirement
 * about the sentence.
 *
 * ## Three failures are still this client's to word, and they are the ones the
 * route did not author
 *
 * A network failure and a malformed body carry no sentence from this API at
 * all. And `unauthorized` comes from `HospitalityComsWeb.PersonAuth`, one
 * pipeline above every controller here, so it is neither surface's sentence and
 * says nothing about what the manager was doing — its copy stays local, exactly
 * as `features/rooms/refusal-message.ts` words it.
 *
 * The residue is on the record: a `400` on these routes would render the
 * server's `"claim_code is required"`, which names a wire field. Both forms
 * below guard the empty submission on this side, so it is not reachable without
 * a drift — and if one arrives, a sentence naming the field the client failed to
 * send is a better bug report than a generic one.
 */

import type { ApiFieldError, FieldErrors, RequestFailure } from "../../api/errors";

const SESSION_ENDED = "Your session has ended. Sign in again.";

/**
 * The sentence to put in front of the manager.
 *
 * Exhaustive over `RequestFailure["kind"]`, so a new member of that union fails
 * the build here rather than falling through to silence.
 */
export function employerFailureMessage(failure: RequestFailure): string {
  switch (failure.kind) {
    case "network_error":
      return "The server could not be reached. Nothing was changed; check your connection and try again.";
    case "malformed_response":
      return `The server answered in a way this client does not understand (${failure.status}). Nothing was changed.`;
    case "api_error":
    case "api_field_error":
      return failure.code === "unauthorized" ? SESSION_ENDED : failure.message;
  }
}

/**
 * The per-field messages a `422` carried, or nothing.
 *
 * Rendered as they arrive, which is the one exception the standing rule already
 * makes: they come from Ecto's changeset traversal and name an input the
 * manager filled in — here `role_label`, whose bound is a number this client
 * does not hold and must not restate.
 */
export function fieldProblems(failure: RequestFailure): FieldErrors | null {
  return isFieldError(failure) ? failure.fields : null;
}

function isFieldError(failure: RequestFailure): failure is ApiFieldError {
  return failure.kind === "api_field_error";
}
