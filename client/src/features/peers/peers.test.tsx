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

/** `rendered_peer/1`. */
function peerWire(overrides: Record<string, unknown> = {}) {
  return {
    person_id: PEER_ID,
    venue_id: VENUE_ID,
    venue_name: "The Anchor",
    role_label: "Bartender",
    visible_from: "2026-07-01T00:00:00Z",
    visible_until: "2026-09-01T00:00:00Z",
    ...overrides,
  };
}

/** `rendered_request/1`. */
function requestWire(overrides: Record<string, unknown> = {}) {
  return {
    request_id: REQUEST_ID,
    requester_id: PERSON_ID,
    addressee_id: PEER_ID,
    state: "pending",
    requested_at: "2026-07-28T09:00:00Z",
    accepted_at: null,
    declined_at: null,
    ...overrides,
  };
}

/** `rendered_conversation/1`, which is also the `accept` and `disconnect` reply. */
function conversationWire(overrides: Record<string, unknown> = {}) {
  return {
    connection_id: CONNECTION_ID,
    peer_id: PEER_ID,
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
    body: "are you on tonight?",
    sent_at: "2026-07-28T09:10:00Z",
    ...overrides,
  };
}

/**
 * The `peer_message` push, which stamps its instant `at` and not `sent_at`.
 *
 * The difference is real and is `PeerChannel.stamped/1`: a push is
 * `HospitalityComs.Peers`' announcement shape, and every announcement on that
 * topic says `at`.
 */
