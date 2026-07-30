/**
 * The peer surface, driven through the real components against the fake socket.
 *
 * Every payload here is the shape
 * `lib/hospitality_coms_web/channels/peer_channel.ex` actually puts on the wire
 * — the nine events, the five pushes and the four rendered entities — read out
 * of that module rather than assumed. The two scenarios issue #12 names are the
 * two `describe` blocks that say so.
 *
 * The fake models `phoenix`'s rejoin behaviour rather than only its interface,
 * which is what makes "a refused join is asked once" a measurement instead of a
 * restatement — see `test-support/fake-socket.ts`.
 *
 * ## Two fixture rules this file learned the hard way
 *
 * **Answer `history` with both parties' messages.** Every disconnect test used
 * to answer it with `{messages: []}`, so the counterpart's messages were never
 * in the cache when the conversation closed — which made the whole class of
 * "what does a disconnect take off the screen" untestable, and hid a real
 * defect for a revision. A fixture that is empty exactly where the property
 * lives cannot fail.
 *
 * **Pin which lists a refresh asks for.** `answerLists` takes the exact events
 * it expects to be outstanding, so a handler refreshing a list it has no
 * business refreshing fails here rather than passing quietly. Answering
 * whatever had accumulated could not catch an over-fetch at all.
 */

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";

import { App } from "../../app/app";
import { SessionProvider } from "../../session/session-context";
import { createMemoryTokenStore } from "../../session/token-store";
import { SocketProvider } from "../../socket/socket-context";
import { createFakeApi, ok } from "../../test-support/fake-api";
import type { FakeChannel } from "../../test-support/fake-socket";
import { fakeSocketFactory } from "../../test-support/fake-socket";
import { createMemoryRoomStore } from "../rooms/room-store";
import { normalisePersonId, peerTopic } from "./peer";

const PERSON_ID = "a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5";
const PEER_ID = "c3c3c3c3-d4d4-4e5e-8f6f-a7a7a7a7a7a7";
const OTHER_PEER_ID = "b2b2b2b2-c3c3-4d4d-8e5e-f6f6f6f6f6f6";
const VENUE_ID = "11111111-1111-4111-8111-111111111111";
const REQUEST_ID = "22222222-2222-4222-8222-222222222222";
const CONNECTION_ID = "33333333-3333-4333-8333-333333333333";
const OTHER_CONNECTION_ID = "44444444-4444-4444-8444-444444444444";

const JOIN_LISTS = ["list_peers", "list_requests", "list_conversations"] as const;

/** `rendered_peer/1`. */
function peerWire(overrides: Record<string, unknown> = {}) {
  return {
    person_id: PEER_ID,
    display_name: "Captain Nemo",
    venue_id: VENUE_ID,
    venue_name: "The Anchor",
    role_label: "Bartender",
    visible_from: "2026-07-01T00:00:00Z",
    visible_until: "2026-09-01T00:00:00Z",
    ...overrides,
  };
}

/**
 * The two people in these fixtures, by the names #73 put on the wire.
 *
 * `OWN_NAME` is never rendered anywhere on this surface — a message this person
 * wrote says "You" — so it is here to be asserted **absent**, which is what
 * makes the author render's own-message branch observable.
 */
const PEER_NAME = "Captain Nemo";
const OWN_NAME = "Doctor Watson";

/** `rendered_request/1`, as this person's own outgoing approach. */
function requestWire(overrides: Record<string, unknown> = {}) {
  return {
    request_id: REQUEST_ID,
    requester_id: PERSON_ID,
    // Both names, beside both ids: `rendered_request/1` serves four call sites
    // and takes no viewer, so it cannot send one viewer-relative counterpart.
    // The two literals are deliberately unequal in every fixture built from
    // this one, because a reader that took the wrong side would otherwise be
    // invisible — the surface renders exactly one of the two per row.
    requester_display_name: OWN_NAME,
    addressee_id: PEER_ID,
    addressee_display_name: PEER_NAME,
    state: "pending",
    requested_at: "2026-07-28T09:00:00Z",
    accepted_at: null,
    declined_at: null,
    ...overrides,
  };
}

/** The same shape addressed the other way, which is what an incoming list holds. */
function incomingWire(overrides: Record<string, unknown> = {}) {
  return requestWire({
    requester_id: PEER_ID,
    requester_display_name: PEER_NAME,
    addressee_id: PERSON_ID,
    addressee_display_name: OWN_NAME,
    ...overrides,
  });
}

/** `rendered_conversation/1`, which is also the `accept` and `disconnect` reply. */
function conversationWire(overrides: Record<string, unknown> = {}) {
  return {
    connection_id: CONNECTION_ID,
    peer_id: PEER_ID,
    peer_display_name: PEER_NAME,
    connected_at: "2026-07-28T09:05:00Z",
    disconnected_at: null,
    disconnected_by_id: null,
    open: true,
    ...overrides,
  };
}

/** `rendered_message/1` — the reply to `send` and every history entry. */
function messageWire(overrides: Record<string, unknown> = {}) {
  return {
    message_id: "55555555-5555-4555-8555-555555555555",
    connection_id: CONNECTION_ID,
    author_id: PEER_ID,
    author_display_name: PEER_NAME,
    body: "are you on tonight?",
    sent_at: "2026-07-28T09:10:00Z",
    ...overrides,
  };
}

/** This person's own message, which is what a closed conversation keeps. */
function mineWire(overrides: Record<string, unknown> = {}) {
  return messageWire({
    message_id: "55555555-5555-4555-8555-000000000011",
    author_id: PERSON_ID,
    // The server sends this person's own name like anybody else's — the join
    // does not know who is asking. The surface renders "You" instead, and this
    // string being on the wire is what lets that be asserted rather than
    // assumed: without it, "the author's own name is absent" would pass because
    // there was never a name to render.
    author_display_name: OWN_NAME,
    body: "mine, from before",
    sent_at: "2026-07-28T09:11:00Z",
    ...overrides,
  });
}

/**
 * The `peer_message` push, which is `rendered_message/1`'s shape exactly.
 *
 * It used to stamp its instant `at` — `PeerChannel.stamped/1` is generic over
 * five notices — so this helper rewrote the key and `decode.ts` carried a
 * second decoder. Issue #31 put the push through `PeerChannel.sent/1`, so the
 * push and the reply are one shape and this is the identity. Kept as a named
 * function rather than inlined: the two are the same shape as a *fact about the
 * server*, and a test that stopped distinguishing them would stop being able to
 * say so.
 */
