import { describe, expect, it } from "vitest";

import { decodeJoinedEngagementId, decodeRoomClosure, decodeRoomMessage } from "./decode";

describe("a message", () => {
  it("reads what `RoomChannel.rendered/1` puts on the wire", () => {
    expect(
      decodeRoomMessage({
        id: "aaaaaaaa-0000-4000-8000-000000000001",
        body: "table four is ready",
        sent_at: "2026-07-28T09:00:00Z",
        author_engagement_id: "33333333-3333-4333-8333-333333333333",
      }),
    ).toEqual({
      id: "aaaaaaaa-0000-4000-8000-000000000001",
      body: "table four is ready",
      sentAt: "2026-07-28T09:00:00Z",
      authorEngagementId: "33333333-3333-4333-8333-333333333333",
    });
  });

  it("answers null for anything missing a field, rather than a partial message", () => {
    const complete: Record<string, string> = {
      id: "a",
      body: "b",
      sent_at: "c",
      author_engagement_id: "d",
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
