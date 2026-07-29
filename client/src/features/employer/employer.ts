/**
 * What the employer surface holds, and how it is written on screen.
 *
 * Three shapes, all of them `HospitalityComsWeb.EmployerController`'s render
 * functions in this client's camelCase. Every one of them is a **field list on
 * both sides**: the controller renders one because `Engagement` and
 * `Invitation` carry columns no employer may see, and this file names exactly
 * the same fields so that a column the server starts sending has nowhere to
 * arrive. `decode.ts` is where that is enforced and `decode.test.ts` is where
 * it is pinned.
 *
 * ## What is not here is the point of the surface
 *
 * There is **no `personId` and no email**, on any of these, because there is
 * none on the wire — `render_engagement/1` is `{engagement_id, role_label,
 * starts_at, ends_at}` and `people` has exactly one identifying column, which
 * no employer route touches. And there is **no `claimCodeDigest`**: the row
 * keeps only a SHA-256 of the code, `render_invitation/1` withholds even that,
 * and the plaintext arrives **beside** the invitation rather than inside it,
 * which is the shape saying it is not a property of the row.
 *
 * A worker on this surface is therefore a role label, a term, and an engagement
 * id that means nothing at any other venue. The interface says so rather than
 * papering over it.
 */

import { instantLabel, termLabel } from "../../app/instant";

/** `%{venue_id:, name:}` — one venue this session may act for. */
export type ManagedVenue = {
  readonly venueId: string;
  readonly name: string;
};

/**
 * `%{engagement_id:, role_label:, starts_at:, ends_at:}` — one person engaged
 * at the venue, at the instant the request was answered.
 *
 * "At the instant" is not decoration: `list_engagements/1` returns the venue's
 * engagements **active now**, nothing stores membership, and the same request a
 * minute after a term's upper bound answers a shorter list with no job having
 * run. So this is never cached and the surface offers a reload rather than
 * pretending the list is stable.
 */
export type VenueEngagement = {
  readonly engagementId: string;
  readonly roleLabel: string;
  readonly startsAt: string;
  readonly endsAt: string;
};

/** `%{invitation_id:, role_label:, starts_at:, ends_at:, code_expires_at:}`. */
export type OfferedInvitation = {
  readonly invitationId: string;
  readonly roleLabel: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly codeExpiresAt: string;
};

/**
 * The whole `201` of `POST /api/employer/venues/:venue_id/invitations`.
 *
 * `claimCode` is plaintext and this response is the only place it will ever
 * exist. Nothing stores it here — not the token store, not the room store, not
 * a URL — so it lives exactly as long as the component holding it, which is
 * what makes "dismissing it loses it" true rather than merely displayed.
 */
export type IssuedOffer = {
  readonly invitation: OfferedInvitation;
  readonly claimCode: string;
};

/**
 * How one engaged person is named on screen: the role, then the term.
 *
 * The role label is the employer's own words and the term is two instants; put
 * together they are everything this API discloses about a worker, and writing
 * them as one string is what stops the engagement id becoming the way a row is
 * recognised.
 *
 * `termLabel` is `src/app/instant.ts`'s, deliberately shared: a term rendered
 * one way beside a shift room and another way beside an engagement would be one
 * product speaking twice. It was the rooms surface's until this surface became
 * its second caller, which is what moved it.
 */
export function engagementLabel(engagement: VenueEngagement): string {
  return `${engagement.roleLabel} · ${termLabel(engagement.startsAt, engagement.endsAt)}`;
}

/** The same, for the offer that has not been claimed yet. */
export function offerLabel(invitation: OfferedInvitation): string {
  return `${invitation.roleLabel} · ${termLabel(invitation.startsAt, invitation.endsAt)}`;
}

/**
 * When a claim code stops working, written for a person.
 *
 * The server defaults it to seven days out and bounds it at fourteen; neither
 * number is computed here, and this client must not start computing one —
 * `HospitalityComs.Clock` is offsettable and moves the server's instant while
 * this browser's stays real, so anything derived from a comparison against
 * `Date.now()` would be wrong during exactly the demo the offset exists for.
 * The instant is rendered and never compared, which is the rule
 * `ShiftRoomListing.closesAt` already carries.
 */
export function expiryLabel(invitation: OfferedInvitation): string {
  return instantLabel(invitation.codeExpiresAt);
}
