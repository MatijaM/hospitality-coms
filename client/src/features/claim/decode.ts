/**
 * `POST /api/claims`' one body, turned into the shape the panel renders.
 *
 * Same posture as every decoder here: `null` for "this is not that", never a
 * partial value and never a throw. Six fields, all required, and the object
 * built below names them one at a time rather than spreading the payload — so a
 * `person_id` the server should never send reaches nothing past this function.
 *
 * The shape is `HospitalityComsWeb.ClaimController.render_engagement/1`, and the
 * envelope is `%{engagement: {...}}` rather than the engagement bare: it is the
 * `<resource>` key convention every other reply on this API uses, and the one a
 * later field would be added beside.
 */

import { isRecord } from "../../api/decode";
import type { ClaimedEngagement } from "./claim";

/** `%{engagement_id:, venue_id:, role_label:, starts_at:, ends_at:, accepted_at:}`. */
export function decodeClaimedEngagement(value: unknown): ClaimedEngagement | null {
  if (!isRecord(value)) return null;
  if (typeof value.engagement_id !== "string") return null;
  if (typeof value.venue_id !== "string") return null;
  if (typeof value.role_label !== "string") return null;
  if (typeof value.starts_at !== "string") return null;
  if (typeof value.ends_at !== "string") return null;
  if (typeof value.accepted_at !== "string") return null;

  return {
    engagementId: value.engagement_id,
    venueId: value.venue_id,
    roleLabel: value.role_label,
    startsAt: value.starts_at,
    endsAt: value.ends_at,
    acceptedAt: value.accepted_at,
  };
}

/** `%{engagement: {...}}` — the whole `201` of a claim. */
export function decodeClaim(body: unknown): ClaimedEngagement | null {
  if (!isRecord(body)) return null;

  return decodeClaimedEngagement(body.engagement);
}
