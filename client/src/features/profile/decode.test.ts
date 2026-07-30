import { describe, expect, it } from "vitest";

import {
  decodeAttestedEntry,
  decodeAudiences,
  decodeCorrectionRequest,
  decodeDeclaredEntry,
  decodeDisclosure,
  decodeDisclosures,
  decodeJoinedProfile,
  decodeProfile,
} from "./decode";

const ENTRY = {
  attested_entry_id: "11111111-1111-4111-8111-111111111111",
  entry_engagement_id: "22222222-2222-4222-8222-222222222222",
  venue_id: "33333333-3333-4333-8333-333333333333",
  venue_name: "The Anchor",
  role_label: "Bartender",
  starts_at: "2026-01-01T00:00:00Z",
  ends_at: "2026-06-01T00:00:00Z",
  attested_at: "2026-01-01T00:00:00Z",
};

const DECLARED = {
  declared_entry_id: "44444444-4444-4444-8444-444444444444",
  role_label: "Chef",
  organisation_name: "A place with no account here",
  starts_at: "2024-01-01T00:00:00Z",
  ends_at: "2025-01-01T00:00:00Z",
  declared_at: "2026-07-01T00:00:00Z",
};

const CORRECTION = {
  correction_request_id: "55555555-5555-4555-8555-555555555555",
  entry_engagement_id: ENTRY.entry_engagement_id,
  venue_id: ENTRY.venue_id,
  body: "the dates are wrong",
  requested_at: "2026-07-02T00:00:00Z",
  resolved_at: null,
  resolution: null,
};

const DISCLOSURE = {
  disclosure_id: "66666666-6666-4666-8666-666666666666",
  engagement_id: ENTRY.entry_engagement_id,
  audience_kind: "venue",
  audience_id: "77777777-7777-4777-8777-777777777777",
  disclosed: false,
  decided_at: "2026-07-03T00:00:00Z",
};

/**
 * One payload short of a key.
 *
 * A helper rather than `const { [key]: _dropped, ...rest }` because the
 * discarded binding is an unused variable and this project's lint config has no
 * underscore exemption. That is the right setting, so the test bends rather
 * than the rule.
 */
function without(source: object, key: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(source).filter(([name]) => name !== key));
}

describe("decodeJoinedProfile", () => {
  it("reads the person and the standing notice", () => {
    expect(
      decodeJoinedProfile({
        person_id: "88888888-8888-4888-8888-888888888888",
        incompleteness_notice: "This record may be incomplete.",
      }),
    ).toEqual({
      personId: "88888888-8888-4888-8888-888888888888",
      incompletenessNotice: "This record may be incomplete.",
    });
  });

  it("refuses a join reply with no notice on it", () => {
    // The notice is required rather than optional because taking it from the
    // join is what makes `incompleteness_notice/0`'s arity zero structural on
    // this side: one string per session, which cannot vary per subject. A
    // decoder that shrugged at its absence would let a transport move it onto
    // the profile replies without anything noticing.
    expect(
      decodeJoinedProfile({ person_id: "88888888-8888-4888-8888-888888888888" }),
    ).toBe(null);
  });

  it("refuses anything that is not a record", () => {
    expect(decodeJoinedProfile(null)).toBe(null);
    expect(decodeJoinedProfile("joined")).toBe(null);
  });
});

describe("decodeAttestedEntry", () => {
  it("reads all eight fields", () => {
    expect(decodeAttestedEntry(ENTRY)).toEqual({
      attestedEntryId: ENTRY.attested_entry_id,
      entryEngagementId: ENTRY.entry_engagement_id,
      venueId: ENTRY.venue_id,
      venueName: ENTRY.venue_name,
      roleLabel: ENTRY.role_label,
      startsAt: ENTRY.starts_at,
      endsAt: ENTRY.ends_at,
      attestedAt: ENTRY.attested_at,
    });
  });

  it("refuses a row missing any one of them", () => {
    // `VisibleEntry` has `@enforce_keys` over all eight and types none as
    // nullable, so a row short of one is drift rather than an entry with a gap.
    for (const key of Object.keys(ENTRY)) {
      expect(decodeAttestedEntry(without(ENTRY, key))).toBe(null);
    }
  });
});

describe("decodeDeclaredEntry", () => {
  it("reads the rendered shape", () => {
    expect(decodeDeclaredEntry(DECLARED)).toEqual({
      declaredEntryId: DECLARED.declared_entry_id,
      roleLabel: DECLARED.role_label,
      organisationName: DECLARED.organisation_name,
      startsAt: DECLARED.starts_at,
      endsAt: DECLARED.ends_at,
      declaredAt: DECLARED.declared_at,
    });
  });

  it("refuses the schema's `id` in place of `declared_entry_id`", () => {
    // `DeclaredEntry` is an Ecto schema with no render struct, so `id` is what
    // a transport would put on the wire if it rendered the struct wholesale —
    // beside `attested_entry_id` and `correction_request_id` on the same
    // surface. Accepting both spellings is how one entity ends up with two key
    // names, which this project has now fixed twice. See `contract.ts`.
    expect(
      decodeDeclaredEntry({
        ...without(DECLARED, "declared_entry_id"),
        id: DECLARED.declared_entry_id,
      }),
    ).toBe(null);
  });
});

