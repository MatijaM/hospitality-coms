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
import type { RoomEntry, RoomRef, ShiftRoomListing } from "./room";
import { instantLabel, roomTopic, shiftRoomLabel } from "./room";
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
    author_role_label: "Head Chef",
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

/**
 * The open room's own section, found by something that is not its name.
 *
 * The composer is the one control only the open room renders, so reaching the
 * panel through it keeps the query independent of the string under test. A
 * `getByRole("region", { name })` would have derived the lookup from the
 * assertion, which is the shape that agrees with itself for any value.
 */
function openRoomPanel(): HTMLElement {
  const panel = screen.getByLabelText(/^message$/i).closest("section");

  if (panel === null) throw new Error("no open room on screen");

  return panel;
}

/** What the open room calls itself, on screen and to a screen reader. */
function openRoomHeader(): { readonly heading: string; readonly region: string } {
  const panel = openRoomPanel();

  return {
    heading: within(panel).getByRole("heading", { level: 2 }).textContent,
    region: panel.getAttribute("aria-label") ?? "",
  };
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
    // A browsed room enters the local list, so that `barred` and the reload
    // survival apply to it too. It used to say "a browsed room and a pasted one
    // take the same path into a channel", which since #80 is a claim about one
    // path and one entry point.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: { messages: [], complete: true },
    });

    await open(socket, /open the anchor/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    const recent = await screen.findByRole("list", { name: /recently opened chats/i });

    // It used to be asserted by looking for the id, which is what the row was.
    // The row is the venue's name now, and the id is asserted absent — with the
    // name as the control, because an empty list contains no id either.
    expect(
      within(recent).getByRole("button", { name: /open the anchor/i }),
    ).toBeVisible();
    expect(recent.textContent).not.toContain(VENUE_ID);
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

/**
 * The recently-opened list's rows, which are the reported surface.
 *
 * Every assertion here is scoped to that list with `within`, because the browse
 * list above it offers the same rooms under the same names — two "Open The
 * Anchor" buttons on one screen is the design (two lists, two labelled
 * regions), and an unscoped query would find either.
 */
describe("what a recently-opened row is called", () => {
  const venueRef = { kind: "venue", id: VENUE_ID } as const;
  const shiftRef = { kind: "shift", id: SHIFT_ROOM_ID } as const;

  async function recentList(): Promise<HTMLElement> {
    return screen.findByRole("list", { name: /recently opened chats/i });
  }

  it("uses the live name over the one it stored, so a rename corrects itself", async () => {
    // The stored name is what this browser last saw; the live one is the
    // server's answer now. Preferring the stored one leaves a venue renamed
    // months ago reading under its old name for as long as the entry survives,
    // with nothing to invalidate it.
    renderRooms(
      { [VENUE_ROOMS]: twoVenueRooms },
      readsFrom({ [VENUE_ROOMS]: twoVenueRooms }),
      [{ ref: venueRef, barred: null, name: "The Old Anchor" }],
    );

    const recent = await recentList();

    await waitFor(() => {
      expect(
        within(recent).getByRole("button", { name: /open the anchor$/i }),
      ).toBeVisible();
    });
    expect(recent.textContent).not.toContain("The Old Anchor");
  });

  it("uses the stored name when no list on screen carries one", async () => {
    // A shift room, with its venue never expanded — so `useShiftRooms` was
    // never asked and there is no live name anywhere in this client. Without
    // the store this row is `shift room 22222222`, which is the case the field
    // exists for.
    renderRooms(
      { [VENUE_ROOMS]: twoVenueRooms },
      readsFrom({ [VENUE_ROOMS]: twoVenueRooms }),
      [{ ref: shiftRef, barred: null, name: "Kitchen · Monday" }],
    );

    const recent = await recentList();

    expect(
      within(recent).getByRole("button", { name: /open kitchen · monday/i }),
    ).toBeVisible();
    // The control on that: the fallback is a real string this row could have
    // shown, so "it used the stored name" is distinguishable from "it rendered
    // nothing at all".
    expect(recent.textContent).not.toContain("shift room 22222222");
    expect(recent.textContent).not.toContain(SHIFT_ROOM_ID);
  });

  it("stores a shift room's name as it is opened, which is the only chance", async () => {
    // The scenario the field was added for, driven rather than asserted about:
    // expand a venue, open one of its shifts, collapse the venue again. The
    // live name is gone at that point and the row still reads.
    const { socket } = renderRooms({
      [VENUE_ROOMS]: twoVenueRooms,
      [SHIFT_ROOMS]: oneShiftRoom,
      [SHIFT_HISTORY]: { messages: [], complete: true },
    });

    const expand = await screen.findByRole("button", {
      name: /shift rooms at the anchor/i,
    });

    await userEvent.click(expand);
    await open(socket, /open kitchen/i, roomTopic(shiftRef));
    await userEvent.click(expand);

    // The browse list's shift rooms are gone, so nothing live names this room.
    await waitFor(() => {
      expect(
        screen.queryByRole("list", { name: /shift rooms at the anchor/i }),
      ).toBeNull();
    });

    const recent = await recentList();

    expect(within(recent).getByRole("button", { name: /open kitchen/i })).toBeVisible();
    expect(recent.textContent).not.toContain(SHIFT_ROOM_ID);
  });
});

/**
 * #80, and it is the presence test for the paste box inverted rather than
 * deleted — #68's manoeuvre, for the reason #74 gives about the peer lookup: a
 * uuid box removed with nothing asserting it gone comes back on the next
 * careless paste with nothing to say so.
 *
 * **The roles and the element ids catch different mutants, and that was
 * measured rather than assumed.** The first draft of this comment claimed
 * `queryByRole("textbox")` was the assertion that fails against the wrong fix —
 * the form styled away rather than deleted. It is not: `hidden` takes an
 * element out of the accessibility tree, so Testing Library stops finding it by
 * role and every role assertion here passes. Measured with the form put back
 * and one `hidden` added — the surviving assertions are the two
 * `getElementById` calls, either of which catches it on its own. Reproduced
 * independently in review, which also named the mechanism: Testing Library's
 * `isSubtreeInaccessible` reads `element.hidden === true` directly, so this
 * holds regardless of whether jsdom applies any CSS.
 *
 * Both halves therefore stay, against two different wrong fixes. A form hidden
 * off-screen — `position: absolute; left: -9999px`, the shape that keeps it
 * reachable by a screen reader and invisible to everybody else, which is the
 * whole argument for deleting rather than hiding — is still in the tree and is
 * what the roles catch. A form hidden any other way, or rebuilt without labels
 * so it has no roles worth querying, keeps its ids.
 */
describe("what the rooms surface does not ask anybody to type", () => {
  it("has no way into a room that is not one of the two lists", async () => {
    // **The controls are mandatory and come first.** Both lists have to be on
    // screen with rows in them, because every absence below passes against a
    // surface that rendered nothing — which is what a failed `read` produces
    // on this very screen, and is the shape this project has shipped five
    // times.
    renderRooms(
      { [VENUE_ROOMS]: twoVenueRooms, [SHIFT_ROOMS]: oneShiftRoom },
      undefined,
      [{ ref: { kind: "venue", id: VENUE_ID }, barred: null, name: "The Anchor" }],
    );

    const browse = await screen.findByRole("list", { name: /venue rooms/i });
    const recent = await screen.findByRole("list", { name: /recently opened chats/i });

    expect(within(browse).getByText("The Anchor")).toBeVisible();
    expect(
      within(recent).getByRole("button", { name: /open the anchor/i }),
    ).toBeVisible();

    // The venue is expanded too, so the shift-room half of the browse list is
    // standing as well: it is the half a paste box would be defended as the way
    // past, and asserting the absence with it collapsed would leave "the box is
    // gone" and "the surface never opened" the same green.
    await userEvent.click(
      await screen.findByRole("button", { name: /shift rooms at the anchor/i }),
    );
    expect(
      within(
        await screen.findByRole("list", { name: /shift rooms at the anchor/i }),
      ).getByRole("button", { name: /open kitchen/i }),
    ).toBeVisible();

    // And now the form, by each route it had onto the page.
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /add this room/i }),
    ).not.toBeInTheDocument();
    expect(document.getElementById("room-id")).toBeNull();
    expect(document.getElementById("room-kind")).toBeNull();
  });

  /**
   * The empty-state sentence, which is a **second render** and was a bug the
   * first time it was written.
   *
   * It began as one more line at the end of the test above —
   * `expect(document.body.textContent).not.toContain("add one by its id")` —
   * under a comment citing #74's regex that never matched what the heading
   * rendered. Review measured it and it was the same class: that test seeds a
   * recent-list entry, because the entry is its control, and `RoomList` renders
   * the empty-state paragraph only when `entries.length === 0`. So the sentence
   * was absent whichever words it held. Restoring the old copy in
   * `rooms-route.tsx` left it green while turning **seven** tests red in
   * `app.test.tsx`.
   *
   * The fix is the empty list, which is the state the sentence exists for. That
   * also closes the gap the vacuous line was hiding: until now nothing inside
   * the rooms feature pinned this copy at all — only `app.test.tsx`'s
   * cross-feature sentinel, where a change to it reads as the tab strip
   * breaking.
   */
  it("points an empty list at the lists above, and nowhere else", async () => {
    renderRooms({ [VENUE_ROOMS]: twoVenueRooms });

    // The control: the panel is up and populated, so "no paste box offered" is
    // distinguishable from "nothing rendered".
    expect(
      within(await screen.findByRole("list", { name: /venue rooms/i })).getByText(
        "The Anchor",
      ),
    ).toBeVisible();

    expect(screen.getByText("No rooms yet. Open one from the list above.")).toBeVisible();
    expect(document.body.textContent).not.toContain("add one by its id");
  });
});

