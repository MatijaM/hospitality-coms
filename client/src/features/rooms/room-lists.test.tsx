/**
 * The three surfaces U12's HTTP routes unlock, driven through the real
 * components against a fake `read`.
 *
 * `rooms.test.tsx` is the socket's file and is untouched by this one: it renders
 * the same surface with the default fake API, whose `read` fails, so every
 * assertion it makes about joining, sending and revocation still holds with the
 * lists absent. This file is about what the lists and the history add.
 *
 * ## The bound is the one thing here worth testing properly
 *
 * The server bounds a history read and says whether the page is the lot. What
 * this side has to get right is **only offering "load the whole history" when
 * it is not** — a control shown unconditionally tells somebody whose room holds
 * three messages that there are more, and one never shown makes the bound
 * unreachable. Both directions are asserted, and the second is the control for
 * the first.
 *
 * Every body below is the shape `HospitalityComsWeb.RoomController` renders,
 * read out of that module rather than assumed, and it goes through the real
 * decoders on its way in — so a fixture that is not the server's shape fails
 * here as `malformed_response` exactly as it would in a browser.
 */

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../../api/client";
import { App } from "../../app/app";
import { SessionProvider } from "../../session/session-context";
import { createMemoryTokenStore } from "../../session/token-store";
import { SocketProvider } from "../../socket/socket-context";
import {
  createFakeApi,
  fails,
  ok,
  offline,
  readsFrom,
  somePerson,
} from "../../test-support/fake-api";
import { fakeSocketFactory } from "../../test-support/fake-socket";
import type { RoomEntry } from "./room";
import { instantLabel, roomTopic } from "./room";
import { createMemoryRoomStore } from "./room-store";

const VENUE_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_VENUE_ID = "99999999-9999-4999-8999-999999999999";
const SHIFT_ROOM_ID = "22222222-2222-4222-8222-222222222222";
const OWN_ENGAGEMENT_ID = "33333333-3333-4333-8333-333333333333";

const VENUE_ROOMS = "/api/venue-rooms";
const SHIFT_ROOMS = `/api/venues/${VENUE_ID}/shift-rooms`;
const VENUE_HISTORY = `/api/venue-rooms/${VENUE_ID}/messages`;
const SHIFT_HISTORY = `/api/shift-rooms/${SHIFT_ROOM_ID}/messages`;

const twoVenueRooms = {
  venue_rooms: [
    { venue_id: VENUE_ID, name: "The Anchor" },
    { venue_id: OTHER_VENUE_ID, name: "The Ship" },
  ],
};

const oneShiftRoom = {
  shift_rooms: [
    {
      shift_room_id: SHIFT_ROOM_ID,
      venue_id: VENUE_ID,
      shift_type_name: "Kitchen",
      starts_at: "2026-03-09T13:00:00Z",
      ends_at: "2026-03-09T21:00:00Z",
      closes_at: "2026-03-09T21:30:00Z",
    },
  ],
};

function message(id: string, body: string) {
  return {
    id,
    body,
    sent_at: "2026-03-09T14:00:00Z",
    author_engagement_id: OWN_ENGAGEMENT_ID,
    author_display_name: "Captain Nemo",
  };
}