describe("decodeCorrectionRequest", () => {
  it("reads an outstanding request, which carries neither resolution field", () => {
    expect(decodeCorrectionRequest(CORRECTION)).toEqual({
      correctionRequestId: CORRECTION.correction_request_id,
      entryEngagementId: CORRECTION.entry_engagement_id,
      venueId: CORRECTION.venue_id,
      body: CORRECTION.body,
      requestedAt: CORRECTION.requested_at,
      resolvedAt: null,
      resolution: null,
    });
  });

  it("reads a resolved request, which carries both", () => {
    const resolved = decodeCorrectionRequest({
      ...CORRECTION,
      resolved_at: "2026-07-04T00:00:00Z",
      resolution: "declined",
    });

    expect(resolved?.resolvedAt).toBe("2026-07-04T00:00:00Z");
    expect(resolved?.resolution).toBe("declined");
  });

  it("refuses each of the two half-states the CHECK constraint forbids", () => {
    // `correction_requests_resolution_complete` pairs `resolved_at` and
    // `resolution` with `IS NULL` on both sides, so a row carrying one and not
    // the other cannot exist. Decoding them independently would accept an
    // instant saying the request was answered beside a `null` the surface
    // renders as "Waiting for an answer" — two claims, contradicting, from one
    // row. The constraint is on the far side of a transport this client cannot
    // see, so it is checked here rather than trusted.
    expect(
      decodeCorrectionRequest({ ...CORRECTION, resolved_at: "2026-07-04T00:00:00Z" }),
    ).toBe(null);

    expect(decodeCorrectionRequest({ ...CORRECTION, resolution: "accepted" })).toBe(null);
  });

  it("refuses a resolution this client has no case for", () => {
    expect(
      decodeCorrectionRequest({
        ...CORRECTION,
        resolved_at: "2026-07-04T00:00:00Z",
        resolution: "withdrawn",
      }),
    ).toBe(null);
  });
});

describe("decodeDisclosure", () => {
  it("reads the tagged audience", () => {
    expect(decodeDisclosure(DISCLOSURE)).toEqual({
      disclosureId: DISCLOSURE.disclosure_id,
      engagementId: DISCLOSURE.engagement_id,
      audienceKind: "venue",
      audienceId: DISCLOSURE.audience_id,
      disclosed: false,
      decidedAt: DISCLOSURE.decided_at,
    });
  });

  it("reads a person audience", () => {
    expect(
      decodeDisclosure({ ...DISCLOSURE, audience_kind: "person" })?.audienceKind,
    ).toBe("person");
  });

  it("refuses an audience kind that is neither", () => {
    expect(decodeDisclosure({ ...DISCLOSURE, audience_kind: "everybody" })).toBe(null);
  });

  it("refuses the table's two-column spelling", () => {
    // `audience_venue_id XOR audience_person_id` is how the row is stored and
    // is deliberately not how it travels: a wire shape spelled that way has to
    // be validated for "exactly one", and it would differ from the spelling
    // `set_disclosure` sends — one entity, two key names, again.
    const twoColumn = {
      ...without(without(DISCLOSURE, "audience_kind"), "audience_id"),
      audience_venue_id: DISCLOSURE.audience_id,
      audience_person_id: null,
    };

    expect(decodeDisclosure(twoColumn)).toBe(null);
  });

  it("refuses `disclosed` given as a string", () => {
    expect(decodeDisclosure({ ...DISCLOSURE, disclosed: "false" })).toBe(null);
  });
});

describe("decodeDisclosures", () => {
  it("reads the list", () => {
    expect(decodeDisclosures({ disclosures: [DISCLOSURE] })).toHaveLength(1);
    expect(decodeDisclosures({ disclosures: [] })).toEqual([]);
  });

  it("refuses the whole list when one row is bad", () => {
    // A list with one unreadable row is not a shorter list. On this surface
    // that matters more than most: a silently shortened ledger is a worker
    // being shown fewer decisions than they have taken.
    expect(
      decodeDisclosures({ disclosures: [DISCLOSURE, { ...DISCLOSURE, disclosed: 1 }] }),
    ).toBe(null);
  });
});