/**
 * The open room's header, which was the last uuid on this surface (#73).
 *
 * It rendered `<h2>Venue room</h2>` over `<code>{ref.id}</code>`. #72 named
 * every row of both lists and left this one, which is the largest of the three
 * — it sits over the conversation rather than in a list.
 *
 * **The order is what is under test here, not the strings.** `roomLabel` is
 * live → stored → fallback and `room.test.ts` pins what each one reads; what
 * this file has to show is that the header goes through all three of them, in
 * that order, on a real screen. Each assertion below is the one that fails when
 * one step of the order is dropped, and the panel is found through the composer
 * rather than by its name so that no query here is derived from the answer.
 */
describe("what the open room's header is called", () => {
  const shiftRef: RoomRef = { kind: "shift", id: SHIFT_ROOM_ID };

  /** `oneShiftRoom`'s single row, decoded — so the label has one spelling. */
  const kitchen: ShiftRoomListing = {
    shiftRoomId: SHIFT_ROOM_ID,
    venueId: VENUE_ID,
    shiftTypeName: "Kitchen",
    startsAt: "2026-03-09T13:00:00Z",
    endsAt: "2026-03-09T21:00:00Z",
    closesAt: "2026-03-09T21:30:00Z",
  };

  const STALE = "What this browser last saw";

  it("prefers the live name over the stored one, and stops at the stored one first", async () => {
    // Both halves in one flow, because the flow is what makes them
    // distinguishable. A room *opened* while a live name is on screen has that
    // name written into the store by `recordOpening`, so the two agree from
    // then on and neither preference is observable. This opens a bookmarked
    // shift room with its venue collapsed — no live name anywhere in this
    // client, which is the case `RoomEntry.name` exists for — and then expands
    // the venue, at which point the list arrives and the two disagree.
    const bodies = {
      [VENUE_ROOMS]: twoVenueRooms,
      [SHIFT_ROOMS]: oneShiftRoom,
      [SHIFT_HISTORY]: { messages: [], complete: true },
    };
    const { socket } = renderRooms(bodies, readsFrom(bodies), [
      { ref: shiftRef, barred: null, name: STALE },
    ]);

    await open(socket, new RegExp(`^open ${STALE}$`, "i"), roomTopic(shiftRef));

    // The stored name, which is all there is. A header that went straight to
    // the fallback would read `shift room 22222222` here.
    expect(openRoomHeader()).toEqual({ heading: STALE, region: STALE });

    await userEvent.click(
      await screen.findByRole("button", { name: /shift rooms at the anchor/i }),
    );

    // And now the server's answer, which wins outright — the same string the
    // browse list above puts on its own row, so one room does not read two
    // ways on one screen.
    await waitFor(() => {
      expect(openRoomHeader().heading).toBe(shiftRoomLabel(kitchen));
    });
    expect(openRoomHeader().region).toBe(shiftRoomLabel(kitchen));
    expect(openRoomPanel().textContent).not.toContain(STALE);
  });

  it("renders the venue's name where the uuid was, and the kind under it", async () => {
    // The reported symptom, from the other kind of room. The control is the
    // heading itself: an absence assertion about an id passes against a header
    // that rendered nothing at all, and "" contains no uuid either.
    const bodies = {
      [VENUE_ROOMS]: twoVenueRooms,
      [VENUE_HISTORY]: { messages: [], complete: true },
    };
    const { socket } = renderRooms(bodies);

    await open(socket, /^open the anchor$/i, roomTopic({ kind: "venue", id: VENUE_ID }));

    expect(openRoomHeader()).toEqual({ heading: "The Anchor", region: "The Anchor" });
    // The kind survives the swap: a venue room and a shift room refuse a send
    // for different reasons, and one of them closes.
    expect(within(openRoomPanel()).getByText("Venue room")).toBeVisible();
    expect(openRoomPanel().textContent).not.toContain(VENUE_ID);
    expect(openRoomPanel().outerHTML).not.toContain(VENUE_ID);
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
