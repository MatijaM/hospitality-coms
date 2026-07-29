/**
 * The four person-side room reads, as paths and decoders.
 *
 * This is the layer `api/client.ts` deliberately does not have: it owns
 * `read` — an authenticated GET that decodes or fails — and a feature owns what
 * it asks for and what comes back. The profile surface
 * (`features/profile/contract.ts`) is waiting on the same fork and adds a file
 * beside this one rather than four methods to the client.
 *
 * The routes, from `lib/hospitality_coms_web/router.ex`:
 *
 *     GET /api/venue-rooms                            {venue_rooms: [...]}
 *     GET /api/venue-rooms/:venue_id/messages         {messages: [...], complete}
 *     GET /api/venues/:venue_id/shift-rooms           {shift_rooms: [...]}
 *     GET /api/shift-rooms/:id/messages               {messages: [...], complete}
 *
 * ## The shift-room list is under the venue, not under the venue room
 *
 * That is the server's shape and it is KTD18: a suspended person is out of the
 * venue room and still on their shift rosters, so a path nested under the venue
 * *room* would invite a membership gate that quietly extended suspension to
 * shift rooms. `RoomController`'s moduledoc carries the argument. The
 * consequence here is small and worth knowing: **a venue id that came out of
 * the venue-room list is not the only one this route accepts**, and a venue the
 * person has nothing at answers an empty list rather than a refusal.
 *
 * ## `extent` is a word, never a number
 *
 * The bound is `HospitalityComs.Rooms.recent_message_limit/0` and lives in the
 * context. There is no `limit` parameter on any of these routes, and adding one
 * would put the unbounded read one forgetful caller away — which is what it was
 * before U12. This client asks for `"recent"` or `"all"` and does not know what
 * the first amounts to.
 *
 * ## Ids are not escaped here, because they cannot be anything but ids
 *
 * Every id reaching these functions has been through `normaliseRoomId` or came
 * out of a decoded server payload, so it is a lowercase uuid. A malformed one
 * would be answered `404` by `HospitalityComsWeb.EntityId` in any case, which
 * is the same answer an unknown room gets (AE1).
 */

import type { ApiClient, ApiResult } from "../../api/client";
import { decodeMessagePage, decodeShiftRooms, decodeVenueRooms } from "./decode";
import type {
  HistoryExtent,
  MessagePage,
  ShiftRoomListing,
  VenueRoomListing,
} from "./room";

/** The venue rooms this session is in, by name. */
export function fetchVenueRooms(
  api: ApiClient,
  sessionToken: string,
): Promise<ApiResult<readonly VenueRoomListing[]>> {
  return api.read("/api/venue-rooms", sessionToken, decodeVenueRooms);
}

/** The shift rooms this session may read at one venue, earliest first. */
export function fetchShiftRooms(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
): Promise<ApiResult<readonly ShiftRoomListing[]>> {
  return api.read(`/api/venues/${venueId}/shift-rooms`, sessionToken, decodeShiftRooms);
}

/** A venue room's history, bounded unless `extent` is `"all"`. */
export function fetchVenueRoomHistory(
  api: ApiClient,
  sessionToken: string,
  venueId: string,
  extent: HistoryExtent,
): Promise<ApiResult<MessagePage>> {
  return api.read(
    `/api/venue-rooms/${venueId}/messages?extent=${extent}`,
    sessionToken,
    decodeMessagePage,
  );
}

/** A shift room's history, bounded unless `extent` is `"all"`. */
export function fetchShiftRoomHistory(
  api: ApiClient,
  sessionToken: string,
  shiftRoomId: string,
  extent: HistoryExtent,
): Promise<ApiResult<MessagePage>> {
  return api.read(
    `/api/shift-rooms/${shiftRoomId}/messages?extent=${extent}`,
    sessionToken,
    decodeMessagePage,
  );
}
