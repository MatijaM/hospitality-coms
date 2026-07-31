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
import { roomFallbackLabel, roomTopic } from "./room";
import type { RoomStore } from "./room-store";
import { createMemoryRoomStore } from "./room-store";

const VENUE_ID = "11111111-1111-4111-8111-111111111111";
const SHIFT_ROOM_ID = "22222222-2222-4222-8222-222222222222";
const OWN_ENGAGEMENT_ID = "33333333-3333-4333-8333-333333333333";
const OTHER_ENGAGEMENT_ID = "44444444-4444-4444-8444-444444444444";

const venueRoom: RoomRef = { kind: "venue", id: VENUE_ID };
const shiftRoom: RoomRef = { kind: "shift", id: SHIFT_ROOM_ID };

function entry(
  ref: RoomRef,
  barred: RoomEntry["barred"] = null,
  name: string | null = null,
): RoomEntry {
  return { ref, barred, name };
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
    clear: () => {
      held.clear();
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

/**
 * Opens a listed room and answers its join, as the server would.
 *
 * Every room in this file is opened from the recently-opened list with no name
 * anywhere — the fake API's `read` fails by default, so the browse list never
 * loads — which means every row here renders under `roomFallbackLabel`. That is
 * navigation rather than an assertion, so it is derived; what the fallback
 * actually reads is pinned against literals in `room.test.ts`.
 */
async function open(
  socket: ReturnType<typeof fakeSocketFactory>["socket"],
  ref: RoomRef,
  reply: object = { venue_id: VENUE_ID, engagement_id: OWN_ENGAGEMENT_ID },
): Promise<FakeChannel> {
  await userEvent.click(
    await screen.findByRole("button", {
      name: new RegExp(`^open ${roomFallbackLabel(ref)}$`, "i"),
    }),
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

/**
 * The open room's header when nothing in this client knows the room's name.
 *
 * `room-lists.test.tsx` has the live and the stored halves, because it has
 * lists. This file has neither — the fake API's `read` fails, so the browse
 * list never loads, and every entry here is stored with `name: null` — which
 * makes it the one place the third step of `roomLabel`'s order is reached on a
 * real screen. It is also the step that was the reported bug's near miss: the
 * header used to be the whole uuid, and a fallback that rendered nothing at all
 * would satisfy "there is no uuid here" just as well.
 */
describe("what the open room's header is called with nothing to call it", () => {
  /** The panel, found through the composer rather than by the name under test. */
  function openRoomPanel(): HTMLElement {
    const panel = screen.getByLabelText(/^message$/i).closest("section");

    if (panel === null) throw new Error("no open room on screen");

    return panel;
  }

  it("falls back to the kind and a short id, and never to nothing", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);

    await open(socket, venueRoom);

    const panel = openRoomPanel();
    const heading = within(panel).getByRole("heading", { level: 2 }).textContent;

    // The literal, not `roomFallbackLabel(venueRoom)`: deriving the expected
    // value from the function under test agrees with itself for any value,
    // which is what an empty fallback would exploit.
    expect(heading).toBe("venue room 11111111");
    expect(panel).toHaveAccessibleName("venue room 11111111");
    expect(panel.outerHTML).not.toContain(VENUE_ID);
  });

  it("says which kind of room it is even when that is all the name says", async () => {
    // The kind moved from the heading to the line under it, where the uuid was.
    // In this state `roomFallbackLabel` carries it too, so the two agree — the
    // control is the shift room, which reads differently in both places from
    // the venue room above and would not if the kind had been dropped.
    const { socket } = renderRooms([entry(shiftRoom)]);

    await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    const panel = openRoomPanel();

    expect(within(panel).getByRole("heading", { level: 2 })).toHaveTextContent(
      "shift room 22222222",
    );
    expect(within(panel).getByText("Shift room")).toBeVisible();
    expect(panel.outerHTML).not.toContain(SHIFT_ROOM_ID);
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

  it("takes the stale refusal off the screen when the bar is cleared", async () => {
    // "Check again" re-enables the composer. Leaving the sentence that closed
    // it sitting above the now-usable input says the room is still refusing,
    // which is the opposite of what the button just did.
    const { socket } = renderRooms([entry(shiftRoom)]);
    const channel = await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });

    await userEvent.type(composer(), "still here?");
    await userEvent.click(sendButton());
    act(() => {
      channel.replyToLast("error", refusal("gone"));
    });
    await screen.findByRole("status");

    await userEvent.click(screen.getByRole("button", { name: /check again/i }));

    expect(composer()).toBeEnabled();
    expect(screen.queryByRole("alert")).toBeNull();
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

  it("keeps what was typed, so a refusal does not eat the message", async () => {
    // The composer cleared on submit rather than on success, so every refusal
    // above silently threw away what the worker wrote. They then read a
    // sentence explaining why it failed, with nothing left to try again.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "kitchen is short tonight");
    await userEvent.click(sendButton());
    act(() => {
      channel.replyToLast("error", refusal("bad_request"));
    });
    await screen.findByRole("alert");

    expect(composer()).toHaveValue("kitchen is short tonight");
  });

  it("clears what was typed once the server has taken it", async () => {
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "on my way");
    await userEvent.click(sendButton());
    act(() => {
      channel.replyToLast("ok", {
        id: "aaaaaaaa-0000-4000-8000-00000000000a",
        body: "on my way",
        sent_at: "2026-07-28T09:00:00Z",
        author_engagement_id: OWN_ENGAGEMENT_ID,
        author_display_name: "Captain Nemo",
        author_role_label: "Head Chef",
      });
    });

    await waitFor(() => {
      expect(composer()).toHaveValue("");
    });
  });

  it("takes one message per click while a send is in flight", async () => {
    // `Composer`'s disabled condition has three clauses and this is the one
    // nothing asserted: every other send test replies immediately, so the
    // window between the click and the reply was never looked at.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "on my way");
    await userEvent.click(sendButton());

    expect(composer()).toBeDisabled();
    expect(sendButton()).toBeDisabled();

    await userEvent.click(sendButton());

    expect(channel.pushed).toHaveLength(1);
  });

  it("closes the composer when the server says this session is not in the room", async () => {
    // `unauthorized` on a send is not a property of the room, so it sets no
    // bar — and the composer stayed live, so somebody removed from a room
    // could keep typing into it and keep being refused.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    await userEvent.type(composer(), "anyone about?");
    await userEvent.click(sendButton());
    act(() => {
      channel.replyToLast("error", refusal("unauthorized"));
    });

    await screen.findByText(/no longer open to you/i);

    expect(composer()).toBeDisabled();
    expect(sendButton()).toBeDisabled();
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

describe("re-opening a room", () => {
  it("joins again, rather than doing nothing because the key did not change", async () => {
    // The one legitimate retry in this surface is the worker asking. It was a
    // no-op: `RoomsRoute` keyed `RoomView` on the room alone, so re-opening
    // the room already open set the same state and React kept the mount. That
    // made every "open it again to check" correction a dead end.
    const { socket } = renderRooms([entry(venueRoom)]);
    const topic = roomTopic(venueRoom);

    await userEvent.click(
      await screen.findByRole("button", { name: /open .*venue room/i }),
    );
    const first = await waitFor(() => {
      const opened = socket.channelFor(topic);
      if (opened === undefined) throw new Error("nothing joined");

      return opened;
    });

    act(() => {
      first.joinPush.trigger("error", refusal("unauthorized"));
    });
    expect(await screen.findByRole("alert")).toHaveTextContent(/not in this room/i);

    await userEvent.click(screen.getByRole("button", { name: /open .*venue room/i }));

    await waitFor(() => {
      expect(socket.channelsFor(topic)).toHaveLength(2);
    });
    // The first channel was left when it was refused, and re-opening did not
    // resurrect it: the second join is a new channel, asked once.
    expect(first.joins).toBe(1);
    expect(socket.channelsFor(topic)[1]?.joins).toBe(1);
  });

  it("does not clear what it learned, so a closed room stays closed", async () => {
    // Re-opening asks the server again about *access*. It is not a way to
    // un-learn that the room is closed to new messages — that is what "Check
    // again" is for, and conflating them would defeat the closed-room render.
    const { socket, store } = renderRooms([entry(shiftRoom, "room_closed")]);

    await open(socket, shiftRoom, {
      shift_room_id: SHIFT_ROOM_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });
    await userEvent.click(screen.getByRole("button", { name: /open .*shift room/i }));

    expect(store.read()).toEqual([entry(shiftRoom, "room_closed")]);
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
        author_display_name: "Captain Nemo",
        author_role_label: "Head Chef",
      });
      channel.emit("message", {
        id: "aaaaaaaa-0000-4000-8000-000000000002",
        body: "i can stay",
        sent_at: "2026-07-28T09:01:00Z",
        author_engagement_id: OWN_ENGAGEMENT_ID,
        author_display_name: "Captain Nemo",
        author_role_label: "Bartender",
      });
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(2);
    });
    const bodies = messageBodies();

    // Attribution is who they are, what they do here, and the engagement
    // (KTD15b, #66, #65). This session's own engagement id came back on the
    // join reply, so it can mark its own — and somebody else's line leads with
    // their name, then the venue's own label for them, then the shortened
    // engagement id, because neither of the first two is unique. The full id is
    // still never rendered.
    expect(bodies[0]).toContain("kitchen is short tonight");
    expect(bodies[0]).toMatch(
      new RegExp(`^Captain Nemo · Head Chef · ${OTHER_ENGAGEMENT_ID.slice(0, 8)}`),
    );
    expect(bodies[0]).not.toContain(OTHER_ENGAGEMENT_ID);
    expect(bodies[1]).toMatch(/^You/);
    expect(bodies[1]).not.toContain("Captain Nemo");
    expect(bodies[1]).not.toContain("Bartender");
    expect(bodies[1]).toContain("i can stay");
  });

  it("names an author whose engagement has ended, from what the server sent", async () => {
    // #66's and #65's argument for the server carrying both. A venue room keeps
    // full history, so a message from somebody no longer on the roll is
    // ordinary — and this client holds no roll to join against anyway. Both
    // values are on the message, so the only way this can be wrong is the
    // server getting it wrong, which is where `rooms_test.exs` asserts it.
    //
    // An erased author reads as **both** constants, which is deliberate: who
    // they were and what they did are two facts and the server keeps two
    // separate strings for them.
    const { socket } = renderRooms([entry(venueRoom)]);
    const channel = await open(socket, venueRoom);

    act(() => {
      channel.emit("message", {
        id: "aaaaaaaa-0000-4000-8000-000000000009",
        body: "handing over",
        sent_at: "2026-07-28T08:00:00Z",
        author_engagement_id: OTHER_ENGAGEMENT_ID,
        author_display_name: "Former colleague",
        author_role_label: "Former team member",
      });
    });

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });

    expect(messageBodies()[0]).toMatch(
      new RegExp(
        `^Former colleague · Former team member · ${OTHER_ENGAGEMENT_ID.slice(0, 8)}`,
      ),
    );
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
      author_display_name: "Captain Nemo",
      author_role_label: "Head Chef",
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

/**
 * **Three tests were deleted from here by #80 rather than rewritten**, and the
 * accounting is here because a deletion that leaves no note reads the same as
 * one that lost coverage.
 *
 * They drove the paste box: it added a room by its id, it lowercased what was
 * typed, and it refused a non-id with an alert. All three asserted a rule that
 * still holds, and every one of those rules is still pinned — one layer down,
 * at the layer where it now lives. `room.test.ts` holds `normaliseRoomId`'s
 * lowercasing with the whole `Phoenix.PubSub` argument and the resulting topic
 * string asserted, and its refusal of a near miss; `room-store.test.ts` holds
 * both again at the decoder, which #80 left as the **only** untrusted way an id
 * reaches a topic.
 *
 * What genuinely went with the form is the alert — "That is not an id" — and
 * nothing replaces it, because nothing asks for an id. A rejected entry in the
 * stored list is dropped silently and correctly: it is not somebody's typo.
 */
describe("the list itself", () => {
  it("offers one control per row, and it is the one that opens the room", async () => {
    // There was a "Forget" beside every "Open". It went, and the list is
    // bounded instead — `room-store.test.ts` holds the eviction.
    //
    // "No Forget button" passes against a panel that rendered nothing at all,
    // so the control is in the same test: the list is found by its own label,
    // both rows are counted, and each is asserted to carry exactly one button.
    renderRooms([entry(venueRoom), entry(shiftRoom)]);

    const list = await screen.findByRole("list", { name: /recently opened chats/i });
    const rows = within(list).getAllByRole("listitem");

    expect(rows).toHaveLength(2);
    for (const row of rows) {
      expect(within(row).getAllByRole("button")).toHaveLength(1);
    }

    expect(within(list).queryByRole("button", { name: /forget/i })).toBeNull();
    expect(within(list).getAllByRole("button", { name: /^open /i })).toHaveLength(2);
  });

  it("puts no uuid in a row, even for a room it has never had a name for", async () => {
    // The report, at the surface. These two rooms have no stored name and no
    // live one — this file's fake `read` fails — so they are the degenerate
    // case, and even it does not render an id.
    renderRooms([entry(venueRoom), entry(shiftRoom)]);

    const list = await screen.findByRole("list", { name: /recently opened chats/i });

    expect(list.textContent).not.toContain(VENUE_ID);
    expect(list.textContent).not.toContain(SHIFT_ROOM_ID);
    // The control: the rows are there and say something, so the absences above
    // are not passing against an empty list.
    expect(list.textContent).toContain("venue room 11111111");
    expect(list.textContent).toContain("shift room 22222222");
  });
});
