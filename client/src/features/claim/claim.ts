/**
 * The worker's half of the handshake, and it is a feature of its own rather
 * than a corner of `features/employer/`.
 *
 * `POST /api/claims` is not under `/employer` and must not be. A claimant needs
 * no grant, no engagement and no prior relationship to the venue — the code is
 * the whole of what they hold, and that is the boundary the demo exists to
 * show. A claim panel filed under the employer surface would say the opposite
 * with its directory name.
 *
 * ## What comes back, and what it does not carry
 *
 * `HospitalityComsWeb.ClaimController.render_engagement/1` answers
 * `{engagement_id, venue_id, role_label, starts_at, ends_at, accepted_at}`.
 * `Engagement` also carries `person_id`, `invitation_id`, `grant_id` and
 * `lock_version`; the first is the claimant's own, so withholding it is the
 * same field-list discipline every other response follows rather than a
 * boundary rule.
 *
 * **`accepted_at` and `starts_at` are both here because they are different
 * questions.** KTD13 keeps them apart: an engagement accepted before its term
 * opens is confirmed and not yet active, and a panel that showed only one of
 * them could not say which of those two states somebody is in.
 *
 * ## There is no venue name on this reply, and that is the server's shape
 *
 * The claim answers a `venue_id` and nothing else about the venue. Rendering a
 * raw uuid at a worker is the mistake the room list already fixed once, so the
 * panel prints the id as an id and says where the name will appear — the venue
 * room's list, which carries it, as soon as the term is open. Asking the claim
 * route to join a name is a server change and is not made from here.
 */

/** The engagement a claim produced, as `ClaimController` renders it. */
export type ClaimedEngagement = {
  readonly engagementId: string;
  readonly venueId: string;
  readonly roleLabel: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly acceptedAt: string;
};

/**
 * Whether a code is worth sending at all.
 *
 * The server's own answer to an empty body is `400 "claim_code is required"`,
 * which names a wire field rather than anything the worker did — so the empty
 * submission is caught here, and the round trip that would produce that
 * sentence never happens.
 */
export function isSubmittable(code: string): boolean {
  return code.trim() !== "";
}
