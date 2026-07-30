import { describe, expect, it } from "vitest";

import {
  decodeJoinedEngagementId,
  decodeMessagePage,
  decodeRoomClosure,
  decodeRoomMessage,
  decodeShiftRooms,
  decodeVenueRooms,
} from "./decode";

describe("a message", () => {
  it("reads what `RoomChannel.rendered/1` puts on the wire", () => {
    expect(
      decodeRoomMessage({
        id: "aaaaaaaa-0000-4000-8000-000000000001",
        body: "table four is ready",
        sent_at: "2026-07-28T09:00:00Z",
        author_engagement_id: "33333333-3333-4333-8333-333333333333",
        author_display_name: "Captain Nemo",
        author_role_label: "Head Chef",
      }),
    ).toEqual({
      id: "aaaaaaaa-0000-4000-8000-000000000001",
      body: "table four is ready",
      sentAt: "2026-07-28T09:00:00Z",
      authorEngagementId: "33333333-3333-4333-8333-333333333333",
      authorDisplayName: "Captain Nemo",
      authorRoleLabel: "Head Chef",
    });
  });

  it("answers null for anything missing a field, rather than a partial message", () => {
    const complete: Record<string, string> = {
      id: "a",
      body: "b",
      sent_at: "c",
      author_engagement_id: "d",
      author_display_name: "e",
      author_role_label: "f",
    };

    for (const missing of Object.keys(complete)) {
      const partial = Object.fromEntries(
        Object.entries(complete).filter(([key]) => key !== missing),
      );

      expect(decodeRoomMessage(partial)).toBeNull();
    }

    expect(decodeRoomMessage({ ...complete, body: 7 })).toBeNull();
    expect(decodeRoomMessage(null)).toBeNull();
    expect(decodeRoomMessage([])).toBeNull();
  });

  it("does not turn `sent_at` into a Date", () => {
    // The instant is the server's. Parsing it here invites this client to
    // compute with it, which is `HospitalityComs.Clock`'s job on the other
    // side and the one thing KTD5 says a long-lived process must not do for
    // itself.
    const message = decodeRoomMessage({
      id: "a",
      body: "b",
      sent_at: "2026-07-28T09:00:00Z",
      author_engagement_id: "d",
      author_display_name: "e",
      author_role_label: "f",
    });

    expect(message?.sentAt).toBe("2026-07-28T09:00:00Z");
  });
});

describe("a join reply", () => {
  it("takes the engagement id, which both replies carry", () => {
    expect(decodeJoinedEngagementId({ venue_id: "v", engagement_id: "e" })).toBe("e");
    expect(decodeJoinedEngagementId({ shift_room_id: "s", engagement_id: "e" })).toBe(
      "e",
    );
  });

  it("answers null rather than guessing when it is absent", () => {
    expect(decodeJoinedEngagementId({ venue_id: "v" })).toBeNull();
    expect(decodeJoinedEngagementId(null)).toBeNull();
  });
});

describe("a terminal notice", () => {
  it("reads what `RoomChannel.closed/4` merges and pushes", () => {
    expect(
      decodeRoomClosure("revoked", {
        venue_id: "11111111-1111-4111-8111-111111111111",
        engagement_id: "33333333-3333-4333-8333-333333333333",
        at: "2026-07-28T09:00:00Z",
      }),
    ).toEqual({
      reason: "revoked",
      engagementId: "33333333-3333-4333-8333-333333333333",
      at: "2026-07-28T09:00:00Z",
    });
  });

  it("takes the reason from the event name, because the payload does not carry one", () => {
    // `"access_revoked"` and `"access_suspended"` differ in the event and in
    // nothing else — they mean opposite things to a reader, which is why the
    // server tells them apart that way (KTD18).
    const payload = { shift_room_id: "s", engagement_id: "e", at: "t" };

    expect(decodeRoomClosure("suspended", payload)?.reason).toBe("suspended");
    expect(decodeRoomClosure("revoked", payload)?.reason).toBe("revoked");
  });

  it("answers null for a payload it was not promised", () => {
    expect(decodeRoomClosure("revoked", { engagement_id: "e" })).toBeNull();
    expect(decodeRoomClosure("revoked", { at: "t" })).toBeNull();
    expect(decodeRoomClosure("revoked", "gone")).toBeNull();
  });
});

