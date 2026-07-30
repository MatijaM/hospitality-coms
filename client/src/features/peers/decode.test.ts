/**
 * Every payload in this file is the shape
 * `lib/hospitality_coms_web/channels/peer_channel.ex` actually renders, read
 * out of `rendered_peer/1`, `rendered_request/1`, `rendered_conversation/1`,
 * `rendered_message/1` and the five `handle_info/2` clauses rather than assumed.
 * Two of the key sets are pinned on the other side by `peer_channel_test.exs`.
 */

import { describe, expect, it } from "vitest";

import {
  decodeConversation,
  decodeConversations,
  decodeJoinedPersonId,
  decodePeer,
  decodePeerMessage,
  decodePeerMessages,
  decodePeerRequest,
  decodePeerRequests,
  decodePeers,
} from "./decode";

const PERSON = "8b1b0a3c-0000-4000-8000-000000000001";
const OTHER = "8b1b0a3c-0000-4000-8000-000000000002";
const CONNECTION = "8b1b0a3c-0000-4000-8000-00000000000c";
const REQUEST = "8b1b0a3c-0000-4000-8000-00000000000b";
const MESSAGE = "8b1b0a3c-0000-4000-8000-00000000000d";

/** The same record with one key absent, which is what drift looks like. */
function without(wire: Record<string, unknown>, key: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(wire).filter(([name]) => name !== key));
}

describe("the join reply", () => {
  it("is the person this channel multiplexes for", () => {
    expect(decodeJoinedPersonId({ person_id: PERSON })).toBe(PERSON);
    expect(decodeJoinedPersonId({ personId: PERSON })).toBeNull();
    expect(decodeJoinedPersonId(null)).toBeNull();
  });
});

describe("a peer", () => {
  const wire = {
    person_id: OTHER,
    display_name: "Captain Nemo",
    venue_id: "8b1b0a3c-0000-4000-8000-00000000000e",
    venue_name: "The Anchor",
    role_label: "Bartender",
    visible_from: "2026-07-01T00:00:00Z",
    visible_until: "2026-09-01T00:00:00Z",
  };

  it("carries the venue and the employer-authored role, and no address", () => {
    // What `list_visible_peers/1` selects is exactly what the venue room's roll
    // already discloses. There is no email on this wire and there will not be
    // one — `peers_test.exs` asserts its absence on the other side.
    expect(decodePeer(wire)).toEqual({
      personId: OTHER,
      displayName: "Captain Nemo",
      venueId: wire.venue_id,
      venueName: "The Anchor",
      roleLabel: "Bartender",
      visibleFrom: wire.visible_from,
      visibleUntil: wire.visible_until,
    });
  });

  it("is nothing at all when a field this client renders is missing", () => {
    // A renamed field has to surface as a named absence, not as `undefined`
    // where a venue name should be.
    for (const key of Object.keys(wire)) {
      expect(decodePeer(without(wire, key))).toBeNull();
    }
  });

  it("reads the list, and a list with one bad row is not a shorter list", () => {
    expect(decodePeers({ peers: [wire] })).toHaveLength(1);
    expect(decodePeers({ peers: [] })).toEqual([]);
    expect(decodePeers({ peers: [wire, { person_id: OTHER }] })).toBeNull();
    expect(decodePeers({ peers: "none" })).toBeNull();
  });
});

