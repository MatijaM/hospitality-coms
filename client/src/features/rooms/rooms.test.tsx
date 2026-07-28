/**
 * The three things the room surfaces exist to get right.
 *
 * Driven through the real components against the fake socket in
 * `test-support/fake-socket.ts`, which models `phoenix`'s rejoin behaviour
 * rather than only its interface — the third scenario is a claim about what
 * does *not* happen, and a fake that cannot rejoin would make it vacuous.
 *
 * Every payload here is the shape `HospitalityComsWeb.RoomChannel`,
 * `VenueRoomChannel` and `ShiftRoomChannel` actually put on the wire, read out
 * of those modules rather than assumed.
 */

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";

import { App } from "../../app/app";
import { SessionProvider } from "../../session/session-context";
import { createMemoryTokenStore } from "../../session/token-store";
import { SocketProvider } from "../../socket/socket-context";
import { createFakeApi, ok, somePerson } from "../../test-support/fake-api";
import type { FakeChannel } from "../../test-support/fake-socket";
import { fakeSocketFactory } from "../../test-support/fake-socket";
import type { RoomEntry, RoomRef } from "./room";
import { roomTopic } from "./room";
import type { RoomStore } from "./room-store";
import { createMemoryRoomStore } from "./room-store";

const VENUE_ID = "11111111-1111-4111-8111-111111111111";
const SHIFT_ROOM_ID = "22222222-2222-4222-8222-222222222222";
const OWN_ENGAGEMENT_ID = "33333333-3333-4333-8333-333333333333";
const OTHER_ENGAGEMENT_ID = "44444444-4444-4444-8444-444444444444";

const venueRoom: RoomRef = { kind: "venue", id: VENUE_ID };
const shiftRoom: RoomRef = { kind: "shift", id: SHIFT_ROOM_ID };

function entry(ref: RoomRef, barred: RoomEntry["barred"] = null): RoomEntry {
  return { ref, barred };
}

