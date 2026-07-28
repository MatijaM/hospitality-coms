import { describe, expect, it } from "vitest";

import { PROFILE_EVENTS, PROFILE_TOPIC_PREFIX } from "./contract";
import type { AttestedEntry, Disclosure } from "./profile";
import {
  decisionsFor,
  disclosureState,
  disclosureStateLabel,
  normalisePersonId,
  profileTopic,
  resolutionLabel,
  resolutionMessage,
  shortId,
} from "./profile";

const ENGAGEMENT_ID = "22222222-2222-4222-8222-222222222222";
const OTHER_ENGAGEMENT_ID = "99999999-9999-4999-8999-999999999999";
const VENUE_ID = "33333333-3333-4333-8333-333333333333";
const PERSON_ID = "77777777-7777-4777-8777-777777777777";

const ENTRY: AttestedEntry = {
  attestedEntryId: "11111111-1111-4111-8111-111111111111",
  entryEngagementId: ENGAGEMENT_ID,
  venueId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  venueName: "The Anchor",
  roleLabel: "Bartender",
  startsAt: "2026-01-01T00:00:00Z",
  endsAt: "2026-06-01T00:00:00Z",
  attestedAt: "2026-01-01T00:00:00Z",
};

function disclosure(overrides: Partial<Disclosure> = {}): Disclosure {
  return {
    disclosureId: "66666666-6666-4666-8666-666666666666",
    engagementId: ENGAGEMENT_ID,
    audienceKind: "venue",
    audienceId: VENUE_ID,
    disclosed: false,
    decidedAt: "2026-07-03T00:00:00Z",
    ...overrides,
  };
}

describe("profileTopic", () => {
  it("is the prefix and the person", () => {
    expect(profileTopic(PERSON_ID)).toBe(`${PROFILE_TOPIC_PREFIX}${PERSON_ID}`);
  });
});

describe("normalisePersonId", () => {
  it("lowercases and trims", () => {
    expect(normalisePersonId(`  ${PERSON_ID.toUpperCase()}  `)).toBe(PERSON_ID);
  });

  it("refuses anything that is not a uuid", () => {
    expect(normalisePersonId("not-an-id")).toBe(null);
    expect(normalisePersonId("")).toBe(null);
  });
});

describe("PROFILE_EVENTS", () => {
  it("collides with none of PeerChannel's nine", () => {
    // `contract.ts` says putting these on `PeerChannel` instead is a one-
    // constant change here, and that claim is only true while the names are
    // disjoint. `PeerChannel`'s nine, read out of the module.
    const peerEvents = [
      "list_peers",
      "list_conversations",
      "list_requests",
      "request",
      "accept",
      "decline",
      "history",
      "send",
      "disconnect",
    ];

    for (const event of Object.values(PROFILE_EVENTS)) {
      expect(peerEvents).not.toContain(event);
    }
  });
});

describe("disclosureState", () => {
  it("is `shown` where the worker said yes", () => {
    expect(
      disclosureState([disclosure({ disclosed: true })], ENTRY, "venue", VENUE_ID),
    ).toBe("shown");
  });

  it("is `hidden` where the worker said no", () => {
    expect(
      disclosureState([disclosure({ disclosed: false })], ENTRY, "venue", VENUE_ID),
    ).toBe("hidden");
  });

  it("is `default` where there is no row, and never `shown`", () => {
    // The ledger holds overrides only. Both defaults are computed server-side
    // from stored periods and are on no wire this client reads, so the absence
    // of a row means "you have not decided", which is a different claim from
    // "they can see it".
    //
    // Answering `shown` here would be actively wrong rather than merely
    // optimistic: the employer default *hides* an entry whose term overlapped
    // one of the reader's, so the reassuring answer tells a worker their second
    // job is disclosed to the venue it is in fact concealed from.
    expect(disclosureState([], ENTRY, "venue", VENUE_ID)).toBe("default");
  });

  it("does not read one audience's decision as another's", () => {
    const decided = [disclosure({ disclosed: true })];

    expect(disclosureState(decided, ENTRY, "person", VENUE_ID)).toBe("default");
    expect(disclosureState(decided, ENTRY, "venue", PERSON_ID)).toBe("default");
  });

  it("does not read one entry's decision as another's", () => {
    const other: AttestedEntry = { ...ENTRY, entryEngagementId: OTHER_ENGAGEMENT_ID };

    expect(
      disclosureState([disclosure({ disclosed: true })], other, "venue", VENUE_ID),
    ).toBe("default");
  });
});

describe("decisionsFor", () => {
  it("keeps only the entry's own", () => {
    const mine = disclosure();
    const theirs = disclosure({
      disclosureId: "aaaaaaaa-1111-4111-8111-111111111111",
      engagementId: OTHER_ENGAGEMENT_ID,
    });

    expect(decisionsFor([mine, theirs], ENTRY)).toEqual([mine]);
  });
});

describe("labels", () => {
  it("never calls an undecided audience shown", () => {
    expect(disclosureStateLabel("default")).toBe("Not decided");
    expect(disclosureStateLabel("shown")).toBe("Shown");
    expect(disclosureStateLabel("hidden")).toBe("Hidden");
  });

  it("says an outstanding correction is outstanding", () => {
    expect(resolutionLabel(null)).toBe("Waiting for an answer");
  });

  it("says an accepted correction changed no entry", () => {
    // `resolve_correction/3` writes no entry and cannot — an attested entry
    // derives from its engagement. A worker told only "Accepted" beside an
    // entry that still reads the same way would reasonably think the system had
    // failed them.
    expect(resolutionMessage("accepted")).toContain("not an edit");
  });

  it("says a declined correction stays readable", () => {
    expect(resolutionMessage("declined")).toContain("stay readable");
  });
});

describe("shortId", () => {
  it("is the first eight characters", () => {
    expect(shortId(PERSON_ID)).toBe("77777777");
  });
});