function messageNotice(overrides: Record<string, unknown> = {}) {
  const { sent_at: at, ...rest } = messageWire(overrides);

  return { ...rest, at };
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
      Promise.resolve(ok({ id: personId, email: "worker@example.com" })),
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

/**
 * Answers the list pushes the client has issued and not had answered.
 *
 * A cursor rather than "the last one", because a notice makes the client ask
 * again: `peer_connected` re-asks two lists in one handler, and a test that
 * answered only the most recent push would leave the other hanging.
 */
function serverFor(channel: FakeChannel) {
  let cursor = 0;

  return {
    async answerLists(lists: Lists): Promise<void> {
      await waitFor(() => {
        expect(
          channel.sent.slice(cursor).some((sent) => sent.event.startsWith("list_")),
        ).toBe(true);
      });

      act(() => {
        for (; cursor < channel.sent.length; cursor += 1) {
          const sent = channel.sent[cursor];
          if (sent === undefined) continue;

          switch (sent.event) {
            case "list_peers":
              sent.push.trigger("ok", { peers: lists.peers ?? [] });
              break;
            case "list_requests":
              sent.push.trigger("ok", {
                incoming: lists.incoming ?? [],
                outgoing: lists.outgoing ?? [],
              });
              break;
            case "list_conversations":
              sent.push.trigger("ok", { conversations: lists.conversations ?? [] });
              break;
            default:
              break;
          }
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
  await server.answerLists(lists);

  return { socket, channel, server };
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

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

    await userEvent.click(
      screen.getByRole("button", { name: /open conversation b2b2b2b2/i }),
    );

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

  it("carries the session token as authToken and never in the socket params", async () => {
    const { socket } = await openPeers();

    expect(socket.options).toEqual({ authToken: "c2Vzc2lvbg" });
    expect(socket.endpoint).toBe("/socket/person");
    expect(socket.channels[0]?.params).toBeUndefined();
  });
});

describe("a pending outbound request renders as pending until answered", () => {
  it("asks, shows pending, and only stops when the server says otherwise", async () => {
    // Issue #12's first scenario, end to end.
    const { channel, server } = await openPeers({ peers: [peerWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /ask c3c3c3c3 to connect/i }),
    );

    expect(pushesOf(channel, "request")).toEqual([
      { event: "request", payload: { person_id: PEER_ID } },
    ]);

    answer(channel, "request", "ok", requestWire());
    await server.answerLists({ peers: [peerWire()], outgoing: [requestWire()] });

    const sent = within(await screen.findByRole("list", { name: /requests you sent/i }));
    expect(sent.getByText(/^Pending$/)).toBeInTheDocument();
    expect(sent.getByText(/waiting for them to answer/i)).toBeInTheDocument();

    // And the peer entry stops offering the ask, because the server just said
    // there is one outstanding.
    expect(screen.queryByRole("button", { name: /ask c3c3c3c3 to connect/i })).toBeNull();

    // It stays pending. Nothing here decides that time has passed: `:lapsed`
    // and `:accepted` are both the server's, derived at the instant it is
    // asked.
    act(() => {
      channel.emit("peer_message", messageNotice({ connection_id: OTHER_CONNECTION_ID }));
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

    await server.answerLists({
      peers: [peerWire()],
      outgoing: [requestWire({ state: "accepted", accepted_at: "2026-07-28T09:05:00Z" })],
      conversations: [conversationWire()],
    });

    expect(await screen.findByText(/^Accepted$/)).toBeInTheDocument();
    expect(screen.queryByText(/^Pending$/)).toBeNull();
    expect(
      within(screen.getByRole("list", { name: /your conversations/i })).getByRole(
        "button",
        { name: /open conversation c3c3c3c3/i },
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
});

describe("two workers exchanging peer messages see them in order", () => {
  it("loads the history, appends what arrives, and orders by the server's instant", async () => {
    // Issue #12's second scenario. The ordering key is `sent_at`, not arrival:
    // a message that reaches this client late — a reconnect delivering a
    // backlog, or the two paths a sender's own message takes — belongs where
    // the server stamped it.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
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
    // counterpart's id is already in the peer list. There is still no name.
    expect(bodies[1]).toMatch(/^c3c3c3c3/);
    expect(bodies[1]).not.toContain(PEER_ID);
    expect(bodies[2]).toMatch(/^You/);
  });

  it("sends under the event and payload the channel handles", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

    await userEvent.type(await screen.findByLabelText(/^message$/i), "on my way");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));

    expect(pushesOf(channel, "send")).toEqual([
      {
        event: "send",
        payload: { connection_id: CONNECTION_ID, body: "on my way" },
      },
    ]);
  });

  it("shows the sender's own message once, though it arrives twice", async () => {
    // `announce/2` publishes to both parties and a channel is subscribed to its
    // own topic, so the reply to `send` and the `peer_message` push are the same
    // row down two paths — under two different keys for its instant.
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

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

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

    await userEvent.type(await screen.findByLabelText(/^message$/i), "kitchen is short");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));
    answer(channel, "send", "error", refusal("unprocessable_entity"));

    await screen.findByRole("alert");
    expect(composer()).toHaveValue("kitchen is short");
  });
});

describe("a refusal on the peer channel", () => {
  it("says why in this client's words, never the server's log sentence", async () => {
    const { channel } = await openPeers({ peers: [peerWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /ask c3c3c3c3 to connect/i }),
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
      await screen.findByRole("button", { name: /ask c3c3c3c3 to connect/i }),
    );
    answer(channel, "request", "error", refusal("not_found"));

    expect(await screen.findByRole("alert")).toHaveTextContent(/cannot tell you which/i);
  });

  it("renders the server's per-field messages, which name what was typed", async () => {
    const { channel } = await openPeers({ conversations: [conversationWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

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

  it("asks the server again when a send says the conversation is closed", async () => {
    // The one real difference from the rooms. A room had to *remember*
    // `room_closed`, because nothing on the wire carries a shift room's
    // `closes_at`; here `list_conversations` carries `open`, so the honest
    // answer to this refusal is to ask and render what comes back. Nothing is
    // inferred and nothing is stored.
    const { channel, server } = await openPeers({ conversations: [conversationWire()] });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

    await userEvent.type(await screen.findByLabelText(/^message$/i), "still there?");
    await userEvent.click(screen.getByRole("button", { name: /^send$/i }));
    answer(channel, "send", "error", refusal("conflict"));

    await server.answerLists({
      conversations: [
        conversationWire({
          open: false,
          disconnected_at: "2026-07-28T09:20:00Z",
          disconnected_by_id: PEER_ID,
        }),
      ],
    });

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
    const { channel, server } = await openPeers({
      incoming: [requestWire({ requester_id: PEER_ID, addressee_id: PERSON_ID })],
    });

    await userEvent.click(
      await screen.findByRole("button", { name: /accept c3c3c3c3/i }),
    );

    expect(pushesOf(channel, "accept")).toEqual([
      { event: "accept", payload: { request_id: REQUEST_ID } },
    ]);

    // `accept` replies with the conversation rather than the request, through
    // `rendered_connection/2`.
    answer(channel, "accept", "ok", conversationWire());
    await server.answerLists({ conversations: [conversationWire()] });

    expect(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    ).toBeInTheDocument();
    expect(screen.getByText(/nobody has asked you to connect/i)).toBeInTheDocument();
  });

  it("declines, and says so in a sentence that is not an error", async () => {
    const { channel, server } = await openPeers({
      incoming: [requestWire({ requester_id: PEER_ID, addressee_id: PERSON_ID })],
    });

    await userEvent.click(
      await screen.findByRole("button", { name: /decline c3c3c3c3/i }),
    );

    expect(pushesOf(channel, "decline")).toEqual([
      { event: "decline", payload: { request_id: REQUEST_ID } },
    ]);

    answer(
      channel,
      "decline",
      "ok",
      requestWire({
        requester_id: PEER_ID,
        addressee_id: PERSON_ID,
        state: "declined",
        declined_at: "2026-07-28T09:30:00Z",
      }),
    );
    await server.answerLists({});

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
      incoming: [
        requestWire({
          requester_id: PEER_ID,
          addressee_id: PERSON_ID,
          state: "lapsed",
        }),
      ],
    });

    expect(
      await screen.findByRole("button", { name: /decline c3c3c3c3/i }),
    ).toBeEnabled();

    await userEvent.click(screen.getByRole("button", { name: /accept c3c3c3c3/i }));
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

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

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

  it("closes that conversation and leaves the rest of the surface alone", async () => {
    // The whole of why this is one topic. A room channel stops on revocation
    // because the topic *is* the room; stopping here would take down every
    // other conversation this person has — so the channel is not left, and the
    // other conversation is still sendable afterwards.
    const conversations = [
      conversationWire(),
      conversationWire({ connection_id: OTHER_CONNECTION_ID, peer_id: OTHER_PEER_ID }),
    ];
    const { channel, server } = await openPeers({ conversations });

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

    await userEvent.click(await screen.findByRole("button", { name: /^disconnect$/i }));
    await userEvent.click(screen.getByRole("button", { name: /yes, disconnect/i }));

    const closed = conversationWire({
      open: false,
      disconnected_at: "2026-07-28T09:40:00Z",
      disconnected_by_id: PERSON_ID,
    });
    answer(channel, "disconnect", "ok", closed);
    await server.answerLists({ conversations: [closed, conversations[1] ?? {}] });

    expect(await screen.findByText(/you ended it/i)).toBeInTheDocument();
    await waitFor(() => {
      expect(composer()).toBeDisabled();
    });

    // The channel is still here, and so is the other conversation.
    expect(channel.leaves).toBe(0);

    await userEvent.click(
      screen.getByRole("button", { name: /open conversation b2b2b2b2/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

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

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", {
      messages: [messageWire({ author_id: PERSON_ID, body: "mine, kept" })],
    });

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

    await userEvent.click(
      await screen.findByRole("button", { name: /open conversation c3c3c3c3/i }),
    );
    answer(channel, "history", "ok", { messages: [] });

    act(() => {
      channel.emit("peer_message", { message_id: 7, body: null });
    });

    expect(messageBodies()).toHaveLength(0);
  });
});