describe("the venue-room list", () => {
  it("reads what `GET /api/venue-rooms` renders", () => {
    expect(
      decodeVenueRooms({
        venue_rooms: [
          { venue_id: "11111111-1111-4111-8111-111111111111", name: "The Anchor" },
        ],
      }),
    ).toEqual([{ venueId: "11111111-1111-4111-8111-111111111111", name: "The Anchor" }]);
  });

  it("refuses a body missing the name, because the name is the whole point", () => {
    // A list of venue rooms without names is the uuid list this endpoint
    // exists to replace, and silently rendering one would be worse than a
    // failure: it would look like the feature working.
    expect(
      decodeVenueRooms({
        venue_rooms: [{ venue_id: "11111111-1111-4111-8111-111111111111" }],
      }),
    ).toBeNull();
  });

  it("fails the whole body for one bad entry rather than dropping it", () => {
    // A list silently one entry short is a room somebody cannot find, with no
    // sentence anywhere saying why.
    expect(
      decodeVenueRooms({
        venue_rooms: [
          { venue_id: "11111111-1111-4111-8111-111111111111", name: "The Anchor" },
          { venue_id: 7, name: "The Ship" },
        ],
      }),
    ).toBeNull();

    expect(decodeVenueRooms({ venue_rooms: {} })).toBeNull();
    expect(decodeVenueRooms(null)).toBeNull();
  });
});

describe("the shift-room list", () => {
  const listed = {
    shift_room_id: "22222222-2222-4222-8222-222222222222",
    venue_id: "11111111-1111-4111-8111-111111111111",
    shift_type_name: "Kitchen",
    starts_at: "2026-03-09T13:00:00Z",
    ends_at: "2026-03-09T21:00:00Z",
    closes_at: "2026-03-09T21:30:00Z",
  };

  it("reads what `GET /api/venues/:venue_id/shift-rooms` renders", () => {
    expect(decodeShiftRooms({ shift_rooms: [listed] })).toEqual([
      {
        shiftRoomId: "22222222-2222-4222-8222-222222222222",
        venueId: "11111111-1111-4111-8111-111111111111",
        shiftTypeName: "Kitchen",
        startsAt: "2026-03-09T13:00:00Z",
        endsAt: "2026-03-09T21:00:00Z",
        closesAt: "2026-03-09T21:30:00Z",
      },
    ]);
  });

  it("requires every field, including the name a label is built from", () => {
    for (const missing of Object.keys(listed)) {
      const partial = Object.fromEntries(
        Object.entries(listed).filter(([key]) => key !== missing),
      );

      expect(decodeShiftRooms({ shift_rooms: [partial] })).toBeNull();
    }
  });
});

describe("a page of history", () => {
  const message = {
    id: "aaaaaaaa-0000-4000-8000-000000000001",
    body: "table four is ready",
    sent_at: "2026-07-28T09:00:00Z",
    author_engagement_id: "33333333-3333-4333-8333-333333333333",
    author_display_name: "Captain Nemo",
    author_role_label: "Head Chef",
  };

  it("reads the messages and whether they are the whole history", () => {
    expect(decodeMessagePage({ messages: [message], complete: false })).toEqual({
      messages: [
        {
          id: "aaaaaaaa-0000-4000-8000-000000000001",
          body: "table four is ready",
          sentAt: "2026-07-28T09:00:00Z",
          authorEngagementId: "33333333-3333-4333-8333-333333333333",
          authorDisplayName: "Captain Nemo",
          authorRoleLabel: "Head Chef",
        },
      ],
      complete: false,
    });
  });

  it("refuses a body with no `complete`, rather than assuming there is no more", () => {
    // Defaulting it to `true` would make the bound invisible to whoever is
    // looking at the screen: the "load the whole history" control would never
    // appear and nothing would say why.
    expect(decodeMessagePage({ messages: [message] })).toBeNull();
    expect(decodeMessagePage({ messages: [message], complete: "false" })).toBeNull();
  });

  it("accepts an empty room", () => {
    expect(decodeMessagePage({ messages: [], complete: true })).toEqual({
      messages: [],
      complete: true,
    });
  });
});
