/**
 * The three employer routes, as paths and wire shapes.
 *
 * `api/client.ts` owns "an authenticated request that decodes or fails"; this
 * owns what is asked for and what comes back — the layering `features/rooms/`
 * established and the reason `write` is one verb there rather than three
 * methods.
 *
 * The routes, from `lib/hospitality_coms_web/router.ex`:
 *
 *     GET  /api/employer/venues                        {venues: [...]}
 *     GET  /api/employer/venues/:venue_id/engagements  {engagements: [...]}
 *     POST /api/employer/venues/:venue_id/invitations  {invitation: {...}, claim_code}
 *
 * ## The picker reads `/api/employer/venues`, and `/api/venue-rooms` would be wrong
 *
 * The venue-room list already answers `{venue_id, name}` for every venue a
 * person is engaged at, needs no new route, and is the obvious reuse. It is
 * also **a strict subset in the direction that matters**:
 * `Rooms.list_venue_rooms/1` applies `unsuspended/2` and
 * `Engagements.fetch_grant_holding_engagement/2` never consults a suspension.
 *
 * So a manager who used the person-side venue-room opt-out — their own choice,
 * about their own reading, at their own venue — would keep full authority over
 * that venue and **vanish from their own picker**, with no other way in and
 * nothing failing anywhere to say why: every employer request they made by hand
 * would still work. That is the coupling KTD18 exists to prevent, arriving at
 * the transport after both tiers below it got it right.
 * `engagements_test.exs` carries the suspended manager who appears here with
 * `list_venue_rooms/1` answering `[]` beside them.
 *
 * ## The offer sends one field, and the three instants are the server's
 *
 * `role_label` and nothing else. `starts_at`, `ends_at` and `code_expires_at`
 * are optional on the route and defaulted from the request's instant, and this
 * client must not fill them in: `HospitalityComs.Clock` is offsettable and U11's
 * demo controls move it, so a browser computing "ninety days from now" against
 * its own clock would be a **second clock** and the two would disagree by
 * whatever the offset was. `EmployerController`'s moduledoc states it from the
 * other side.
 *
 * `grant_id` is not sent either, and could not be: the controller takes exactly
 * four fields off the body and that is not one of them, because an invitation
 * carrying a grant is an invitation to *manage*.
 */

import type { ApiClient, ApiResult } from "../../api/client";
import { decodeIssuedOffer, decodeManagedVenues, decodeVenueEngagements } from "./decode";
import type { IssuedOffer, ManagedVenue, VenueEngagement } from "./employer";

/** The venues this session may act for, suspensions not consulted. */
export function fetchManagedVenues(
  api: ApiClient,
  sessionToken: string,
): Promise<ApiResult<readonly ManagedVenue[]>> {
  return api.read("/api/employer/venues", sessionToken, decodeManagedVenues);
}

/** The people engaged at one venue, at the instant the server answers. */
export function fetchVenueEngagements(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
): Promise<ApiResult<readonly VenueEngagement[]>> {
  return api.read(
    `/api/employer/venues/${venueId}/engagements`,
    sessionToken,
    decodeVenueEngagements,
  );
}

/**
 * Issues an offer at one venue and returns the code that redeems it, once.
 *
 * `201` is the success and every other status is a refusal, which the surface
 * renders from the envelope rather than from a code — see `refusal-message.ts`
 * for why that is this surface's rule and not the whole client's.
 */
export function issueInvitation(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  roleLabel: string,
): Promise<ApiResult<IssuedOffer>> {
  return api.write(
    {
      method: "POST",
      path: `/api/employer/venues/${venueId}/invitations`,
      body: { role_label: roleLabel },
      status: 201,
    },
    sessionToken,
    decodeIssuedOffer,
  );
}