function messageNotice(overrides: Record<string, unknown> = {}) {
  return messageWire(overrides);
}

/** The envelope `ErrorEnvelope.new/2` builds, with a message nobody renders. */
function refusal(code: string, message = "SERVER-SIDE LOG SENTENCE") {
  return { error: { code, message } };
}

type Lists = {
  readonly peers?: readonly object[];
  readonly incoming?: readonly object[];
  readonly outgoing?: readonly object[];
  readonly conversations?: readonly object[];
};

function renderPeers(personId: string) {
  const { socket, createSocket } = fakeSocketFactory();
  const api = createFakeApi({
    currentPerson: () =>
      Promise.resolve(
        ok({ id: personId, email: "worker@example.com", displayName: "Captain Nemo" }),
      ),
  });

  render(
    <MemoryRouter initialEntries={["/peers"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <SocketProvider createSocket={createSocket}>
          <App roomStore={createMemoryRoomStore()} />
        </SocketProvider>
      </SessionProvider>
    </MemoryRouter>,
  );

  return socket;
}

/** A macrotask, so a push queued behind the ones just seen has landed. */
function settle(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

/**
 * Answers the list pushes the client has issued and not had answered.
 *
 * A cursor rather than "the last one", because a notice makes the client ask
 * again: `peer_connected` re-asks two lists in one handler, and a test that
 * answered only the most recent push would leave the other hanging.
 *
 * `expected` is the point of the shape. Every caller names exactly which lists
 * it believes are outstanding, so a refresh that asks for one it should not —
 * an over-fetch, invisible on screen and a round trip per event — fails here.
 */
function serverFor(channel: FakeChannel) {
  let cursor = 0;

  function pending(): string[] {
    return channel.sent
      .slice(cursor)
      .map((sent) => sent.event)
      .filter((event) => event.startsWith("list_"));
  }

  async function answerWith(
    expected: readonly string[],
    payloadFor: (event: string) => unknown,
  ): Promise<void> {
    await waitFor(() => {
      expect(pending()).toEqual([...expected]);
    });

    // And nothing more arrives a turn later. Without this, an over-fetch issued
    // in a microtask behind these would be missed by the assertion above.
    await settle();
    expect(pending()).toEqual([...expected]);

    act(() => {
      for (; cursor < channel.sent.length; cursor += 1) {
        const sent = channel.sent[cursor];
        if (sent?.event.startsWith("list_") !== true) continue;

        sent.push.trigger("ok", payloadFor(sent.event));
      }
    });
  }

  return {
    answerWith,
    answerLists(expected: readonly string[], lists: Lists): Promise<void> {
      return answerWith(expected, (event) => {
        switch (event) {
          case "list_peers":
            return { peers: lists.peers ?? [] };
          case "list_requests":
            return { incoming: lists.incoming ?? [], outgoing: lists.outgoing ?? [] };
          default:
            return { conversations: lists.conversations ?? [] };
        }
      });
    },
  };
}

/** Answers the most recent push of one event, as the server would. */
function answer(
  channel: FakeChannel,
  event: string,
  status: "ok" | "error" | "timeout",
  payload?: unknown,
): void {
  for (let index = channel.sent.length - 1; index >= 0; index -= 1) {
    if (channel.sent[index]?.event === event) {
      act(() => {
        channel.reply(index, status, payload);
      });

      return;
    }
  }

  throw new Error(`nothing pushed ${event}`);
}

function pushesOf(
  channel: FakeChannel,
  event: string,
): { event: string; payload: object }[] {
  return channel.pushed.filter((sent) => sent.event === event);
}

/** Waits until one event has been pushed exactly `count` times. */
async function awaitPushes(
  channel: FakeChannel,
  event: string,
  count: number,
): Promise<void> {
  await waitFor(() => {
    expect(pushesOf(channel, event)).toHaveLength(count);
  });
}

async function openPeers(lists: Lists = {}, personId: string = PERSON_ID) {
  const socket = renderPeers(personId);
  const topic = peerTopic(normalisePersonId(personId) ?? "");

  const channel = await waitFor(() => {
    const opened = socket.channelFor(topic);
    if (opened === undefined) throw new Error(`nothing joined ${topic}`);

    return opened;
  });

  act(() => {
    channel.joinPush.trigger("ok", { person_id: normalisePersonId(personId) });
  });

  const server = serverFor(channel);
  await server.answerLists(JOIN_LISTS, lists);

  return { socket, channel, server };
}

/** Opens a listed conversation and answers the history it asks for. */
async function openConversation(
  channel: FakeChannel,
  peerId: string,
  messages: readonly object[] = [],
): Promise<void> {
  await userEvent.click(
    await screen.findByRole("button", {
      // The button reads `Open conversation <name> · <short id>` since #73, so
      // the name sits between the two halves this helper used to match on. It
      // is matched loosely here and pinned exactly one describe block below:
      // a helper asserting the render would make every test that uses it a
      // second, silent copy of that assertion.
      name: new RegExp(`open conversation .*${peerId.slice(0, 8)}`, "i"),
    }),
  );

  answer(channel, "history", "ok", { messages });
}

/**
 * Confirms a disconnect, opening the confirmation first if it is not on screen.
 *
 * The reopen is what makes two calls of this "one impatient worker" rather than
 * "one worker and a fixture". `DisconnectControl` used to dismiss the
 * confirmation with the same click that sent the push, so the second confirm a
 * double-click reaches is the "Disconnect" button and then "Yes, disconnect"
 * again — and a helper that only clicked the latter would fail on a missing
 * element instead of on the second push it exists to count.
 */
async function confirmDisconnect(): Promise<void> {
  const reopen = screen.queryByRole("button", { name: /^disconnect$/i });
  if (reopen !== null) await userEvent.click(reopen);

  await userEvent.click(screen.getByRole("button", { name: /yes, disconnect/i }));
}

function messageBodies(): (string | null)[] {
  return within(screen.getByRole("list", { name: /conversation messages/i }))
    .queryAllByRole("listitem")
    .map((item) => item.textContent);
}

function composer(): HTMLInputElement {
  return screen.getByLabelText(/^message$/i);
}

describe("the topic the peer surface is joined on", () => {
  it("is `peer:<person_id>`, and one channel carries every conversation", async () => {
    // KTD10. Every event names its conversation in the payload and never in the
    // topic, so two live conversations are still one channel — and no
    // per-conversation topic name exists for a later unit to copy into an
    // employer socket's routing table.
    const { socket, channel } = await openPeers({
      conversations: [
        conversationWire(),
        conversationWire({
          connection_id: OTHER_CONNECTION_ID,
          peer_id: OTHER_PEER_ID,
        }),
      ],
    });

    expect(socket.channels.map((opened) => opened.topic)).toEqual([`peer:${PERSON_ID}`]);

    await openConversation(channel, PEER_ID);
    await openConversation(channel, OTHER_PEER_ID);

    // Still one. A second topic here would be the thing KTD10 exists to
    // prevent.
    expect(socket.channels).toHaveLength(1);
  });

  it("lowercases the person id, because PubSub broadcasts on the literal topic", async () => {
    // The failure is silent and total: an uppercase suffix still passes
    // `admitted/3` — `Ecto.UUID.cast/1` downcases before the comparison — so
    // the join succeeds, and `Phoenix.Channel.Server` then subscribes the
    // channel to a topic string nothing publishes to. Every announcement,
    // for the whole session, absent.
    const socket = renderPeers(PERSON_ID.toUpperCase());

    await waitFor(() => {
      expect(socket.channels).toHaveLength(1);
    });

    expect(socket.channels[0]?.topic).toBe(`peer:${PERSON_ID}`);
  });

  it("asks for the three lists it renders, as soon as it is admitted", async () => {
    const { channel } = await openPeers();

    expect(channel.pushed).toEqual([
      { event: "list_peers", payload: {} },
      { event: "list_requests", payload: {} },
      { event: "list_conversations", payload: {} },
    ]);
  });

  it("names a counterpart, with the id beside the name rather than instead of it", async () => {
    // #66. The list used to lead with eight hex characters. It leads with the
    // counterpart's own name now — and keeps the shortened `person_id`, because
    // display names are deliberately not unique and two colleagues can draw the
    // same character.
    await openPeers({ peers: [peerWire()] });

    const list = within(await screen.findByRole("list", { name: /people you can see/i }));

    expect(list.getByText(`Captain Nemo · ${PEER_ID.slice(0, 8)}`)).toBeInTheDocument();
    // The full id is still never rendered, which is what the shortening is for.
    expect(list.queryByText(PEER_ID)).toBeNull();
  });

  it("carries the session token as authToken and never in the socket params", async () => {
    const { socket } = await openPeers();

    expect(socket.options).toEqual({ authToken: "c2Vzc2lvbg" });
    expect(socket.endpoint).toBe("/socket/person");
    expect(socket.channels[0]?.params).toBeUndefined();
  });
});

describe("every person on this surface is named and not only numbered", () => {
  // #73. `list_visible_peers/1` carried a name from #66 and nothing else did,
  // so five of the six places this surface names a human rendered eight hex
  // characters with no name at all — which is worse than the chat, where the
  // name was at least there. #76 put `peer_display_name`,
  // `requester_display_name`, `addressee_display_name` and
  // `author_display_name` on the wire; these are the renders that read them.
  //
  // **The short id stays beside every one.** Collisions are deliberate — a
  // globally unique readable name would be a second `person_id` in plain text
  // — so the id is the only one of the two that tells two people apart. The
  // colliding-names test below is what makes that a measurement here rather
  // than a sentence in `CLAUDE.md`.

  it("names the requester in the heading and in both answers", async () => {
    await openPeers({ incoming: [incomingWire()] });

    const row = within(await screen.findByRole("list", { name: /requests to you/i }));
    const short = PEER_ID.slice(0, 8);

    expect(row.getByText(`${PEER_NAME} · ${short}`)).toBeInTheDocument();
    expect(
      row.getByRole("button", { name: `Accept ${PEER_NAME} · ${short}` }),
    ).toBeInTheDocument();
    expect(
      row.getByRole("button", { name: `Decline ${PEER_NAME} · ${short}` }),
    ).toBeInTheDocument();
  });

  it("keeps the two answer buttons apart when two requesters share a name", async () => {
    // The control on the short id in a *button*, and the reason it is on the
    // buttons at all rather than only in the heading. Two people may draw the
    // same character, and two buttons with one accessible name are a
    // screen-reader user choosing between two identical options.
    //
    // **Asserted as an inequality rather than against the two expected
    // strings**, which is the difference between this test and the one above.
    // Written the other way it failed when the *format* changed and passed
    // whenever two buttons were indistinguishable in some other format —
    // measured: dropping the short id made it fail "could not find `Accept
    // Captain Nemo · c3c3c3c3`", which is the wrong reason and would have been
    // satisfied by any renaming. The property is that the two differ.
    await openPeers({
      incoming: [
        incomingWire(),
        incomingWire({
          request_id: "22222222-2222-4222-8222-000000000002",
          requester_id: OTHER_PEER_ID,
          // The same name, deliberately. A fixture with two different names
          // is invariant under the mutation this test exists to catch.
          requester_display_name: PEER_NAME,
        }),
      ],
    });

    const row = within(await screen.findByRole("list", { name: /requests to you/i }));

    // The control: two rows rendered, and both name the shared character. An
    // inequality over an empty list is vacuous.
    const accepts = row.getAllByRole("button", { name: /^accept/i });
    expect(accepts).toHaveLength(2);
    for (const button of accepts) {
      expect(button).toHaveAccessibleName(new RegExp(PEER_NAME));
    }

    const [first, second] = accepts.map((button) => button.textContent);
    expect(first).not.toEqual(second);
  });

  it("names the addressee on an outgoing request, which is the side the reader is not", async () => {
    await openPeers({ outgoing: [requestWire()] });

    const row = within(await screen.findByRole("list", { name: /requests you sent/i }));

    // The control: the row rendered and carries what it always carried. An
    // absence assertion below passes against a list that rendered nothing.
    expect(row.getByText(`${PEER_NAME} · ${PEER_ID.slice(0, 8)}`)).toBeInTheDocument();
    expect(row.getByText("Pending")).toBeInTheDocument();

    // `rendered_request/1` sends both names because it takes no viewer. Which
    // of the two a row shows is this client's choice, and showing the
    // requester here would name the reader to themselves.
    expect(row.queryByText(new RegExp(OWN_NAME))).toBeNull();
  });

  it("names the counterpart in the conversation list", async () => {
    await openPeers({ conversations: [conversationWire()] });

    expect(
      await screen.findByRole("button", {
        name: `Open conversation ${PEER_NAME} · ${PEER_ID.slice(0, 8)}`,
      }),
    ).toBeInTheDocument();
  });

  it("names the counterpart in the conversation heading", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });
    await openConversation(channel, PEER_ID);

    expect(
      await screen.findByRole("heading", {
        name: `Conversation with ${PEER_NAME} · ${PEER_ID.slice(0, 8)}`,
      }),
    ).toBeInTheDocument();
  });

  it("names the author of everybody else's messages and says `You` for its own", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });
    await openConversation(channel, PEER_ID, [mineWire(), messageWire()]);

    const list = within(
      await screen.findByRole("list", { name: /conversation messages/i }),
    );

    // The control: both messages are on screen. Asserting the reader's own
    // name is absent passes against an empty history.
    expect(list.getByText("are you on tonight?")).toBeInTheDocument();
    expect(list.getByText("mine, from before")).toBeInTheDocument();

    expect(list.getByText(`${PEER_NAME} · ${PEER_ID.slice(0, 8)}`)).toBeInTheDocument();
    expect(list.getByText("You")).toBeInTheDocument();

    // `mineWire` carries this person's own name on the wire — the join does
    // not know who is asking — so "You" is a choice this render makes and not
    // an absence it inherits.
    expect(list.queryByText(new RegExp(OWN_NAME))).toBeNull();
    expect(list.queryByText(new RegExp(PERSON_ID.slice(0, 8)))).toBeNull();
  });

  it("renders an erased counterpart's constant verbatim, having no case for it", async () => {
    // A control rather than coverage, and it is recorded as one in the brief.
    // `Lifecycle.erase_person/1` overwrites `display_name` with
    // `erased_display_name/0` in the statement that nulls the address, and
    // none of the three joins filters `erased_at` — so the constant arrives as
    // an ordinary string. This passes trivially against a correct client and
    // fails against one that grew a branch for it, or a decoder that treated
    // the constant as an absence. A second spelling of that string on this
    // side is the thing being refused.
    //
    // **It asserts the list *and* the heading**, which is a correction found by
    // mutating rather than by reading: written against the list alone, a
    // special case planted in `conversation-view.tsx` killed 0. The heading is
    // where such a branch would most plausibly go — it is the one render that
    // names the counterpart on their own and reads oddest with a constant.
    const { channel } = await openPeers({
      conversations: [conversationWire({ peer_display_name: "Former colleague" })],
    });

    expect(
      await screen.findByRole("button", {
        name: `Open conversation Former colleague · ${PEER_ID.slice(0, 8)}`,
      }),
    ).toBeInTheDocument();

    await openConversation(channel, PEER_ID);

    expect(
      await screen.findByRole("heading", {
        name: `Conversation with Former colleague · ${PEER_ID.slice(0, 8)}`,
      }),
    ).toBeInTheDocument();
  });
});