function renderRooms(
  entries: readonly RoomEntry[],
  onWrite?: (written: readonly RoomEntry[]) => void,
) {
  const { socket, createSocket } = fakeSocketFactory();
  const held = createMemoryRoomStore(entries);
  const store: RoomStore = {
    read: () => held.read(),
    write: (next) => {
      held.write(next);
      onWrite?.(next);
    },
  };
  const api = createFakeApi({ currentPerson: () => Promise.resolve(ok(somePerson)) });

  render(
    <MemoryRouter initialEntries={["/rooms"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <SocketProvider createSocket={createSocket}>
          <App roomStore={store} />
        </SocketProvider>
      </SessionProvider>
    </MemoryRouter>,
  );

  return { socket, store };
}

/** Opens a listed room and answers its join, as the server would. */
async function open(
  socket: ReturnType<typeof fakeSocketFactory>["socket"],
  ref: RoomRef,
  reply: object = { venue_id: VENUE_ID, engagement_id: OWN_ENGAGEMENT_ID },
): Promise<FakeChannel> {
  await userEvent.click(
    await screen.findByRole("button", { name: new RegExp(`open .*${ref.id}`, "i") }),
  );

  const channel = await waitFor(() => {
    const opened = socket.channelFor(roomTopic(ref));
    if (opened === undefined) throw new Error(`nothing joined ${roomTopic(ref)}`);

    return opened;
  });

  act(() => {
    channel.joinPush.trigger("ok", reply);
  });

  return channel;
}

function composer(): HTMLInputElement {
  return screen.getByLabelText(/^message$/i);
}

function sendButton(): HTMLElement {
  return screen.getByRole("button", { name: /^send$/i });
}

/** The room's own message list, which is not the list of rooms. */
function messageBodies(): string[] {
  return within(screen.getByRole("list", { name: /messages/i }))
    .queryAllByRole("listitem")
    .map((item) => item.textContent);
}

/** The envelope `ErrorEnvelope.new/2` builds, with a message nobody renders. */
function refusal(code: string, message = "SERVER-SIDE LOG SENTENCE") {
  return { error: { code, message } };
}

describe("the topic a room is joined on", () => {
  it("is the one PersonSocket routes, with the id as the suffix", async () => {
    const { socket } = renderRooms([entry(venueRoom), entry(shiftRoom)]);

    await open(socket, venueRoom);
    await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    expect(socket.channels.map((channel) => channel.topic)).toEqual([
      `venue_room:${VENUE_ID}`,
      `shift_room:${SHIFT_ROOM_ID}`,
    ]);
  });

  it("carries the session token as authToken and never in the socket params", async () => {
    // The P0 the foundation fixed, asserted where the socket is finally wired
    // up: `Socket.endPointURL()` appends `params()` to the query string, so a
    // token there is a live credential in every access log on the path.
    const { socket } = renderRooms([entry(venueRoom)]);

    await open(socket, venueRoom);

    expect(socket.options).toEqual({ authToken: "c2Vzc2lvbg" });
    expect(socket.endpoint).toBe("/socket/person");
    expect(socket.channels[0]?.params).toBeUndefined();
  });
});

describe("a closed room", () => {
  it("renders its state and disables the composer, before anything is typed", async () => {
    // The room is readable and not writable, which is U6's two predicates and
    // KTD6b: a roster period that has elapsed still earns the reading. The
    // client knows because it was told once and remembered — nothing on the
    // wire carries `closes_at`.
    const { socket } = renderRooms([entry(shiftRoom, "room_closed")]);

    await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    expect(await screen.findByText(/this room is closed/i)).toBeInTheDocument();
    expect(composer()).toBeDisabled();
    expect(sendButton()).toBeDisabled();
    // And it did not have to lose a message to find out.
    expect(socket.channelFor(roomTopic(shiftRoom))?.sent).toEqual([]);
  });

  it("says so for a session that is off the roster, which is a different sentence", async () => {
    const { socket } = renderRooms([entry(shiftRoom, "not_rostered")]);

    await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    expect(await screen.findByText(/not on this shift's roster/i)).toBeInTheDocument();
    expect(composer()).toBeDisabled();
  });

  it("becomes closed when the server refuses a send with `gone`, and stays closed", async () => {
    const { socket, store } = renderRooms([entry(shiftRoom)]);
    const channel = await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    await userEvent.type(composer(), "anyone still here?");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("error", refusal("gone"));
    });

    expect(await screen.findByRole("status")).toHaveTextContent(/this room is closed/i);
    expect(composer()).toBeDisabled();
    // Remembered, so a reload does not make the worker rediscover it by
    // losing another message.
    expect(store.read()).toEqual([entry(shiftRoom, "room_closed")]);
  });

  it("offers a way to unlearn it, because closure was inferred and can be wrong", async () => {
    const { socket, store } = renderRooms([entry(shiftRoom, "room_closed")]);

    await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });
    await userEvent.click(screen.getByRole("button", { name: /check again/i }));

    expect(composer()).toBeEnabled();
    expect(store.read()).toEqual([entry(shiftRoom, null)]);
  });
});

describe("a rejected send", () => {
  it("says why, in this client's words rather than the server's log sentence", async () => {
    const { socket } = renderRooms([entry(shiftRoom)]);
    const channel = await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    await userEvent.type(composer(), "table four is ready");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("error", refusal("forbidden"));
    });

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/no longer on this shift's roster/i);
    // The envelope's own documentation says `message` is for a human reading a
    // log. Rendering it would put untranslated internal copy in front of
    // somebody trying to start a shift.
    expect(alert).not.toHaveTextContent(/SERVER-SIDE LOG SENTENCE/);
  });

  it("renders the server's per-field messages, which name what was typed", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "x");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("error", {
        error: {
          code: "unprocessable_entity",
          message: "the message was rejected",
          fields: { body: ["should be at most 4000 character(s)"] },
        },
      });
    });

    expect(
      await screen.findByText(/should be at most 4000 character\(s\)/i),
    ).toBeInTheDocument();
  });

  it("leaves the composer usable when the refusal was about the message", async () => {
    // `unprocessable_entity` says nothing about the room, so barring the
    // composer over one would make a typo look like a closure.
    const { socket, store } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "x");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("error", {
        error: { code: "unprocessable_entity", message: "no", fields: { body: ["no"] } },
      });
    });

    await screen.findAllByRole("alert");

    expect(composer()).toBeEnabled();
    expect(store.read()).toEqual([entry(venueRoom, null)]);
  });

  it("says something for a refusal that is not the envelope at all", async () => {
    // `phoenix` itself refuses with `%{reason: "unmatched topic"}` and, at
    // `max_channels_per_transport`, `%{reason: "too many channels joined"}`.
    // Neither is an `ErrorEnvelope`, and silence is the one wrong answer.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "hello");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("error", { reason: "too many channels joined" });
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /does not understand.*nothing was sent/i,
    );
  });

  it("says something when the server never answers, and does not call it a refusal", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "hello");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("timeout");
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(/did not answer in time/i);
    expect(composer()).toBeEnabled();
  });

  it("sends the body under the event name the channel handles", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "on my way");
    await userEvent.click(sendButton());

    expect(channel.pushed).toEqual([{ event: "send", payload: { body: "on my way" } }]);
  });
});

