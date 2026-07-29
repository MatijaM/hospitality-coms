/**
 * The nine employer routes, as paths and wire shapes.
 *
 * `api/client.ts` owns "an authenticated request that decodes or fails"; this
 * owns what is asked for and what comes back — the layering `features/rooms/`
 * established and the reason `write` is one verb there rather than three
 * methods.
 *
 * The routes, from `lib/hospitality_coms_web/router.ex`:
 *
 *     GET    /api/employer/venues                        {venues: [...]}
 *     GET    .../venues/:venue_id/engagements            {engagements: [...]}
 *     POST   .../venues/:venue_id/invitations            {invitation: {...}, claim_code}
 *     GET    .../venues/:venue_id/shift-types            {shift_types: [...]}
 *     POST   .../venues/:venue_id/shift-rooms            {shift_room: {...}}
 *     GET    .../venues/:venue_id/shift-rooms[?extent]   {shift_rooms: [...], complete}
 *     POST   .../shift-rooms/:id/roster                  {roster_entry: {...}}
 *     GET    .../shift-rooms/:id/roster                  {roster: [...]}
 *     DELETE .../shift-rooms/:id/roster/:engagement_id   204, no body
 *
 * The last is the only call in this client that succeeds with no body, and
 * `write`'s optional decoder exists for it — see `removeFromRoster` below.
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
import type { ListExtent } from "../../api/types";
import type { ShiftRoomListing } from "../../app/shift-room";
import {
  decodeCreatedRosterEntry,
  decodeCreatedShiftRoom,
  decodeIssuedOffer,
  decodeManagedVenues,
  decodeRoster,
  decodeShiftRoomPage,
  decodeShiftTypes,
  decodeVenueEngagements,
} from "./decode";
import type {
  IssuedOffer,
  ManagedVenue,
  RosterEntry,
  ShiftRoomPage,
  ShiftType,
  VenueEngagement,
} from "./employer";

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

/** The kinds of shift this venue runs — the create form's picker. */
export function fetchShiftTypes(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
): Promise<ApiResult<readonly ShiftType[]>> {
  return api.read(
    `/api/employer/venues/${venueId}/shift-types`,
    sessionToken,
    decodeShiftTypes,
  );
}

/**
 * The venue's shift rooms, most recent first and bounded unless `extent` is
 * `"all"`.
 *
 * **The extent is a word and there is no `limit` on this route.** The bound is
 * `Rooms.recent_shift_room_limit/0` and lives in the context, because a route
 * that took a number would leave the unbounded read one forgetful caller away —
 * which is how both of `Rooms`' history functions came to be `Repo.all/1` over
 * a room's entire life. This client does not know what `"recent"` amounts to.
 */
export function fetchShiftRooms(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  extent: ListExtent,
): Promise<ApiResult<ShiftRoomPage>> {
  return api.read(
    `/api/employer/venues/${venueId}/shift-rooms?extent=${extent}`,
    sessionToken,
    decodeShiftRoomPage,
  );
}

/**
 * Creates tonight's shift: a room of the named type, over the named term.
 *
 * **Three fields and no more.** `venue_id` and `grace_period_minutes` come off
 * the shift type `Rooms.create_shift_room/3` resolves inside its own
 * transaction and are not castable — the controller's `Map.take/2` is what
 * strips them, and a client sending either would be relying on that rather than
 * on its own correctness. A `venue_id` in user attributes is a cross-tenant
 * write waiting for somebody to forget.
 */
export function createShiftRoom(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  shift: {
    readonly shiftTypeId: string;
    readonly startsAt: string;
    readonly endsAt: string;
  },
): Promise<ApiResult<ShiftRoomListing>> {
  return api.write(
    {
      method: "POST",
      path: `/api/employer/venues/${venueId}/shift-rooms`,
      body: {
        shift_type_id: shift.shiftTypeId,
        starts_at: shift.startsAt,
        ends_at: shift.endsAt,
      },
      status: 201,
    },
    sessionToken,
    decodeCreatedShiftRoom,
  );
}

/** Who is on a shift at the instant the server answers. */
export function fetchRoster(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  shiftRoomId: string,
): Promise<ApiResult<readonly RosterEntry[]>> {
  return api.read(rosterPath(venueId, shiftRoomId), sessionToken, decodeRoster);
}

/** Puts an engagement on a shift's roster, from this request's instant. */
export function addToRoster(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  shiftRoomId: string,
  engagementId: string,
): Promise<ApiResult<RosterEntry>> {
  return api.write(
    {
      method: "POST",
      path: rosterPath(venueId, shiftRoomId),
      body: { engagement_id: engagementId },
      status: 201,
    },
    sessionToken,
    decodeCreatedRosterEntry,
  );
}

/**
 * Takes an engagement off a shift's roster.
 *
 * **No decoder, and that is the whole of why `write` has an optional one.** The
 * route answers `204` with no body — `remove_from_roster/3` closes the period
 * and keeps the row (KTD6b), so handing the closed entry back would give this
 * client a row it must not render. Omitting the decoder is what stops the body
 * being read at all; a `read`-shaped call here reports the removal as
 * `malformed_response` *after it has succeeded*, and every retry then meets
 * `:not_rostered`.
 *
 * The caller re-reads the roster rather than being told what changed.
 */
export function removeFromRoster(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  shiftRoomId: string,
  engagementId: string,
): Promise<ApiResult<null>> {
  return api.write(
    {
      method: "DELETE",
      path: `${rosterPath(venueId, shiftRoomId)}/${engagementId}`,
      status: 204,
    },
    sessionToken,
  );
}

/** One spelling of the roster's path, which two verbs and a read all name. */
function rosterPath(venueId: string, shiftRoomId: string): string {
  return `/api/employer/venues/${venueId}/shift-rooms/${shiftRoomId}/roster`;
}
