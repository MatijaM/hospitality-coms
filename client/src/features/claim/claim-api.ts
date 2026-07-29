/**
 * One route: `POST /api/claims`.
 *
 * The body is `{claim_code}` and nothing else, because the route casts nothing
 * else. Accepting an offer is accepting *the* offer — the term, the role and
 * the venue all come off the invitation — so there is no field here a client
 * could add that would mean anything, and one that could would be a claim
 * granting itself a year at a venue that offered a fortnight.
 *
 * `201` is the success. Every other status is a refusal and is rendered from
 * the envelope; `refusal-message.ts` says why this surface reads the sentence
 * rather than the code.
 */

import type { ApiClient, ApiResult } from "../../api/client";
import type { ClaimedEngagement } from "./claim";
import { decodeClaim } from "./decode";

/** Redeems a claim code under this session, and answers what it produced. */
export function claimInvitation(
  api: ApiClient,
  sessionToken: string,
  claimCode: string,
): Promise<ApiResult<ClaimedEngagement>> {
  return api.write(
    { method: "POST", path: "/api/claims", body: { claim_code: claimCode }, status: 201 },
    sessionToken,
    decodeClaim,
  );
}