function renderRooms(
  bodies: Readonly<Record<string, unknown>>,
  read: ApiClient["read"] = readsFrom(bodies),
  entries: RoomEntry[] = [],
) {
  const { socket, createSocket } = fakeSocketFactory();
  const api = createFakeApi({
    currentPerson: () => Promise.resolve(ok(somePerson)),
    read,
  });

  render(
    <MemoryRouter initialEntries={["/rooms"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <SocketProvider createSocket={createSocket}>
          <App roomStore={createMemoryRoomStore(entries)} />
        </SocketProvider>
      </SessionProvider>
    </MemoryRouter>,
  );

  return { socket, read };
}

/** Opens a room from whichever list carries the named button, and answers its join. */
async function open(
  socket: ReturnType<typeof fakeSocketFactory>["socket"],
  name: RegExp,
  topic: string,
) {
  await userEvent.click(await screen.findByRole("button", { name }));

  const channel = await waitFor(() => {
    const opened = socket.channelFor(topic);
    if (opened === undefined) throw new Error(`nothing joined ${topic}`);

    return opened;
  });

  act(() => {
    channel.joinPush.trigger("ok", {
      venue_id: VENUE_ID,
      engagement_id: OWN_ENGAGEMENT_ID,
    });
  });

  return channel;
}

function messageBodies(): (string | null)[] {
  return within(screen.getByRole("list", { name: /messages/i }))
    .queryAllByRole("listitem")
    .map((item) => item.textContent);
}

describe("the list of venue rooms", () => {
  it("renders the venue's name rather than its id", async () => {
    // The whole of the first sub-item. `VenueRoom` carries a name, and
    // rendering it is what stops every room list in this client being uuid
    // prefixes — which is the single thing that made the old layout read as
    // broken.
    renderRooms({ [VENUE_ROOMS]: twoVenueRooms });

    const list = await screen.findByRole("list", { name: /venue rooms/i });

    expect(within(list).getByText("The Anchor")).toBeVisible();
    expect(within(list).getByText("The Ship")).toBeVisible();
    expect(list.textContent).not.toContain(VENUE_ID);
  });

  it("opens a browsed room on the topic PersonSocket routes, and keeps it locally", async () => {
    // A browsed room and a pasted one take the same path into a channel, and
    // the browsed one enters the local list so that `barred` and the reload
    // survival apply to it too.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: { messages: [], complete: true },
    });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    expect(await screen.findByRole("list", { name: /your rooms/i })).toHaveTextContent(
      VENUE_ID,
    );
  });

  it("says so when the list cannot be loaded, and offers to ask again", async () => {
    // A failure has to read as a failure rather than as an empty list. "You are
    // not in any venue rooms" in front of somebody who is in three is the
    // worst answer available, and it is the one a surface that ignored the
    // failure would give — which is the state `rooms.test.tsx` renders this
    // surface in, since its fake `read` fails by default.
    const read = vi.fn(() => Promise.resolve(fails<never>(offline())));
    renderRooms({}, read);

    expect(await screen.findByText(/that list could not be loaded/i)).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: /try again/i }));

    await waitFor(() => {
      expect(read).toHaveBeenCalledTimes(2);
    });
  });
});

describe("the list of shift rooms at a venue", () => {
  it("is asked for per venue and labelled with the shift type's name", async () => {
    // The second sub-item. The venue is a path segment, so there is no arity of
    // the route that spans every venue, and the label carries the type's name
    // because `ShiftRoom` has none of its own.
    const { read } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [SHIFT_ROOMS]: oneShiftRoom,
    });

    await userEvent.click(
      await screen.findByRole("button", { name: /shift rooms at the anchor/i }),
    );

    const list = await screen.findByRole("list", { name: /shift rooms at the anchor/i });

    expect(within(list).getByRole("button", { name: /kitchen/i })).toBeVisible();
    expect(list.textContent).not.toContain(SHIFT_ROOM_ID);

    expect(read).toHaveBeenCalledWith(
      SHIFT_ROOMS,
      expect.any(String),
      expect.any(Function),
    );
  });

  it("asks for nothing until a venue is chosen", async () => {
    // A request per venue on arrival is what choosing avoids, and it is the
    // control for the assertion above: a panel that fetched every venue's rooms
    // eagerly would still pass that one.
    const { read } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [SHIFT_ROOMS]: oneShiftRoom,
    });

    await screen.findByRole("list", { name: /venue rooms/i });

    expect(read).toHaveBeenCalledTimes(1);
    expect(read).not.toHaveBeenCalledWith(
      SHIFT_ROOMS,
      expect.any(String),
      expect.any(Function),
    );
  });

  it("writes when a room stops taking messages as a time, not as an instant", async () => {
    // `closes_at` is deliberately never compared against this browser's clock:
    // the demo moves the server's and not this one, so an open/closed badge
    // here would be wrong during exactly the demo the offset exists for. That
    // is an argument against comparing it and never was one against formatting
    // it — rendered raw it put `2026-03-09T21:30:00Z` in front of a worker,
    // beside a term this client had already formatted.
    //
    // No timezone is pinned here and none is needed: `instantLabel` is the
    // rendering under test, so both sides of the comparison move together with
    // whatever timezone the runner is in. What the label says in a *named* one
    // is `room.test.ts`'s question.
    renderRooms({ [VENUE_ROOMS]: twoVenueRooms, [SHIFT_ROOMS]: oneShiftRoom });

    await userEvent.click(
      await screen.findByRole("button", { name: /shift rooms at the anchor/i }),
    );

    const list = await screen.findByRole("list", { name: /shift rooms at the anchor/i });

    expect(list.textContent).not.toContain("2026-03-09T21:30:00Z");
    expect(list.textContent).toContain(`closes ${instantLabel("2026-03-09T21:30:00Z")}`);

    // The instant itself stays where a machine reads it, which is what `<time>`
    // is for.
    expect(within(list).getByText(/^closes /)).toHaveAttribute(
      "datetime",
      "2026-03-09T21:30:00Z",
    );
  });

  it("opens a shift room from the label", async () => {
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [SHIFT_ROOMS]: oneShiftRoom,
      [SHIFT_HISTORY]: { messages: [], complete: true },
    });

    await userEvent.click(
      await screen.findByRole("button", { name: /shift rooms at the anchor/i }),
    );

    const channel = await open(
      socket,
      /open kitchen/i,
      roomTopic({ kind: "shift", id: SHIFT_ROOM_ID }),
    );

    expect(channel.topic).toBe(`shift_room:${SHIFT_ROOM_ID}`);
  });
});