describe("the revocation event", () => {
  it("removes the room from the list, and does not retry into the refusal", async () => {
    const { socket, store } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      channel.emit("access_revoked", {
        venue_id: VENUE_ID,
        engagement_id: OWN_ENGAGEMENT_ID,
        at: "2026-07-28T09:00:00Z",
      });
    });

    // The room is gone, from the surface and from the bookmark list.
    await waitFor(() => {
      expect(screen.queryByRole("button", { name: /open .*venue room/i })).toBeNull();
    });
    expect(store.read()).toEqual([]);

    // The topic was left, which is what resets `phoenix`'s rejoin timer.
    expect(channel.leaves).toBe(1);

    // And this is the part that matters. Firing the rejoin timer ten times
    // produces no further join, so there is no socket quietly hammering a
    // refusal. A room that merely disappeared from the list would pass the
    // assertions above and fail this one.
    act(() => {
      socket.fireRejoinTimers(10);
    });

    expect(channel.joins).toBe(1);
    expect(socket.channelsFor(roomTopic(venueRoom))).toHaveLength(1);
  });

  it("control: the same harness counts a rejoin on a room that was not revoked", async () => {
    // Without this, `joins === 1` above would be satisfied by a fake that
    // cannot rejoin at all — a restatement rather than a measurement.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      socket.fireRejoinTimers(1);
    });

    expect(channel.joins).toBe(2);
  });

  it("leaves the topic in the handler, before the list drops the room", async () => {
    // Dropping the room unmounts the view, and the view's cleanup leaves the
    // topic too — so `leaves === 1` alone cannot tell "left deliberately" from
    // "left by an unmount that happened to follow". This records how many
    // leaves had happened *at the moment the list changed*, which can.
    //
    // Measured: deleting the `open?.leave()` in `use-room.ts` turns the
    // expectation below from `[1]` into `[0]` while every other assertion in
    // this describe block still passes.
    const leavesWhenListChanged: number[] = [];
    const held: { channel?: FakeChannel } = {};

    const { socket } = renderRooms([entry(venueRoom)], () => {
      leavesWhenListChanged.push(held.channel?.leaves ?? -1);
    });

    held.channel = await open(socket, venueRoom);
    const opened = held.channel;

    act(() => {
      opened.emit("access_revoked", {
        venue_id: VENUE_ID,
        engagement_id: OWN_ENGAGEMENT_ID,
        at: "2026-07-28T09:00:00Z",
      });
    });

    await waitFor(() => {
      expect(screen.queryByRole("button", { name: /open .*venue room/i })).toBeNull();
    });

    expect(leavesWhenListChanged).toEqual([1]);
    expect(opened.leaves).toBe(1);
  });

  it("leaves the topic even when the notice is in a shape this client cannot read", async () => {
    // A renamed field must not become a reason to stay subscribed to a topic
    // the server has finished with.
    const { socket, store } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      channel.emit("access_revoked", { nothing: "this client was promised" });
    });

    await waitFor(() => {
      expect(store.read()).toEqual([]);
    });
    expect(channel.leaves).toBe(1);

    act(() => {
      socket.fireRejoinTimers(5);
    });
    expect(channel.joins).toBe(1);
  });
});

describe("a suspension", () => {
  it("leaves the topic but keeps the room, because the person can undo it", async () => {
    // KTD18: suspension is this person opting out of this venue's room,
    // possibly from another device. Forgetting the bookmark would make
    // resuming it a paste.
    const { socket, store } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      channel.emit("access_suspended", {
        venue_id: VENUE_ID,
        engagement_id: OWN_ENGAGEMENT_ID,
        at: "2026-07-28T09:00:00Z",
      });
    });

    expect(await screen.findByText(/you have suspended this room/i)).toBeInTheDocument();
    expect(store.read()).toEqual([entry(venueRoom, null)]);
    expect(channel.leaves).toBe(1);

    act(() => {
      socket.fireRejoinTimers(5);
    });
    expect(channel.joins).toBe(1);
  });
});