describe("decodeProfile", () => {
  const profile = {
    attested_entries: [ENTRY],
    declared_entries: [DECLARED],
    correction_requests: [CORRECTION],
  };

  it("reads the three lists", () => {
    const decoded = decodeProfile(profile);

    expect(decoded?.attestedEntries).toHaveLength(1);
    expect(decoded?.declaredEntries).toHaveLength(1);
    expect(decoded?.correctionRequests).toHaveLength(1);
  });

  it("reads a profile with nothing in it", () => {
    expect(
      decodeProfile({
        attested_entries: [],
        declared_entries: [],
        correction_requests: [],
      }),
    ).toEqual({ attestedEntries: [], declaredEntries: [], correctionRequests: [] });
  });

  it("refuses a reply missing one of the three lists", () => {
    for (const key of Object.keys(profile)) {
      expect(decodeProfile(without(profile, key))).toBe(null);
    }
  });

  it("carries nothing beyond the three lists, whatever the reply holds", () => {
    // The reply must never carry a count, a total, or a notice: a field whose
    // value depended on what had been withheld would be the oracle
    // `incompleteness_notice/0`'s arity exists to prevent, and it would be one
    // this client had asked for. Extra keys are ignored rather than refused —
    // this decoder cannot police a server — but nothing reaches the surface, so
    // no rendering can reach one either.
    const decoded = decodeProfile({
      ...profile,
      hidden_count: 3,
      incompleteness_notice: "this profile is hiding things",
    });

    expect(decoded === null ? [] : Object.keys(decoded).sort()).toEqual([
      "attestedEntries",
      "correctionRequests",
      "declaredEntries",
    ]);
  });
});

describe("the audiences a disclosure can name", () => {
  // `ProfileChannel`'s `"list_audiences"`, the eighth event and the only one
  // that does not call `HospitalityComs.Profiles`. Read out of
  // `rendered_venue/1` and `rendered_person/1` rather than assumed: a venue
  // listed **as itself** is `venue_id`/`name`, which is
  // `EmployerController.render_venue/1`'s spelling and the one every other
  // venue decoder in this client already reads, while `venue_name` is what a
  // venue named *inside another entity* is called. A person is `person_id`/
  // `display_name`, `rendered_peer/1`'s spelling for the same pair.
  //
  // **These keys are the one thing about this event no surface test can
  // check.** A surface fixture and a decoder both written here agree with each
  // other whatever they say — which is #66's client half exactly, where
  // `{displayName}` went out to a server reading `display_name` and killed
  // nothing. So they are asserted against literals, here, and nowhere else.
  const audiences = {
    venues: [{ venue_id: "66666666-6666-4666-8666-666666666666", name: "The Anchor" }],
    people: [
      { person_id: "77777777-7777-4777-8777-777777777777", display_name: "Captain Nemo" },
    ],
  };

  it("reads the two kinds `Disclosure.audience/0` has", () => {
    expect(decodeAudiences(audiences)).toEqual({
      venues: [{ venueId: "66666666-6666-4666-8666-666666666666", name: "The Anchor" }],
      people: [
        { personId: "77777777-7777-4777-8777-777777777777", displayName: "Captain Nemo" },
      ],
    });
  });

  it("answers both halves empty, which is a worker with nobody to name", () => {
    // Distinct from `null`, and the distinction is the whole of this event's
    // render logic: a picker cannot tell "still loading" from "there is nobody"
    // unless one of the two is not an empty pair. See `use-profile-surface.ts`.
    expect(decodeAudiences({ venues: [], people: [] })).toEqual({
      venues: [],
      people: [],
    });
  });

  it("refuses a reply carrying only one of the two lists", () => {
    // The absent half is the half the picker silently renders nothing for, and
    // a `?? []` here is how a one-sided transport ships as a working surface
    // with one group missing and nothing to say so.
    expect(decodeAudiences({ venues: audiences.venues })).toBeNull();
    expect(decodeAudiences({ people: audiences.people })).toBeNull();
    expect(decodeAudiences({})).toBeNull();
    expect(decodeAudiences(null)).toBeNull();
  });

  it("refuses the whole reply for one bad row, in either list", () => {
    // A list with one bad row is not a shorter list — every decoder in this
    // client shares the rule. It matters twice over here: a dropped row is an
    // audience the worker cannot name and has no way to notice is missing.
    expect(
      decodeAudiences({ ...audiences, venues: [...audiences.venues, { venue_id: "x" }] }),
    ).toBeNull();
    expect(
      decodeAudiences({
        ...audiences,
        people: [...audiences.people, { person_id: "x" }],
      }),
    ).toBeNull();
  });

  it("refuses a venue spelled `venue_name`, which is the other entity's key", () => {
    // The two spellings are one rename apart, and the wrong one renders an
    // option with an empty label rather than failing.
    expect(
      decodeAudiences({
        ...audiences,
        venues: [{ venue_id: "66666666-6666-4666-8666-666666666666", venue_name: "x" }],
      }),
    ).toBeNull();
  });
});