describe("a pending outbound request renders as pending until answered", () => {
  it("asks, shows pending, and only stops when the server says otherwise", async () => {
    // Issue #12's first scenario, end to end.
    const { channel, server } = await openPeers({ peers: [peerWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /ask captain nemo to connect/i }),
    );

    expect(pushesOf(channel, "request")).toEqual([
      { event: "request", payload: { person_id: PEER_ID } },
    ]);

    answer(channel, "request", "ok", requestWire());
    await server.answerLists(["list_requests"], {
      peers: [peerWire()],
      outgoing: [requestWire()],
    });

    const sent = within(await screen.findByRole("list", { name: /requests you sent/i }));
    expect(sent.getByText(/^Pending$/)).toBeInTheDocument();
    expect(sent.getByText(/waiting for them to answer/i)).toBeInTheDocument();

    // And the peer entry stops offering the ask, because the server just said
    // there is one outstanding.
    expect(
      screen.queryByRole("button", { name: /ask captain nemo to connect/i }),
    ).toBeNull();

    // It stays pending. Nothing here decides that time has passed: `:lapsed`
    // and `:accepted` are both the server's, derived at the instant it is
    // asked.
    act(() => {
      channel.emit("peer_message", messageNotice({ connection_id: CONNECTION_ID }));
    });
    expect(sent.getByText(/^Pending$/)).toBeInTheDocument();
  });

  it("stops being pending when the acceptance arrives, without a reload", async () => {
    // The regression this pins: a client that applied the notice to local state
    // rather than re-asking would have to invent `state`, which is derived per
    // read from visibility at that instant. One that ignored the notice
    // entirely would sit on "Pending" for ever.
    const { channel, server } = await openPeers({
      peers: [peerWire()],
      outgoing: [requestWire()],
    });

    // Twice over: the peer entry stops offering the ask and says what it is
    // waiting for, and the outgoing list says the same.
    expect(await screen.findAllByText(/^Pending$/)).toHaveLength(2);

    act(() => {
      channel.emit("peer_connected", {
        connection_id: CONNECTION_ID,
        request_id: REQUEST_ID,
        peer_id: PEER_ID,
        at: "2026-07-28T09:05:00Z",
      });
    });

    await server.answerLists(["list_requests", "list_conversations"], {
      peers: [peerWire()],
      outgoing: [requestWire({ state: "accepted", accepted_at: "2026-07-28T09:05:00Z" })],
      conversations: [conversationWire()],
    });

    expect(await screen.findByText(/^Accepted$/)).toBeInTheDocument();
    expect(screen.queryByText(/^Pending$/)).toBeNull();
    expect(
      within(screen.getByRole("list", { name: /your conversations/i })).getByRole(
        "button",
        { name: /open conversation .*c3c3c3c3/i },
      ),
    ).toBeInTheDocument();
  });

  it("renders a lapsed request as expired rather than as refused", async () => {
    // `:lapsed` is derived and reversible: the pair stopped being co-rostered,
    // nobody refused anything, and the same row reports `:pending` again if
    // they work together again.
    await openPeers({ outgoing: [requestWire({ state: "lapsed" })] });

    expect(await screen.findByText(/^Expired$/)).toBeInTheDocument();
    expect(screen.getByText(/nobody refused it/i)).toBeInTheDocument();
  });

  it("offers no way to withdraw one, because the server has no event for it", async () => {
    // `HospitalityComs.Peers` says so and says why: declining blocks the
    // requester by design, so a non-blocking withdrawal is a rate-limiting
    // decision (issue #15) rather than a mechanical addition. A button here
    // would be inventing a backend.
    await openPeers({ outgoing: [requestWire()] });

    await screen.findByText(/^Pending$/);
    expect(screen.queryByRole("button", { name: /withdraw|cancel request/i })).toBeNull();
  });

  it("does not offer to ask somebody who has already asked you", async () => {
    // Everything on `list_incoming_requests/1` is outstanding, so an entry from
    // this peer means the approach already exists in the other direction. The
    // server refuses the request `conflict`, so the button could only ever
    // produce an error — and it reads as though nothing has happened, when
    // somebody is waiting on an answer further down the page.
    await openPeers({ peers: [peerWire()], incoming: [incomingWire()] });

    expect(await screen.findByText(/they asked you to connect/i)).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /ask captain nemo to connect/i }),
    ).toBeNull();

    // The answer is still one click away, which is the point of saying where.
    expect(screen.getByRole("button", { name: /accept .*c3c3c3c3/i })).toBeEnabled();
  });
});