describe("a room's history", () => {
  it("shows what was said before the room was opened", async () => {
    // The third sub-item. Before it, the surface said "This room shows what has
    // been said since you opened it. There is no endpoint that serves the
    // history" — which was true and is not any more.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: {
        messages: [message("a", "said before"), message("b", "also before")],
        complete: true,
      },
    });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    await waitFor(() => {
      expect(messageBodies().join(" ")).toContain("said before");
    });

    expect(messageBodies().join(" ")).toContain("also before");
  });

  it("writes when each message was sent as a time, not as an instant", async () => {
    // The history is what made this matter. Until this unit a room showed only
    // what had arrived since it was opened, so every timestamp in the list was
    // minutes old; it now opens on a fetched page, which is where a raw
    // `2026-03-09T14:00:00Z` is least readable and most of them.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: { messages: [message("a", "said before")], complete: true },
    });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    await waitFor(() => {
      expect(messageBodies().join(" ")).toContain("said before");
    });

    expect(messageBodies().join(" ")).not.toContain("2026-03-09T14:00:00Z");
    expect(messageBodies().join(" ")).toContain(instantLabel("2026-03-09T14:00:00Z"));
  });

  it("shows a message once when the history and the stream overlap", async () => {
    // The fetch and the join are independent requests, so a message sent
    // between them is in both answers.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: { messages: [message("a", "in both")], complete: true },
    });

    const channel = await open(
      socket,
      /open the anchor/i,
      roomTopic({ kind: "venue", id: VENUE_ID }),
    );

    await waitFor(() => {
      expect(messageBodies()).toHaveLength(1);
    });

    act(() => {
      channel.push("message", message("a", "in both"));
    });

    expect(messageBodies()).toHaveLength(1);
  });

  it("offers the whole history only when the page is not the whole history", async () => {
    // The bound, from this side. `complete` is the server's answer and it is
    // not derivable here — a full page and a full history of the same length
    // are the same list — so a control offered unconditionally would lie.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: { messages: [message("a", "only one")], complete: true },
    });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    await waitFor(() => {
      expect(messageBodies().join(" ")).toContain("only one");
    });

    expect(screen.queryByRole("button", { name: /load the whole history/i })).toBeNull();
  });

  it("asks for extent=all when the control is used, and shows what comes back", async () => {
    // The control for the assertion above, and the only place the unbounded
    // read is reachable from a browser. The client sends a **word**: there is
    // no `limit` here and there must not be one, because the bound lives in
    // `HospitalityComs.Rooms` precisely so a caller cannot pass a number.
    const { socket, read } = renderRooms({
      [`${VENUE_HISTORY}?extent=recent`]: {
        messages: [message("b", "the recent one")],
        complete: false,
      },
      [`${VENUE_HISTORY}?extent=all`]: {
        messages: [message("a", "the older one"), message("b", "the recent one")],
        complete: true,
      },
      [VENUE_ROOMS]: twoVenueRooms,
    });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    const control = await screen.findByRole("button", {
      name: /load the whole history/i,
    });

    expect(messageBodies().join(" ")).not.toContain("the older one");

    await userEvent.click(control);

    await waitFor(() => {
      expect(messageBodies().join(" ")).toContain("the older one");
    });

    expect(read).toHaveBeenCalledWith(
      `${VENUE_HISTORY}?extent=all`,
      expect.any(String),
      expect.any(Function),
    );

    // Gone once it has been used: there is nothing more to load.
    expect(screen.queryByRole("button", { name: /load the whole history/i })).toBeNull();
  });

  it("says so when the history cannot be read, and opens the room anyway", async () => {
    // The history route re-derives the same authorisation the join does, so the
    // two usually agree — but a network failure is not a refusal, and a room
    // whose stream works must not be unusable because its past could not be
    // fetched.
    const { socket } = renderRooms({ [VENUE_ROOMS]: twoVenueRooms });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    expect(
      await screen.findAllByText(/that room is not one you can reach/i),
    ).not.toHaveLength(0);

    expect(screen.getByLabelText(/^message$/i)).not.toBeDisabled();
  });
});
