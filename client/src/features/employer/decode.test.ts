/**
 * The employer bodies, decoded — and the client's half of R18.
 *
 * The server pins its rendered key sets three ways and every one of them fails
 * when the **server** starts sending a field it should not. This file is the
 * one that holds when they do not: a `person_id` that reaches this client must
 * reach nothing past the decoder, whether it arrived because somebody widened a
 * render, because a proxy merged something in, or because this client was
 * pointed at a different build.
 *
 * So the key set is asserted against a **literal written out here**, not
 * against `Object.keys` of another object built by the same code — comparing
 * the two sides of one implementation is the shape
 * `docs/solutions/test-failures/tests-that-certify-nothing.md` calls a control
 * that cannot control, and this project has now shipped five of them.
 */

import { describe, expect, it } from "vitest";

import {
  decodeCreatedRosterEntry,
  decodeCreatedShiftRoom,
  decodeIssuedOffer,
  decodeManagedVenue,
  decodeManagedVenues,
  decodeOfferedInvitation,
  decodeRoster,
  decodeRosterEntry,
  decodeShiftRoomPage,
  decodeShiftType,
  decodeShiftTypes,
  decodeVenueEngagement,
  decodeVenueEngagements,
} from "./decode";

/** `render_engagement/1`'s four keys, in this client's spelling. */
const ENGAGEMENT_KEYS = ["endsAt", "engagementId", "roleLabel", "startsAt"];

/** `render_shift_type/1`. */
const SHIFT_TYPE = {
  shift_type_id: "55555555-5555-4555-8555-555555555551",
  name: "Close",
  grace_period_minutes: 30,
};

/** `render_roster_entry/1`, off a preloaded engagement. */
const ROSTER_ENTRY = {
  engagement_id: "33333333-3333-4333-8333-333333333333",
  role_label: "Runner",
  joined_at: "2026-03-09T18:00:00Z",
};

/** `RoomController.rendered_shift_room/1`, which both sides of this API use. */
function shiftRoomBody(typeName: string, startsAt: string) {
  return {
    shift_room_id: `66666666-6666-4666-8666-6666666666${typeName.length}1`,
    venue_id: "11111111-1111-4111-8111-111111111111",
    shift_type_name: typeName,
    starts_at: startsAt,
    ends_at: "2026-03-10T05:00:00Z",
    closes_at: "2026-03-10T05:30:00Z",
  };
}

const ENGAGEMENT = {
  engagement_id: "33333333-3333-4333-8333-333333333333",
  role_label: "Runner",
  starts_at: "2026-03-09T13:00:00Z",
  ends_at: "2026-06-07T13:00:00Z",
};

const INVITATION = {
  invitation_id: "44444444-4444-4444-8444-444444444444",
  role_label: "Runner",
  starts_at: "2026-03-09T13:00:00Z",
  ends_at: "2026-06-07T13:00:00Z",
  code_expires_at: "2026-03-16T13:00:00Z",
};

describe("a venue this session may act for", () => {
  it("takes the venue_id and name the route renders", () => {
    expect(
      decodeManagedVenue({
        venue_id: "11111111-1111-4111-8111-111111111111",
        name: "Harbour Tavern",
      }),
    ).toEqual({
      venueId: "11111111-1111-4111-8111-111111111111",
      name: "Harbour Tavern",
    });
  });

  it("refuses an entry with no name rather than rendering an unnamed button", () => {
    expect(
      decodeManagedVenue({ venue_id: "11111111-1111-4111-8111-111111111111" }),
    ).toBeNull();
  });

  it("fails the whole list when one entry does not decode", () => {
    // All-or-nothing rather than filtering: a picker silently one venue short
    // is a manager who cannot reach their own venue, with no sentence anywhere
    // saying why. The caller reports `malformed_response` instead.
    expect(
      decodeManagedVenues({
        venues: [
          { venue_id: "11111111-1111-4111-8111-111111111111", name: "Harbour Tavern" },
          { venue_id: "22222222-2222-4222-8222-222222222222" },
        ],
      }),
    ).toBeNull();
  });

  it("reads an empty list as an empty list, not as an absence", () => {
    // AE10 rests on this: no venues is an answer, and it has to survive the
    // decoder as one rather than becoming `malformed_response`.
    expect(decodeManagedVenues({ venues: [] })).toEqual([]);
  });
});