describe("two workers exchanging peer messages see them in order", () => {
  it("loads the history, appends what arrives, and orders by the server's instant", async () => {
    // Issue #12's second scenario. The ordering key is `sent_at`, not arrival:
    // a message that reaches this client late — a reconnect delivering a
    // backlog, or the two paths a sender's own message takes — belongs where
    // the server stamped it.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation .*c3c3c3c3/i }),
    );

    expect(pushesOf(channel, "history")).toEqual([
      { event: "history", payload: { connection_id: CONNECTION_ID } },
    ]);

    answer(channel, "history", "ok", {
      messages: [
        messageWire({ body: "are you on tonight?", sent_at: "2026-07-28T09:10:00Z" }),
        messageWire({
          message_id: "55555555-5555-4555-8555-000000000002",
          author_id: PERSON_ID,
          body: "yes, from six",
          sent_at: "2026-07-28T09:11:00Z",
        }),
      ],
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });

    act(() => {
      channel.emit(
        "peer_message",
        messageNotice({
          message_id: "55555555-5555-4555-8555-000000000003",
          body: "see you there",
          sent_at: "2026-07-28T09:12:00Z",
        }),
      );
    });

    // And one that is older than everything already on screen, arriving last.
    act(() => {
      channel.emit(
        "peer_message",
        messageNotice({
          message_id: "55555555-5555-4555-8555-000000000000",
          body: "morning",
          sent_at: "2026-07-28T08:59:00Z",
        }),
      );
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(4);
    });

    const bodies = messageBodies();
    expect(bodies[0]).toContain("morning");
    expect(bodies[1]).toContain("are you on tonight?");
    expect(bodies[2]).toContain("yes, from six");
    expect(bodies[3]).toContain("see you there");

    // Attribution is the person here — the peer graph is person zone and the
    // counterpart's id is already in the peer list. Since #73 the name leads
    // and the shortened id follows it, which is the ordering every render on
    // this surface uses; the full id is still never on screen.
    expect(bodies[1]).toMatch(new RegExp(`^${PEER_NAME} · c3c3c3c3`));
    expect(bodies[1]).not.toContain(PEER_ID);
    expect(bodies[2]).toMatch(/^You/);
  });

  it("orders a sub-second instant after the whole second it follows", async () => {
    // A guard on a hazard that is live rather than hypothetical. Compared as
    // strings, `"…:00.5Z" < "…:00Z"` — `.` sorts before `Z` — so the moment any
    // peer column becomes `:utc_datetime_usec` the order inverts inside every
    // second. U6's review made exactly that change to `roster_entries` for a
    // correctness reason, so this is a thing that happens in this codebase.
    //
    // Deleting the `Date.parse` in `byInstant` fails this and nothing else.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID, [
      messageWire({
        message_id: "55555555-5555-4555-8555-00000000000a",
        body: "on the hour",
        sent_at: "2026-07-28T09:10:00Z",
      }),
      messageWire({
        message_id: "55555555-5555-4555-8555-00000000000b",
        body: "half a second later",
        sent_at: "2026-07-28T09:10:00.500000Z",
      }),
    ]);

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });

    const bodies = messageBodies();
    expect(bodies[0]).toContain("on the hour");
    expect(bodies[1]).toContain("half a second later");
  });

  it("keeps the server's order for two messages sharing an instant", async () => {
    // The clock is injectable and the demo pins it, so two messages stamped in
    // the same second are ordinary rather than exotic. The sort is stable and
    // the history is merged first, so the server's own ordering survives — and
    // a message arriving afterwards at that same instant goes last, where it
    // belongs.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID, [
      messageWire({
        message_id: "55555555-5555-4555-8555-00000000000c",
        body: "first",
        sent_at: "2026-07-28T09:10:00Z",
      }),
      messageWire({
        message_id: "55555555-5555-4555-8555-00000000000d",
        body: "second",
        sent_at: "2026-07-28T09:10:00Z",
      }),
    ]);

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });

    act(() => {
      channel.emit(
        "peer_message",
        messageNotice({
          message_id: "55555555-5555-4555-8555-00000000000e",
          body: "third",
          sent_at: "2026-07-28T09:10:00Z",
        }),
      );
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(3);
    });

    const bodies = messageBodies();
    expect(bodies[0]).toContain("first");
    expect(bodies[1]).toContain("second");
    expect(bodies[2]).toContain("third");
  });

  it("backfills what it missed while the socket was away", async () => {
    // The gap `joinGeneration` closes. The three lists are re-asked on every
    // join, so a reconnect re-derives them — but an open conversation's history
    // is not a list, and a message sent while the link was down reached no push
    // here, because this client was not subscribed to hear it.
    //
    // Deleting `joinGeneration` from `ConversationView`'s effect leaves the
    // second message missing until the conversation is closed and reopened.
    const { channel, server } = await openPeers({
      conversations: [conversationWire()],
    });

    await openConversation(channel, PEER_ID, [
      messageWire({ body: "before the drop", sent_at: "2026-07-28T09:10:00Z" }),
    ]);
    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });

    // What `phoenix` does when the link comes back: the same join push's
    // `receive("ok")` hooks fire again, because `Push.reset()` keeps `recHooks`.
    act(() => {
      channel.joinPush.trigger("ok", { person_id: PERSON_ID });
    });

    await server.answerLists(JOIN_LISTS, { conversations: [conversationWire()] });

    await awaitPushes(channel, "history", 2);
    answer(channel, "history", "ok", {
      messages: [
        messageWire({ body: "before the drop", sent_at: "2026-07-28T09:10:00Z" }),
        messageWire({
          message_id: "55555555-5555-4555-8555-00000000000f",
          body: "while you were away",
          sent_at: "2026-07-28T09:11:00Z",
        }),
      ],
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });
    expect(messageBodies()[1]).toContain("while you were away");
  });

  it("sends under the event and payload the channel handles", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    await userEvent.type(await screen.findByLabelText(/^message$/i), "on my way");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));

    expect(pushesOf(channel, "send")).toEqual([
      { event: "send", payload: { connection_id: CONNECTION_ID, body: "on my way" } },
    ]);
  });

  it("shows the sender's own message once, though it arrives twice", async () => {
    // `announce/2` publishes to both parties and a channel is subscribed to its
    // own topic, so the reply to `send` and the `peer_message` push are the same
    // row down two paths — under two different keys for its instant.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    await userEvent.type(await screen.findByLabelText(/^message$/i), "on my way");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));

    const mine = { author_id: PERSON_ID, body: "on my way" };
    answer(channel, "send", "ok", messageWire(mine));
    act(() => {
      channel.emit("peer_message", messageNotice(mine));
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });
    expect(composer()).toHaveValue("");
  });

  it("keeps what was typed when the send is refused", async () => {
    // `features/rooms/`'s lesson, which cost a message every time: clearing on
    // submit means the worker reads a sentence explaining the failure with
    // nothing left to correct and resend.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    await userEvent.type(await screen.findByLabelText(/^message$/i), "kitchen is short");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));
    answer(channel, "send", "error", refusal("unprocessable_entity"));

    await screen.findByRole("alert");
    expect(composer()).toHaveValue("kitchen is short");
  });

  it("finds a conversation no list has mentioned, rather than losing it", async () => {
    // `announce/2` is best effort and logged, so a `peer_connected` can be
    // dropped. Without this the message piles up in a cache nothing can open
    // and the conversation is invisible until a reload.
    const { channel, server } = await openPeers({ conversations: [] });

    expect(await screen.findByText(/no conversations yet/i)).toBeInTheDocument();

    act(() => {
      channel.emit("peer_message", messageNotice({ body: "did you get my request?" }));
    });

    await server.answerLists(["list_conversations"], {
      conversations: [conversationWire()],
    });

    await openConversation(channel, PEER_ID);

    // And the message that announced it is there, because it was kept.
    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });
    expect(messageBodies()[0]).toContain("did you get my request?");
  });
});

