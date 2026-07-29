/**
 * The employer routes' three bodies, turned into the shapes the surface
 * renders.
 *
 * Same posture as every other decoder here: `null` for "this is not that",
 * never a partial value and never a throw, so a field the server renames
 * surfaces as `malformed_response` rather than as `undefined` in a heading.
 *
 * The shapes are `HospitalityComsWeb.EmployerController`'s `render_venue/1`,
 * `render_engagement/1` and `render_invitation/1`.
 *
 *     GET  /api/employer/venues                        {venues: [...]}
 *     GET  /api/employer/venues/:venue_id/engagements  {engagements: [...]}
 *     POST /api/employer/venues/:venue_id/invitations  {invitation: {...}, claim_code: "..."}
 *
 * ## The output key set is the fourth pin on R18, and it points the other way
 *
 * The server carries three: a structural `@spec` Dialyzer checks, an exact
 * key-set equality in `employer_controller_test.exs`, and a control asserting
 * `Engagement.__schema__(:fields)` still holds `:person_id` so an empty render
 * cannot pass for a redacted one. All three fail when the **server** starts
 * sending a field it should not.
 *
 * This is the one that holds when they do not. Each decoder below builds a new
 * object naming its fields one at a time — never a spread of the payload, never
 * `Object.assign` — so a `person_id` that reaches this client reaches nothing
 * past it. `decode.test.ts` pins the resulting key set against a literal and
 * feeds one in.
 *
 * ## `venue_id` and `name` are spelled the way the room surface spells them
 *
 * `render_venue/1` and `RoomController.render_venue_room/1` render the same two
 * keys for the same entity, and one entity gets one key name across this API —
 * so `ManagedVenue` and `VenueRoomListing` are structurally identical and are
 * still two types, because they answer two different questions: *which venues
 * may I act for* and *which venue rooms am I in*. Those sets differ, and the
 * whole reason this surface exists on a route of its own is that they must be
 * allowed to (`Engagements.list_managed_venues/1` consults no suspension).
 */

import { isRecord } from "../../api/decode";
import type {
  IssuedOffer,
  ManagedVenue,
  OfferedInvitation,
  VenueEngagement,
} from "./employer";

/**
 * Decodes an array whose every element must decode, or nothing.
 *
 * All-or-nothing rather than filtering, for `features/rooms/decode.ts`'s
 * reason: a list silently one entry short is a person missing from a venue's
 * roll with no sentence anywhere saying why. One bad entry fails the whole
 * body, which the caller reports as `malformed_response`.
 */
function decodeEach<T>(
  value: unknown,
  one: (entry: unknown) => T | null,
): readonly T[] | null {
  if (!Array.isArray(value)) return null;

  const decoded: T[] = [];

  for (const entry of value) {
    const item = one(entry);
    if (item === null) return null;
    decoded.push(item);
  }

  return decoded;
}

/** `%{venue_id:, name:}` — one entry of `GET /api/employer/venues`. */
export function decodeManagedVenue(value: unknown): ManagedVenue | null {
  if (!isRecord(value)) return null;
  if (typeof value.venue_id !== "string") return null;
  if (typeof value.name !== "string") return null;

  return { venueId: value.venue_id, name: value.name };
}

/** `%{venues: [...]}` — the body of the venue picker's read. */
export function decodeManagedVenues(body: unknown): readonly ManagedVenue[] | null {
  if (!isRecord(body)) return null;

  return decodeEach(body.venues, decodeManagedVenue);
}

/**
 * One entry of `GET /api/employer/venues/:venue_id/engagements`.
 *
 * Four fields, all required, and **the object built here carries exactly
 * those** — a payload that also names a person decodes without them. See this
 * file's header.
 */
export function decodeVenueEngagement(value: unknown): VenueEngagement | null {
  if (!isRecord(value)) return null;
  if (typeof value.engagement_id !== "string") return null;
  if (typeof value.role_label !== "string") return null;
  if (typeof value.starts_at !== "string") return null;
  if (typeof value.ends_at !== "string") return null;

  return {
    engagementId: value.engagement_id,
    roleLabel: value.role_label,
    startsAt: value.starts_at,
    endsAt: value.ends_at,
  };
}

/** `%{engagements: [...]}` — the body of the venue's people list. */
export function decodeVenueEngagements(body: unknown): readonly VenueEngagement[] | null {
  if (!isRecord(body)) return null;

  return decodeEach(body.engagements, decodeVenueEngagement);
}

/** `%{invitation_id:, role_label:, starts_at:, ends_at:, code_expires_at:}`. */
export function decodeOfferedInvitation(value: unknown): OfferedInvitation | null {
  if (!isRecord(value)) return null;
  if (typeof value.invitation_id !== "string") return null;
  if (typeof value.role_label !== "string") return null;
  if (typeof value.starts_at !== "string") return null;
  if (typeof value.ends_at !== "string") return null;
  if (typeof value.code_expires_at !== "string") return null;

  return {
    invitationId: value.invitation_id,
    roleLabel: value.role_label,
    startsAt: value.starts_at,
    endsAt: value.ends_at,
    codeExpiresAt: value.code_expires_at,
  };
}

/**
 * `%{invitation: {...}, claim_code: "..."}` — the whole `201` of an issued
 * offer.
 *
 * `claim_code` is **required and is not defaulted**. It is the only thing in
 * this response that cannot be asked for again, so a body arriving without one
 * has to be a named failure: defaulting it to an empty string would put a
 * successful-looking panel on screen with nothing in it to copy, and the
 * invitation would already have been written.
 */
export function decodeIssuedOffer(body: unknown): IssuedOffer | null {
  if (!isRecord(body)) return null;
  if (typeof body.claim_code !== "string") return null;

  const invitation = decodeOfferedInvitation(body.invitation);
  if (invitation === null) return null;

  return { invitation, claimCode: body.claim_code };
}