describe("one of a venue's people", () => {
  it("has exactly the four keys the route renders", () => {
    const decoded = decodeVenueEngagement(ENGAGEMENT);

    expect(decoded).toEqual({
      engagementId: "33333333-3333-4333-8333-333333333333",
      roleLabel: "Runner",
      startsAt: "2026-03-09T13:00:00Z",
      endsAt: "2026-06-07T13:00:00Z",
    });
    expect(Object.keys(decoded ?? {}).sort()).toEqual(ENGAGEMENT_KEYS);
  });

  it("decodes a payload carrying person_id without it", () => {
    // The client twin of the server's redaction pin. `Engagement` carries
    // `person_id` — the globally stable cross-venue key two venues could
    // compare out of band — and `render_engagement/1` withholds it. This is
    // what holds if that ever stops being true: the decoder names its fields
    // one at a time rather than spreading the payload, so the key arrives and
    // goes no further.
    const decoded = decodeVenueEngagement({
      ...ENGAGEMENT,
      person_id: "99999999-9999-4999-8999-999999999999",
      email: "runner@example.com",
    });

    expect(Object.keys(decoded ?? {}).sort()).toEqual(ENGAGEMENT_KEYS);
    expect(JSON.stringify(decoded)).not.toContain("99999999-9999-4999-8999-999999999999");
    expect(JSON.stringify(decoded)).not.toContain("runner@example.com");
  });

  it("refuses an entry missing the role label", () => {
    expect(
      decodeVenueEngagement({
        engagement_id: ENGAGEMENT.engagement_id,
        starts_at: ENGAGEMENT.starts_at,
        ends_at: ENGAGEMENT.ends_at,
      }),
    ).toBeNull();
  });

  it("refuses an entry whose term is not two strings", () => {
    expect(decodeVenueEngagement({ ...ENGAGEMENT, ends_at: 1_772_000_000 })).toBeNull();
  });

  it("fails the whole list when one entry does not decode", () => {
    expect(
      decodeVenueEngagements({ engagements: [ENGAGEMENT, { engagement_id: "x" }] }),
    ).toBeNull();
  });

  it("reads the list off the engagements key and nowhere else", () => {
    expect(decodeVenueEngagements({ engagements: [ENGAGEMENT] })).toHaveLength(1);
    expect(decodeVenueEngagements({ people: [ENGAGEMENT] })).toBeNull();
  });
});

describe("an issued offer", () => {
  it("carries the invitation and the plaintext code beside it", () => {
    expect(decodeIssuedOffer({ invitation: INVITATION, claim_code: "aGFuZGVk" })).toEqual(
      {
        invitation: {
          invitationId: "44444444-4444-4444-8444-444444444444",
          roleLabel: "Runner",
          startsAt: "2026-03-09T13:00:00Z",
          endsAt: "2026-06-07T13:00:00Z",
          codeExpiresAt: "2026-03-16T13:00:00Z",
        },
        claimCode: "aGFuZGVk",
      },
    );
  });

  it("keeps no claim_code_digest, whatever the response carries", () => {
    // `employer_role` holds table-level SELECT on `invitations`, so the digest
    // comes back with every row server-side and `render_invitation/1` is what
    // withholds it. This is the same guard one layer out: the digest is not a
    // working credential, but a page that rendered a struct wholesale would
    // ship it, and a decoder that spread the payload would hand it one.
    const decoded = decodeOfferedInvitation({
      ...INVITATION,
      claim_code_digest: "3d2f1e0c9b8a7654",
    });

    expect(Object.keys(decoded ?? {}).sort()).toEqual([
      "codeExpiresAt",
      "endsAt",
      "invitationId",
      "roleLabel",
      "startsAt",
    ]);
    expect(JSON.stringify(decoded)).not.toContain("3d2f1e0c9b8a7654");
  });

  it("refuses a 201 with no claim code rather than showing an empty panel", () => {
    // The one field in this response that cannot be asked for again. Defaulting
    // it would put a successful-looking panel on screen with nothing to copy,
    // against an invitation that has already been written.
    expect(decodeIssuedOffer({ invitation: INVITATION })).toBeNull();
  });

  it("refuses a 201 whose invitation does not decode", () => {
    expect(
      decodeIssuedOffer({ invitation: { invitation_id: "x" }, claim_code: "aGFuZGVk" }),
    ).toBeNull();
  });
});