describe("a request", () => {
  const wire = {
    request_id: REQUEST,
    requester_id: PERSON,
    // The two names are deliberately unequal, and neither is a substring of the
    // other. `rendered_request/1` serves four call sites and takes no viewer,
    // so it sends **both** names rather than one viewer-relative counterpart —
    // which means the one way this decoder can be wrong and still look right is
    // to put each name on the other party. A fixture naming both parties
    // "Captain Nemo" is invariant under exactly that mutation.
    requester_display_name: "Captain Nemo",
    addressee_id: OTHER,
    addressee_display_name: "Allan Quatermain",
    state: "pending",
    requested_at: "2026-07-28T09:00:00Z",
    accepted_at: null,
    declined_at: null,
  };

  it("carries the state and the instant that state became true", () => {
    // `state` is the claim and `accepted_at`/`declined_at` are when it became
    // true. A surface rendering "declined" has nothing to render it *as of*
    // without them, which is why U8's review added them.
    expect(
      decodePeerRequest({
        ...wire,
        state: "declined",
        declined_at: "2026-07-28T10:00:00Z",
      }),
    ).toEqual({
      requestId: REQUEST,
      requesterId: PERSON,
      requesterDisplayName: "Captain Nemo",
      addresseeId: OTHER,
      addresseeDisplayName: "Allan Quatermain",
      state: "declined",
      requestedAt: wire.requested_at,
      acceptedAt: null,
      declinedAt: "2026-07-28T10:00:00Z",
    });
  });

  it("puts each name on its own party, which is the only way this can be subtly wrong", () => {
    // Read as a pair with the assertion above rather than as a repeat of it.
    // That one would survive both names being read off `requester_display_name`
    // if the two literals were equal; this one names the sides explicitly and
    // is the row the swap mutation is measured against.
    const decoded = decodePeerRequest(wire);

    expect(decoded?.requesterDisplayName).toBe("Captain Nemo");
    expect(decoded?.addresseeDisplayName).toBe("Allan Quatermain");
    expect(decoded?.requesterDisplayName).not.toBe(decoded?.addresseeDisplayName);
  });

  it("is nothing at all when either name is missing", () => {
    // #73 put both on the wire and every `rendered_request/1` heads on
    // `is_binary/1` for both, so there is no request the server can produce
    // without them. A fallback here would only ever mask a server that drifted
    // — and would put `undefined` in the heading of somebody's inbox.
    for (const key of Object.keys(wire)) {
      expect(decodePeerRequest(without(wire, key))).toBeNull();
    }
  });

  it("refuses a state this client has no case for", () => {
    // Everything the surface renders about a request switches on `state`, and
    // the switches are exhaustive. A fifth value arriving as a string would
    // fall out of every one of them with nothing to render; as a decode failure
    // it is a named absence instead.
    expect(decodePeerRequest({ ...wire, state: "withdrawn" })).toBeNull();
    expect(decodePeerRequest({ ...wire, state: null })).toBeNull();
  });

  it("takes null for the two instants and nothing else", () => {
    expect(decodePeerRequest({ ...wire, accepted_at: 0 })).toBeNull();
  });

  it("reads the two lists, which are not the same query", () => {
    // `list_incoming_requests/1` is only what the addressee can still answer;
    // `list_outgoing_requests/1` carries every unsuperseded approach, answered
    // or not. So an outgoing list holds `declined` entries and an incoming one
    // does not, and both have to decode.
    expect(decodePeerRequests({ incoming: [wire], outgoing: [] })).toEqual({
      incoming: [expect.objectContaining({ requestId: REQUEST })],
      outgoing: [],
    });
    expect(decodePeerRequests({ incoming: [wire] })).toBeNull();
  });
});