describe("a refused join", () => {
  it("says so, keeps the room listed, and asks nobody again", async () => {
    // `createSessionSocket` has already left the topic by the time this
    // arrives. The room stays in the list because a refusal enumerates nothing
    // (AE1) — this client cannot tell an ended engagement from a mistyped id,
    // so it is not entitled to throw the bookmark away.
    const { socket, store } = renderRooms([entry(venueRoom)]);

    await userEvent.click(
      await screen.findByRole("button", { name: /open .*venue room/i }),
    );

    const channel = await waitFor(() => {
      const opened = socket.channelFor(roomTopic(venueRoom));
      if (opened === undefined) throw new Error("nothing joined");

      return opened;
    });

    act(() => {
      channel.joinPush.trigger("error", refusal("unauthorized"));
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(/not in this room/i);
    expect(store.read()).toEqual([entry(venueRoom, null)]);
    expect(channel.leaves).toBe(1);

    act(() => {
      socket.fireRejoinTimers(10);
    });
    expect(channel.joins).toBe(1);
  });
});

describe("messages", () => {
  it("renders what arrives on the broadcast, marking this session's own", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      channel.emit("message", {
        id: "aaaaaaaa-0000-4000-8000-000000000001",
        body: "kitchen is short tonight",
        sent_at: "2026-07-28T09:00:00Z",
        author_engagement_id: OTHER_ENGAGEMENT_ID,
      });
      channel.emit("message", {
        id: "aaaaaaaa-0000-4000-8000-000000000002",
        body: "i can stay",
        sent_at: "2026-07-28T09:01:00Z",
        author_engagement_id: OWN_ENGAGEMENT_ID,
      });
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });
    const bodies = messageBodies();

    // Attribution is the engagement, never the person (KTD15b). This session's
    // own engagement id came back on the join reply, so it can mark its own.
    expect(bodies[0]).toContain("kitchen is short tonight");
    expect(bodies[0]).toMatch(new RegExp(`^${OTHER_ENGAGEMENT_ID.slice(0, 8)}`));
    expect(bodies[0]).not.toContain(OTHER_ENGAGEMENT_ID);
    expect(bodies[1]).toMatch(/^You/);
    expect(bodies[1]).toContain("i can stay");
  });

  it("shows a message once, though the sender receives it twice", async () => {
    // `broadcast!/3` reaches every subscriber of the topic and a channel is
    // subscribed to its own, so the reply and the broadcast are the same row.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);
    const message = {
      id: "aaaaaaaa-0000-4000-8000-000000000003",
      body: "on my way",
      sent_at: "2026-07-28T09:02:00Z",
      author_engagement_id: OWN_ENGAGEMENT_ID,
    };

    await userEvent.type(composer(), "on my way");
    await userEvent.click(sendButton());

    act(() => {
      channel.replyToLast("ok", message);
      channel.emit("message", message);
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });

    expect(messageBodies()[0]).toContain("on my way");
  });

  it("ignores a payload in a shape this client was not promised", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      channel.emit("message", { id: 7, body: null });
    });

    expect(messageBodies()).toHaveLength(0);
  });
});

describe("the list itself", () => {
  it("adds a room by its id and opens it", async () => {
    const { socket, store } = renderRooms([]);

    await userEvent.type(await screen.findByLabelText(/^id$/i), VENUE_ID);
    await userEvent.click(screen.getByRole("button", { name: /add this room/i }));

    await waitFor(() => {
      expect(socket.channelFor(roomTopic(venueRoom))).toBeDefined();
    });
    expect(store.read()).toEqual([entry(venueRoom, null)]);
  });

  it("refuses an id that is not one, rather than putting it on a socket", async () => {
    // The server answers a malformed suffix exactly as it answers an unknown
    // room, so it can say nothing useful about somebody's own typo.
    const { socket } = renderRooms([]);

    await userEvent.type(await screen.findByLabelText(/^id$/i), "not-an-id");
    await userEvent.click(screen.getByRole("button", { name: /add this room/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /should look like a uuid/i,
    );
    expect(socket.channels).toHaveLength(0);
  });

  it("leaves the topic when a room is closed by hand", async () => {
    const { socket, store } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.click(screen.getByRole("button", { name: /forget/i }));

    expect(store.read()).toEqual([]);
    expect(channel.leaves).toBe(1);
  });
});