describe("a shift type", () => {
  it("takes exactly the three keys the route renders", () => {
    expect(decodeShiftType(SHIFT_TYPE)).toEqual({
      shiftTypeId: "55555555-5555-4555-8555-555555555551",
      name: "Close",
      gracePeriodMinutes: 30,
    });
  });

  // **The control, and it is the shape this project keeps re-learning.** A
  // grace of zero is a real configuration — the picker has to offer it — and it
  // is the value a `!value` guard silently refuses while every fixture with a
  // non-zero grace passes. `tests-that-certify-nothing.md` calls this "a
  // fixture that made the operation under test the identity".
  it("decodes a grace of zero rather than reading it as an absence", () => {
    expect(decodeShiftType({ ...SHIFT_TYPE, grace_period_minutes: 0 })).toEqual({
      shiftTypeId: "55555555-5555-4555-8555-555555555551",
      name: "Close",
      gracePeriodMinutes: 0,
    });
  });

  it("refuses an entry missing any of the three", () => {
    expect(decodeShiftType({ ...SHIFT_TYPE, name: undefined })).toBeNull();
    expect(decodeShiftType({ ...SHIFT_TYPE, grace_period_minutes: "30" })).toBeNull();
    expect(decodeShiftType({ ...SHIFT_TYPE, shift_type_id: 55 })).toBeNull();
  });

  it("fails the whole list when one entry does not decode", () => {
    // A picker silently one type short is a shift a manager cannot create, with
    // no sentence anywhere saying why.
    expect(decodeShiftTypes({ shift_types: [SHIFT_TYPE, { name: "Day" }] })).toBeNull();
  });

  it("reads the list off the shift_types key and nowhere else", () => {
    expect(decodeShiftTypes({ types: [SHIFT_TYPE] })).toBeNull();
    expect(decodeShiftTypes({ shift_types: [] })).toEqual([]);
  });
});

describe("a page of the venue's shift rooms", () => {
  it("carries the rooms and the server's own completeness flag", () => {
    const page = decodeShiftRoomPage({
      shift_rooms: [shiftRoomBody("Close", "2026-03-09T21:00:00Z")],
      complete: false,
    });

    expect(page?.complete).toBe(false);
    expect(page?.rooms.map((room) => room.shiftTypeName)).toEqual(["Close"]);
  });

  // `complete` is the whole of what this client knows about the bound. A full
  // page and a full history of the same length are the same list, so a default
  // of `true` silently means "this is everything" and the bound stops being
  // visible to anybody looking at the screen.
  it("requires complete rather than defaulting it", () => {
    expect(decodeShiftRoomPage({ shift_rooms: [] })).toBeNull();
    expect(decodeShiftRoomPage({ shift_rooms: [], complete: "yes" })).toBeNull();
  });

  // The hoist's own assertion from this side: the page's rooms go through
  // `src/app/shift-room.ts`'s decoder, which is the same one the person-side
  // shift-room list uses, because `RoomController.rendered_shift_room/1` is one
  // render function for both.
  it("fails the whole page when a room is missing its type's name", () => {
    const { shift_type_name: _dropped, ...nameless } = shiftRoomBody(
      "Close",
      "2026-03-09T21:00:00Z",
    );

    expect(decodeShiftRoomPage({ shift_rooms: [nameless], complete: true })).toBeNull();
  });

  it("reads a created room off the shift_room key and nowhere else", () => {
    const room = shiftRoomBody("Close", "2026-03-09T21:00:00Z");

    expect(decodeCreatedShiftRoom({ shift_room: room })?.shiftTypeName).toBe("Close");
    expect(decodeCreatedShiftRoom({ room })).toBeNull();
  });
});

describe("a roster entry", () => {
  it("has exactly the three keys the route renders, and drops a person id", () => {
    // `render_roster_entry/1` reads a field list off a **preloaded**
    // `Engagement`, so the struct carrying `person_id` — the globally stable
    // cross-venue key — is one field access from that render. The fixture sends
    // one, because a payload without one makes this pass for the wrong reason.
    const decoded = decodeRosterEntry({
      ...ROSTER_ENTRY,
      person_id: "99999999-9999-4999-8999-999999999999",
    });

    expect(decoded).toEqual({
      engagementId: "33333333-3333-4333-8333-333333333333",
      roleLabel: "Runner",
      joinedAt: "2026-03-09T18:00:00Z",
    });
    expect(JSON.stringify(decoded)).not.toContain(
      "99999999-9999-4999-8999-999999999999",
    );
  });

  // R13 says each entry names the engagement **and the role label**. An
  // optional label renders a blank row for exactly the entry KTD-E10 is about —
  // a starter whose term has not opened, who is absent from the people list and
  // therefore unnameable from anywhere else.
  it("refuses an entry with no role label", () => {
    const { role_label: _dropped, ...unlabelled } = ROSTER_ENTRY;

    expect(decodeRosterEntry(unlabelled)).toBeNull();
  });

  it("reads the roster off the roster key and a created entry off roster_entry", () => {
    expect(decodeRoster({ roster: [ROSTER_ENTRY] })).toHaveLength(1);
    expect(decodeRoster({ entries: [ROSTER_ENTRY] })).toBeNull();
    expect(decodeCreatedRosterEntry({ roster_entry: ROSTER_ENTRY })?.roleLabel).toBe(
      "Runner",
    );
    expect(decodeCreatedRosterEntry({ entry: ROSTER_ENTRY })).toBeNull();
  });

  it("fails the whole roster when one entry does not decode", () => {
    expect(decodeRoster({ roster: [ROSTER_ENTRY, { role_label: "Chef" }] })).toBeNull();
  });
});