describe("a conversation", () => {
  const wire = {
    connection_id: CONNECTION,
    peer_id: OTHER,
    peer_display_name: "Captain Nemo",
    connected_at: "2026-07-28T09:00:00Z",
    disconnected_at: null,
    disconnected_by_id: null,
    open: true,
  };

  it("names the counterpart, resolved server-side out of the canonical pair", () => {
    expect(decodeConversation(wire)).toEqual({
      connectionId: CONNECTION,
      peerId: OTHER,
      peerDisplayName: "Captain Nemo",
      connectedAt: wire.connected_at,
      disconnectedAt: null,
      disconnectedById: null,
      open: true,
    });
  });

  it("is nothing at all when the counterpart has no name", () => {
    // `Records.with_pair/1` has no activeness predicate and no `erased_at`
    // filter, so a conversation always has a name to carry: a closed one, one
    // whose counterpart left the trade, and one whose counterpart was erased —
    // the last reading `Lifecycle.erased_display_name/0` — all arrive with a
    // string. There is no state this fallback would serve.
    expect(decodeConversation(without(wire, "peer_display_name"))).toBeNull();
    expect(decodeConversation({ ...wire, peer_display_name: null })).toBeNull();
  });

  it("carries who closed it, so the two sides can read differently", () => {
    expect(
      decodeConversation({
        ...wire,
        disconnected_at: "2026-07-28T11:00:00Z",
        disconnected_by_id: PERSON,
        open: false,
      }),
    ).toEqual(expect.objectContaining({ open: false, disconnectedById: PERSON }));
  });

  it("requires `open` to be a boolean rather than truthy", () => {
    expect(decodeConversation({ ...wire, open: "true" })).toBeNull();
    expect(decodeConversations({ conversations: [wire] })).toHaveLength(1);
  });
});

describe("a message, which reaches this client under one key on all three paths", () => {
  const common = {
    message_id: MESSAGE,
    connection_id: CONNECTION,
    author_id: PERSON,
    author_display_name: "Captain Nemo",
    body: "on my way",
  };

  it("says `sent_at` in a reply, in a history entry, and in the push", () => {
    // `rendered_message/1`. `peer_channel_test.exs` pins this key set exactly
    // and now pins the push's against it, which is what let the second decoder
    // go — so `author_display_name` reaches all three paths or none.
    expect(decodePeerMessage({ ...common, sent_at: "2026-07-28T09:00:00Z" })).toEqual({
      messageId: MESSAGE,
      connectionId: CONNECTION,
      authorId: PERSON,
      authorDisplayName: "Captain Nemo",
      body: "on my way",
      sentAt: "2026-07-28T09:00:00Z",
    });
  });

  it("is nothing at all when the author has no name", () => {
    // Spelled `author_display_name`, exactly as `RoomChannel.rendered/1`
    // spells it: a message's author is one entity whichever room or
    // conversation carried the words, and `decodeRoomMessage` requires the
    // same key for the same reason.
    expect(
      decodePeerMessage(
        without({ ...common, sent_at: "2026-07-28T09:00:00Z" }, "author_display_name"),
      ),
    ).toBeNull();
    expect(
      decodePeerMessage({
        ...common,
        sent_at: "2026-07-28T09:00:00Z",
        author_display_name: 7,
      }),
    ).toBeNull();
  });

  it("refuses `at`, which is what the push used to say", () => {
    // The control, and the reason this is one decoder rather than one decoder
    // with a fallback. `at` is still the key of the four *notices* — a
    // request, a decline, a connection, a disconnection — and accepting it
    // here would let a message and a notice decode as the same thing, which is
    // how one entity keeps two key names for ever.
    expect(decodePeerMessage({ ...common, at: "2026-07-28T09:00:00Z" })).toBeNull();

    // And a payload carrying neither is still nothing, which a fallback would
    // have had to check for separately.
    expect(decodePeerMessage(common)).toBeNull();
  });

  it("is `message_id` in both, which is the half U8's review fixed", () => {
    // The live push always said `message_id`; the reply and the history said
    // `id`, so one entity had two key names on one channel. A client keying on
    // `<entity>_id` read one of the three and not the other two.
    expect(
      decodePeerMessage({
        id: MESSAGE,
        connection_id: CONNECTION,
        author_id: PERSON,
        body: "on my way",
        sent_at: "2026-07-28T09:00:00Z",
      }),
    ).toBeNull();
  });

  it("reads the history, oldest first, as the reply carries it", () => {
    expect(
      decodePeerMessages({
        messages: [
          { ...common, sent_at: "2026-07-28T09:00:00Z" },
          { ...common, message_id: OTHER, sent_at: "2026-07-28T09:01:00Z" },
        ],
      }),
    ).toHaveLength(2);
    expect(decodePeerMessages({ messages: [{ ...common }] })).toBeNull();
  });
});
