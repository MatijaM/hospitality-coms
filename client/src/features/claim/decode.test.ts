/**
 * `POST /api/claims`' body, decoded.
 *
 * Six fields and a literal key set, for `features/employer/decode.test.ts`'s
 * reason: the server pins what it renders, and this is what holds if that pin
 * ever stops holding. `Engagement` carries `person_id`, `invitation_id`,
 * `grant_id` and `lock_version` beyond what the route renders, and the decoder
 * names its fields one at a time so none of them can arrive here.
 */

import { describe, expect, it } from "vitest";

import { isSubmittable } from "./claim";
import { decodeClaim, decodeClaimedEngagement } from "./decode";

const CLAIMED = {
  engagement_id: "33333333-3333-4333-8333-333333333333",
  venue_id: "11111111-1111-4111-8111-111111111111",
  role_label: "Runner",
  starts_at: "2026-03-09T13:00:00Z",
  ends_at: "2026-06-07T13:00:00Z",
  accepted_at: "2026-03-09T13:00:00Z",
};

const CLAIMED_KEYS = [
  "acceptedAt",
  "endsAt",
  "engagementId",
  "roleLabel",
  "startsAt",
  "venueId",
];

describe("the engagement a claim produced", () => {
  it("has exactly the six keys the route renders", () => {
    const decoded = decodeClaimedEngagement(CLAIMED);

    expect(decoded).toEqual({
      engagementId: "33333333-3333-4333-8333-333333333333",
      venueId: "11111111-1111-4111-8111-111111111111",
      roleLabel: "Runner",
      startsAt: "2026-03-09T13:00:00Z",
      endsAt: "2026-06-07T13:00:00Z",
      acceptedAt: "2026-03-09T13:00:00Z",
    });
    expect(Object.keys(decoded ?? {}).sort()).toEqual(CLAIMED_KEYS);
  });

  it("decodes a payload carrying the schema's other columns without them", () => {
    const decoded = decodeClaimedEngagement({
      ...CLAIMED,
      person_id: "99999999-9999-4999-8999-999999999999",
      invitation_id: "44444444-4444-4444-8444-444444444444",
      lock_version: 0,
    });

    expect(Object.keys(decoded ?? {}).sort()).toEqual(CLAIMED_KEYS);
    expect(JSON.stringify(decoded)).not.toContain("99999999-9999-4999-8999-999999999999");
  });

  it("keeps accepted_at and starts_at apart, because they answer different questions", () => {
    // KTD13. An engagement accepted before its term opens is confirmed and not
    // yet active, and a decoder that dropped one of them would leave the panel
    // unable to say which state somebody is in.
    const decoded = decodeClaimedEngagement({
      ...CLAIMED,
      accepted_at: "2026-03-01T09:00:00Z",
    });

    expect(decoded?.acceptedAt).toBe("2026-03-01T09:00:00Z");
    expect(decoded?.startsAt).toBe("2026-03-09T13:00:00Z");
  });

  it("refuses a body with no accepted_at rather than rendering an undefined instant", () => {
    expect(
      decodeClaimedEngagement({
        engagement_id: CLAIMED.engagement_id,
        venue_id: CLAIMED.venue_id,
        role_label: CLAIMED.role_label,
        starts_at: CLAIMED.starts_at,
        ends_at: CLAIMED.ends_at,
      }),
    ).toBeNull();
  });

  it("reads it off the engagement key and nowhere else", () => {
    expect(decodeClaim({ engagement: CLAIMED })).not.toBeNull();
    expect(decodeClaim({ claim: CLAIMED })).toBeNull();
    expect(decodeClaim(CLAIMED)).toBeNull();
  });
});

describe("whether a code is worth sending", () => {
  it("refuses a blank one and one that is only spaces", () => {
    expect(isSubmittable("")).toBe(false);
    expect(isSubmittable("   ")).toBe(false);
  });

  it("accepts one with something in it", () => {
    expect(isSubmittable(" Y29kZQ ")).toBe(true);
  });
});