describe("a refusal on the peer channel", () => {
  it("says why in this client's words, never the server's log sentence", async () => {
    const { channel } = await openPeers({ peers: [peerWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /ask captain nemo to connect/i }),
    );
    answer(channel, "request", "error", refusal("conflict"));

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/already outstanding|already connected/i);
    expect(alert).not.toHaveTextContent(/SERVER-SIDE LOG SENTENCE/);
  });

  it("says nothing about whether the thing exists, which is AE1", async () => {
    // `:not_found` covers a person who is not a peer, a conversation between
    // two other people, and an id that names nothing — identically, and a
    // malformed id gets it too. Rendering two sentences would hand back the
    // distinction the server declines to make.
    const { channel } = await openPeers({ peers: [peerWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /ask captain nemo to connect/i }),
    );
    answer(channel, "request", "error", refusal("not_found"));

    expect(await screen.findByRole("alert")).toHaveTextContent(/cannot tell you which/i);
  });

  it("renders the server's per-field messages, which name what was typed", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    await userEvent.type(await screen.findByLabelText(/^message$/i), "x");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));
    answer(channel, "send", "error", {
      error: {
        code: "unprocessable_entity",
        message: "that was rejected",
        fields: { body: ["should be at most 4000 character(s)"] },
      },
    });

    expect(
      await screen.findByText(/should be at most 4000 character\(s\)/i),
    ).toBeInTheDocument();
  });

  it("names an answer it cannot read, rather than leaving a stale list", async () => {
    // `decode.ts` says every decoder returns `null` for "this is not that" so
    // the caller can turn it into a *named absence*. The list loaders used to
    // return silently, so one row carrying a `state` this client has no case
    // for left an empty list on screen under "Nobody has asked you to
    // connect" — the documented safety property and the implemented one
    // disagreeing, which is the class this project keeps finding.
    const socket = renderPeers(PERSON_ID);
    const channel = await waitFor(() => {
      const opened = socket.channelFor(peerTopic(PERSON_ID));
      if (opened === undefined) throw new Error("nothing joined");

      return opened;
    });

    act(() => {
      channel.joinPush.trigger("ok", { person_id: PERSON_ID });
    });

    await serverFor(channel).answerWith(JOIN_LISTS, (event) =>
      event === "list_requests"
        ? { incoming: [incomingWire({ state: "withdrawn" })], outgoing: [] }
        : { peers: [], conversations: [] },
    );

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /shape this client does not understand/i,
    );
  });

  it("asks the server again when a send says the conversation is closed", async () => {
    // The one real difference from the rooms. A room had to *remember*
    // `room_closed`, because nothing on the wire carries a shift room's
    // `closes_at`; here `list_conversations` carries `open`, so the honest
    // answer to this refusal is to ask and render what comes back. Nothing is
    // inferred and nothing is stored.
    const { channel, server } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID, [mineWire()]);

    await userEvent.type(await screen.findByLabelText(/^message$/i), "still there?");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));
    answer(channel, "send", "error", refusal("conflict"));

    await server.answerLists(["list_conversations"], {
      conversations: [
        conversationWire({
          open: false,
          disconnected_at: "2026-07-28T09:20:00Z",
          disconnected_by_id: PEER_ID,
        }),
      ],
    });

    // Closing it re-asks the history, because a closed conversation is a
    // different answer — see the disconnect block below.
    await awaitPushes(channel, "history", 2);
    answer(channel, "history", "ok", { messages: [mineWire()] });

    expect(await screen.findByText(/they ended it/i)).toBeInTheDocument();
    await waitFor(() => {
      expect(composer()).toBeDisabled();
    });
  });

  it("does not retry into a refused join", async () => {
    const socket = renderPeers(PERSON_ID);

    const channel = await waitFor(() => {
      const opened = socket.channelFor(peerTopic(PERSON_ID));
      if (opened === undefined) throw new Error("nothing joined");

      return opened;
    });

    act(() => {
      channel.joinPush.trigger("error", refusal("unauthorized"));
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /signed out somewhere else/i,
    );
    expect(channel.leaves).toBe(1);

    act(() => {
      socket.fireRejoinTimers(10);
    });

    expect(channel.joins).toBe(1);
  });

  it("takes the whole graph off the screen when a rejoin is refused", async () => {
    // The shared-terminal rule, arriving for the third time in this client —
    // after room bookmarks surviving log-out, and a closed conversation's cache
    // outliving the server's own answer.
    //
    // `phoenix` rejoins on its own backoff after a dropped link, and a session
    // revoked in between is refused there. `RequireSession` still reads
    // `authenticated` — `GET /api/me` was answered minutes ago — so nothing
    // else on this page would clear it, and what is on screen names who this
    // person knows.
    const { channel } = await openPeers({
      peers: [peerWire()],
      incoming: [incomingWire()],
      conversations: [conversationWire()],
    });

    expect(
      await screen.findByRole("list", { name: /people you can see/i }),
    ).toBeInTheDocument();

    // The rejoin refusal: the same join push answering again, which is what
    // `Push.reset()` keeping `recHooks` produces.
    act(() => {
      channel.joinPush.trigger("error", refusal("unauthorized"));
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /signed out somewhere else/i,
    );

    // The sections stay on the page and are **empty**, which is the evidence
    // that the surface dropped what it held rather than merely hiding it. A
    // route that hid them instead would satisfy "the peer is not on screen"
    // while the graph sat in memory for the life of the page, and no assertion
    // through the DOM could tell the two apart.
    await waitFor(() => {
      expect(screen.queryByRole("list", { name: /people you can see/i })).toBeNull();
    });
    expect(screen.queryByRole("list", { name: /requests to you/i })).toBeNull();
    expect(screen.queryByRole("list", { name: /your conversations/i })).toBeNull();
    expect(screen.queryByText(new RegExp(PEER_ID.slice(0, 8)))).toBeNull();

    expect(screen.getByText(/nobody right now/i)).toBeInTheDocument();
    expect(screen.getByText(/nobody has asked you to connect/i)).toBeInTheDocument();
    expect(screen.getByText(/no conversations yet/i)).toBeInTheDocument();
  });

  it("keeps a list a refusal says nothing about, when the session is fine", async () => {
    // The control for the test above, and the reason the clear is keyed on
    // `unauthorized` rather than on any refusal. `phoenix` itself refuses with
    // `%{reason: "too many channels joined"}` at `max_channels_per_transport`,
    // which is not an `ErrorEnvelope` and says nothing about who is signed in.
    // Emptying the graph there would throw away this person's own data to
    // report a transport limit.
    const { channel } = await openPeers({ peers: [peerWire()] });

    await screen.findByRole("list", { name: /people you can see/i });

    act(() => {
      channel.joinPush.trigger("error", { reason: "too many channels joined" });
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(/does not understand/i);
    expect(screen.getByRole("list", { name: /people you can see/i })).toBeInTheDocument();
  });

  it("control: the same harness counts a rejoin on a surface that was admitted", async () => {
    // Without this, `joins === 1` above would be satisfied by a fake that
    // cannot rejoin at all.
    const { socket, channel } = await openPeers();

    act(() => {
      socket.fireRejoinTimers(1);
    });

    expect(channel.joins).toBe(2);
  });
});

describe("answering a request", () => {
  it("accepts, and the conversation it created appears", async () => {
    const { channel, server } = await openPeers({ incoming: [incomingWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /accept .*c3c3c3c3/i }),
    );

    expect(pushesOf(channel, "accept")).toEqual([
      { event: "accept", payload: { request_id: REQUEST_ID } },
    ]);

    // `accept` replies with the conversation rather than the request, through
    // `rendered_connection/2`.
    answer(channel, "accept", "ok", conversationWire());
    await server.answerLists(["list_requests", "list_conversations"], {
      conversations: [conversationWire()],
    });

    expect(
      await screen.findByRole("button", { name: /open conversation .*c3c3c3c3/i }),
    ).toBeInTheDocument();
    expect(screen.getByText(/nobody has asked you to connect/i)).toBeInTheDocument();
  });

  it("takes one answer per request, not one per click", async () => {
    // Accepting and declining are the same conditional `UPDATE` on the server
    // (`Records.answerable/2`), so a second click loses whichever it was and
    // gets `:not_found` — indistinguishable from an id that names nothing
    // (AE1), so the surface could not explain it if it wanted to.
    const { channel } = await openPeers({ incoming: [incomingWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /accept .*c3c3c3c3/i }),
    );

    expect(screen.getByRole("button", { name: /accept .*c3c3c3c3/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /decline .*c3c3c3c3/i })).toBeDisabled();

    await userEvent.click(screen.getByRole("button", { name: /accept .*c3c3c3c3/i }));
    await userEvent.click(screen.getByRole("button", { name: /decline .*c3c3c3c3/i }));

    expect(pushesOf(channel, "accept")).toHaveLength(1);
    expect(pushesOf(channel, "decline")).toHaveLength(0);
  });

  it("declines, and says so in a sentence that is not an error", async () => {
    const { channel, server } = await openPeers({ incoming: [incomingWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /decline .*c3c3c3c3/i }),
    );

    expect(pushesOf(channel, "decline")).toEqual([
      { event: "decline", payload: { request_id: REQUEST_ID } },
    ]);

    answer(
      channel,
      "decline",
      "ok",
      incomingWire({ state: "declined", declined_at: "2026-07-28T09:30:00Z" }),
    );
    await server.answerLists(["list_requests"], {});

    expect(
      await screen.findByText(/nobody has asked you to connect/i),
    ).toBeInTheDocument();
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("keeps both controls on a lapsed request, because it can be declined", async () => {
    // An addressee may always say no, whether or not the pair can still see
    // each other — refusing a decline would leave the requester holding a row
    // nobody could clear. Accepting one is refused `gone`, and the sentence
    // says it can be answered again if they work together again.
    const { channel } = await openPeers({
      incoming: [incomingWire({ state: "lapsed" })],
    });

    expect(
      await screen.findByRole("button", { name: /decline .*c3c3c3c3/i }),
    ).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: /accept .*c3c3c3c3/i }));
    answer(channel, "accept", "error", refusal("gone"));

    expect(await screen.findByRole("alert")).toHaveTextContent(/expired/i);
  });
});

describe("disconnecting", () => {
  it("confirms first, because it is not undoable and not symmetric", async () => {
    // R15 makes it unilateral and KTD19 makes the consequence directional: the
    // counterpart of whoever disconnects may not approach again. It is a remedy
    // with a lasting effect on somebody else, not a window being closed.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    await userEvent.click(await screen.findByRole("button", { name: /^disconnect$/i }));
    expect(pushesOf(channel, "disconnect")).toEqual([]);

    await userEvent.click(screen.getByRole("button", { name: /cancel/i }));
    expect(pushesOf(channel, "disconnect")).toEqual([]);

    await userEvent.click(screen.getByRole("button", { name: /^disconnect$/i }));
    await userEvent.click(screen.getByRole("button", { name: /yes, disconnect/i }));

    expect(pushesOf(channel, "disconnect")).toEqual([
      { event: "disconnect", payload: { connection_id: CONNECTION_ID } },
    ]);
  });

  it("takes one disconnect per confirmation, not one per click", async () => {
    // The confirmation is not the guard against a duplicate, and it used to be
    // treated as one: it was dismissed by the same click that sent the push, so
    // the "Disconnect" button was back on screen with the first answer still
    // out and confirming again sent a second `disconnect` for a conversation
    // the first one had already closed. The server answers that one `conflict`,
    // which this surface would then render beside a conversation that did in
    // fact end.
    //
    // Both controls close while an answer is in flight now, which is
    // `IncomingRequest`'s shape in `peers-route.tsx` — the same defect class
    // "takes one answer per request, not one per click" pins a few blocks up.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    await confirmDisconnect();
    await confirmDisconnect();

    expect(pushesOf(channel, "disconnect")).toEqual([
      { event: "disconnect", payload: { connection_id: CONNECTION_ID } },
    ]);

    // Still the confirmation, and nothing on it is live: the server has not
    // answered, so there is no state to go back to yet.
    expect(screen.getByRole("button", { name: /yes, disconnect/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /cancel/i })).toBeDisabled();
  });

  it("takes the other party's messages off the screen, because the server does", async () => {
    // `Peers.list_messages/2` reads the whole conversation while it is open
    // and, once disconnected, **each party's own messages and only their own**
    // — R15's remedy, which `peers_test.exs` asserts with a row count as the
    // control for nothing having been deleted.
    //
    // The client held a cache from while it was open and merged the new history
    // into it, so the counterpart's messages stayed rendered: the enforcement
    // held on the wire and not on the screen. It now **replaces** rather than
    // merges once `open` is false, and re-asks when the flag flips — the merge
    // exists to catch a push that raced the reply, and nothing can be pushed to
    // a conversation that is closed.
    const { channel, server } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID, [
      messageWire({ author_id: PEER_ID, body: "theirs, from before" }),
      mineWire(),
    ]);

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });

    await userEvent.click(await screen.findByRole("button", { name: /^disconnect$/i }));
    await userEvent.click(screen.getByRole("button", { name: /yes, disconnect/i }));

    const closed = conversationWire({
      open: false,
      disconnected_at: "2026-07-28T09:40:00Z",
      disconnected_by_id: PERSON_ID,
    });
    answer(channel, "disconnect", "ok", closed);
    await server.answerLists(["list_conversations"], { conversations: [closed] });

    // It asks again, because a closed conversation is a different answer.
    await awaitPushes(channel, "history", 2);
    answer(channel, "history", "ok", { messages: [mineWire()] });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });
    expect(messageBodies()[0]).toContain("mine, from before");
    expect(screen.queryByText(/theirs, from before/)).toBeNull();
  });

  it("closes that conversation and leaves the rest of the surface alone", async () => {
    // The whole of why this is one topic. A room channel stops on revocation
    // because the topic *is* the room; stopping here would take down every
    // other conversation this person has — so the channel is not left, and the
    // other conversation is still sendable afterwards.
    const other = conversationWire({
      connection_id: OTHER_CONNECTION_ID,
      peer_id: OTHER_PEER_ID,
    });
    const { channel, server } = await openPeers({
      conversations: [conversationWire(), other],
    });

    await openConversation(channel, PEER_ID, [
      messageWire({ author_id: PEER_ID, body: "theirs" }),
    ]);

    await userEvent.click(await screen.findByRole("button", { name: /^disconnect$/i }));
    await userEvent.click(screen.getByRole("button", { name: /yes, disconnect/i }));

    const closed = conversationWire({
      open: false,
      disconnected_at: "2026-07-28T09:40:00Z",
      disconnected_by_id: PERSON_ID,
    });
    answer(channel, "disconnect", "ok", closed);
    await server.answerLists(["list_conversations"], { conversations: [closed, other] });

    await awaitPushes(channel, "history", 2);
    answer(channel, "history", "ok", { messages: [] });

    expect(await screen.findByText(/you ended it/i)).toBeInTheDocument();
    await waitFor(() => {
      expect(composer()).toBeDisabled();
    });

    // The channel is still here, and so is the other conversation.
    expect(channel.leaves).toBe(0);

    await openConversation(channel, OTHER_PEER_ID);

    await userEvent.type(await screen.findByLabelText(/^message$/i), "still talking");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));

    expect(pushesOf(channel, "send")).toEqual([
      {
        event: "send",
        payload: { connection_id: OTHER_CONNECTION_ID, body: "still talking" },
      },
    ]);
  });

  it("keeps a closed conversation listed, because each party keeps their own", async () => {
    // Nothing is deleted (KTD21 reserves deletion for erasure): after a
    // disconnect each party reads their own messages and only their own, so a
    // list that dropped closed conversations would leave those messages with
    // nothing to reach them by.
    const { channel } = await openPeers({
      conversations: [
        conversationWire({
          open: false,
          disconnected_at: "2026-07-28T09:40:00Z",
          disconnected_by_id: PEER_ID,
        }),
      ],
    });

    await openConversation(channel, PEER_ID, [mineWire({ body: "mine, kept" })]);

    expect(await screen.findByText(/mine, kept/)).toBeInTheDocument();
    expect(composer()).toBeDisabled();
    expect(screen.queryByRole("button", { name: /^disconnect$/i })).toBeNull();
  });
});

describe("the surface with nothing in it", () => {
  it("says so rather than rendering four empty lists", async () => {
    await openPeers();

    expect(await screen.findByText(/nobody right now/i)).toBeInTheDocument();
    expect(screen.getByText(/nobody has asked you to connect/i)).toBeInTheDocument();
    expect(screen.getByText(/you have not asked anybody/i)).toBeInTheDocument();
    expect(screen.getByText(/no conversations yet/i)).toBeInTheDocument();
  });

  it("ignores a push in a shape this client was not promised", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await openConversation(channel, PEER_ID);

    act(() => {
      channel.emit("peer_message", { message_id: 7, body: null });
    });

    expect(messageBodies()).toHaveLength(0);
  });
});
