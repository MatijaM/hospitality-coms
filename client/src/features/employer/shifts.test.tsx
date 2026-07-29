/**
 * Flow F2 — tonight's shift — driven through the real components against a fake
 * `read` and a fake `write`.
 *
 * ## Three properties here are not "does it render"
 *
 * **The page is the venue's *latest* shift rooms, and that is asserted by name
 * rather than by count.** `Rooms.list_shift_rooms/2` scans descending with a
 * `limit + 1` probe and re-orders ascending in SQL around it, precisely so the
 * shift a manager created a minute ago is in the default read. A bound applied
 * to the rota's own order returns the venue's **oldest** rooms and satisfies
 * every count assertion while hiding it — `MessagePage`'s moduledoc calls that
 * "the one mistake this function can make silently".
 *
 * **`complete` is the server's and is asserted in both directions.** A flag
 * hard-coded either way passes one of them, and this client cannot derive it: a
 * full page and a full history of the same length are the same list.
 *
 * **Nothing is sorted here.** The server's order is the display order, and the
 * whole rendered sequence is compared against the fixture's. What that cannot
 * catch is a client-side *ascending* sort, because within one page the server's
 * order already is ascending — recorded in this unit's brief rather than
 * claimed away.
 *
 * **The form empties itself on success and keeps everything on a refusal**, and
 * that pair is the only thing standing between a manager and a duplicate shift
 * room. Two rooms of one type over one term are legitimately creatable, so the
 * second click gets a `201` and there is nothing downstream to catch it. Both
 * directions are asserted and each reaches its positive state first — the three
 * values are sent before "the fields are blank" is asked, because a field that
 * was never filled satisfies that on its own.
 */

import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../../api/client";
import type { RequestFailure } from "../../api/errors";
import { instantLabel } from "../../app/instant";
import { shiftRoomLabel } from "../../app/shift-room";
import { writesTo } from "../../test-support/fake-api";
import {
  CREATE_SHIFT,
  HARBOUR,
  PEOPLE,
  SHIFT_ROOMS,
  SHIFT_TYPES,
  VENUES,
  chooseHarbour,
  renderEmployer,
  twoVenues,
} from "../../test-support/employer-harness";

const CLOSE = "55555555-5555-4555-8555-555555555551";
const DAY = "55555555-5555-4555-8555-555555555552";

const shiftTypes = {
  shift_types: [
    { shift_type_id: CLOSE, name: "Close", grace_period_minutes: 30 },
    { shift_type_id: DAY, name: "Day", grace_period_minutes: 0 },
  ],
};

/**
 * One shift room as `RoomController.rendered_shift_room/1` writes it.
 *
 * The terms deliberately cross local midnight — eight hours from the evening —
 * because that is the ordinary shape of a hospitality shift and it is what
 * `termLabel`'s two-day form exists for. The seed's own live room is eight
 * hours anchored on `Clock.now()`, so it is overnight whenever the manifest is
 * seeded after about four in the afternoon.
 */
function room(suffix: string, typeName: string, day: string) {
  return {
    shift_room_id: `66666666-6666-4666-8666-66666666666${suffix}`,
    venue_id: HARBOUR,
    shift_type_name: typeName,
    starts_at: `2026-03-0${day}T21:00:00Z`,
    ends_at: `2026-03-0${String(Number(day) + 1)}T05:00:00Z`,
    closes_at: `2026-03-0${String(Number(day) + 1)}T05:30:00Z`,
  };
}

/** Ascending by `starts_at`, which is the order the server answers in. */
const OLDEST = room("1", "Day", "1");
const OLDER = room("2", "Day", "2");
const THIRD = room("3", "Close", "3");
const SECOND = room("4", "Close", "4");
const NEWEST = room("5", "Close", "5");

/** The bounded read: the venue's three most recent, oldest first within itself. */
const recentPage = { shift_rooms: [THIRD, SECOND, NEWEST], complete: false };

/** `?extent=all`: all five, in the same ascending order. */
const wholePage = {
  shift_rooms: [OLDEST, OLDER, THIRD, SECOND, NEWEST],
  complete: true,
};

function labelOf(body: ReturnType<typeof room>): string {
  return shiftRoomLabel({
    shiftRoomId: body.shift_room_id,
    venueId: body.venue_id,
    shiftTypeName: body.shift_type_name,
    startsAt: body.starts_at,
    endsAt: body.ends_at,
    closesAt: body.closes_at,
  });
}

function refusal(status: number, code: string, message: string): RequestFailure {
  return { kind: "api_error", status, code: "unrecognised", rawCode: code, message };
}

/** Everything the venue desk reads, so only the panel under test can fail. */
function bodies(overrides: Readonly<Record<string, unknown>> = {}) {
  return {
    [VENUES]: twoVenues,
    [PEOPLE]: { engagements: [] },
    [SHIFT_TYPES]: shiftTypes,
    [SHIFT_ROOMS]: recentPage,
    ...overrides,
  };
}

function shiftList() {
  return screen.findByRole("list", { name: /shifts at this venue/i });
}

async function fillShiftForm(typeName: string) {
  await userEvent.selectOptions(
    await screen.findByLabelText(/shift type/i),
    screen.getByRole("option", { name: new RegExp(typeName, "i") }),
  );
  await userEvent.type(screen.getByLabelText(/^starts$/i), "2026-03-09T21:00");
  await userEvent.type(screen.getByLabelText(/^ends$/i), "2026-03-10T05:00");
}

describe("the venue's shift types", () => {
  it("offers them by name, with the grace that tells two apart", async () => {
    renderEmployer(bodies());

    await chooseHarbour();

    const picker = await screen.findByLabelText(/shift type/i);

    expect(within(picker).getByRole("option", { name: /close/i })).toBeInTheDocument();
    expect(within(picker).getByRole("option", { name: /day/i })).toBeInTheDocument();
    expect(picker.textContent).toContain("30");
    // The id is what a picker without a name read as, and the whole reason
    // `GET shift-types` exists rather than a paste box.
    expect(picker.textContent).not.toContain(CLOSE);
  });

  it("says why a venue with no shift types cannot have a shift created", async () => {
    // Kolektiv is this venue in the seed: `Venues.create_shift_type/3` exists
    // and nothing on this surface calls it, so a venue with none is a real
    // state and an empty `<select>` is not a sentence.
    renderEmployer(bodies({ [SHIFT_TYPES]: { shift_types: [] } }));

    await chooseHarbour();

    expect(
      await screen.findByText(/no shift types are configured at this venue/i),
    ).toBeVisible();
  });
});

describe("creating a shift", () => {
  it("sends the type and the two instants, and nothing else", async () => {
    // `venue_id` and `grace_period_minutes` come off the resolved shift type
    // and are **not castable**: `EmployerController`'s `@term_fields` is
    // `~w(starts_at ends_at)` and `create_shift_room/3` puts the rest from the
    // type. A client sending either would be relying on that `Map.take/2` to
    // strip it.
    const write = writesTo({ [CREATE_SHIFT]: { body: { shift_room: NEWEST } } });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");
    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    await waitFor(() => {
      expect(write).toHaveBeenCalledOnce();
    });

    const [request] = vi.mocked(write).mock.calls[0] ?? [];

    expect(request?.method).toBe("POST");
    expect(request?.path).toBe(SHIFT_ROOMS);
    expect(request?.status).toBe(201);
    // The instants are the manager's own wall clock turned into instants, so
    // they resolve the runner's timezone — read back out of the same conversion
    // rather than spelled, for `room.test.ts`'s reason.
    expect(Object.keys(request?.body as object).sort()).toEqual([
      "ends_at",
      "shift_type_id",
      "starts_at",
    ]);
    expect((request?.body as { shift_type_id: string }).shift_type_id).toBe(CLOSE);
    expect((request?.body as { starts_at: string }).starts_at).toBe(
      new Date("2026-03-09T21:00").toISOString(),
    );
  });

  it("puts the new shift in the list, which did not hold it before", async () => {
    // **The "before" assertion is this test's own control.** A fixture whose
    // bounded read already contained the created room would pass the "after"
    // half with no re-read at all.
    // `readsFrom` reads its table at call time, so moving the answer between
    // the two reads is one assignment rather than a stateful fake.
    const created = room("9", "Close", "6");
    const answers: Record<string, unknown> = bodies();

    const write = writesTo({ [CREATE_SHIFT]: { body: { shift_room: created } } });
    renderEmployer(answers, write);

    await chooseHarbour();

    expect((await shiftList()).textContent).not.toContain(labelOf(created));

    answers[SHIFT_ROOMS] = {
      shift_rooms: [...recentPage.shift_rooms, created],
      complete: false,
    };

    await fillShiftForm("Close");
    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    await waitFor(async () => {
      expect((await shiftList()).textContent).toContain(labelOf(created));
    });
  });

  it("does not create a shift from an empty form", async () => {
    const write = writesTo({ [CREATE_SHIFT]: { body: { shift_room: NEWEST } } });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await userEvent.click(
      await screen.findByRole("button", { name: /create this shift/i }),
    );

    expect(write).not.toHaveBeenCalled();
  });

  it("stays closed until a type and both instants are named", async () => {
    // **This is the assertion that makes the `disabled` attribute observable**,
    // and it is here because the test above is not: the form's `onSubmit` guard
    // refuses an empty type as well, so removing the attribute alone kills
    // nothing. Measured — mutation 22a, zero kills, before this body existed.
    //
    // The pair is kept and neither half is the other's spare. The attribute is
    // what a manager sees; `onSubmit`'s guard is what the handler promises,
    // and it also covers a value the attribute cannot see — an input whose
    // contents will not parse, where `toISOString()` throws rather than
    // returning something wrong. That branch is **not reachable through this
    // DOM**: `datetime-local` sanitises a non-date value to the empty string in
    // jsdom exactly as a conforming browser does, so the field goes blank and
    // the attribute catches it first. `employer.test.ts` covers it directly,
    // which is where it can be reached at all.
    renderEmployer(bodies());

    await chooseHarbour();

    const submit = await screen.findByRole("button", { name: /create this shift/i });

    expect(submit).toBeDisabled();

    await userEvent.selectOptions(
      await screen.findByLabelText(/shift type/i),
      screen.getByRole("option", { name: /close/i }),
    );

    expect(submit).toBeDisabled();

    await userEvent.type(screen.getByLabelText(/^starts$/i), "2026-03-09T21:00");

    expect(submit).toBeDisabled();

    await userEvent.type(screen.getByLabelText(/^ends$/i), "2026-03-10T05:00");

    // The control: a form that closed the submit unconditionally would pass
    // every assertion above.
    expect(submit).toBeEnabled();
  });

  it("empties the form once the shift is created, so a second click repeats nothing", async () => {
    // **The positive state is reached first.** The three values are asserted
    // present *and* asserted sent before anything is asserted about the fields
    // being blank — otherwise a form that was never filled satisfies the whole
    // body, which is the shape this project has shipped once and caught twice.
    //
    // The in-flight guard does not cover this. `creating` is `false` again the
    // moment the answer arrives, and nothing downstream deduplicates: two shift
    // rooms of one type over one term are legitimately creatable, so a second
    // click answers `201` and the manager un-creates a room by hand.
    const write = writesTo({ [CREATE_SHIFT]: { body: { shift_room: NEWEST } } });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");

    expect(await screen.findByLabelText(/shift type/i)).toHaveValue(CLOSE);
    expect(screen.getByLabelText(/^starts$/i)).toHaveValue("2026-03-09T21:00");
    expect(screen.getByLabelText(/^ends$/i)).toHaveValue("2026-03-10T05:00");

    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    await waitFor(() => {
      expect(write).toHaveBeenCalledOnce();
    });

    const sent = vi.mocked(write).mock.calls[0]?.[0]?.body as {
      shift_type_id: string;
    };

    expect(sent.shift_type_id).toBe(CLOSE);

    await waitFor(() => {
      expect(screen.getByLabelText(/shift type/i)).toHaveValue("");
    });

    expect(screen.getByLabelText(/^starts$/i)).toHaveValue("");
    expect(screen.getByLabelText(/^ends$/i)).toHaveValue("");
    // `blank` is what closes the submit again, so the second click is not
    // merely useless — it is unavailable, which is the same affordance the
    // manager met before they typed anything.
    expect(screen.getByRole("button", { name: /create this shift/i })).toBeDisabled();
  });

  it("keeps what the manager typed when the create is refused", async () => {
    // **The control for the body above, and the direction that is worse to get
    // wrong.** A `422` names the field that was not accepted; a form that
    // emptied itself on *submit* rather than on success would hand the manager
    // that sentence with nothing left on screen to correct.
    const write = writesTo({
      [CREATE_SHIFT]: {
        failure: {
          kind: "api_field_error",
          status: 422,
          code: "unprocessable_entity",
          rawCode: "unprocessable_entity",
          message: "the shift was not accepted",
          fields: { ends_at: ["must be after the start"] },
        },
      },
    });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");
    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /must be after the start/i,
    );

    expect(screen.getByLabelText(/shift type/i)).toHaveValue(CLOSE);
    expect(screen.getByLabelText(/^starts$/i)).toHaveValue("2026-03-09T21:00");
    expect(screen.getByLabelText(/^ends$/i)).toHaveValue("2026-03-10T05:00");
    expect(screen.getByRole("button", { name: /create this shift/i })).toBeEnabled();
  });

  it("creates once however fast the button is clicked", async () => {
    const write = vi.fn(() => new Promise<never>(() => undefined)) as ApiClient["write"];
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");

    const submit = screen.getByRole("button", { name: /create this shift/i });
    await userEvent.click(submit);
    await userEvent.click(submit);

    expect(write).toHaveBeenCalledOnce();
    expect(submit).toBeDisabled();
  });
});

describe("the venue's shifts", () => {
  it("labels each room by its type and its term", async () => {
    renderEmployer(bodies());

    await chooseHarbour();

    const list = await shiftList();

    // `shift_type_name` comes off the server — `rendered_shift_room/1` preloads
    // the type — so there is no id to join against here and none on the wire.
    expect(within(list).getByRole("button", { name: labelOf(NEWEST) })).toBeVisible();
    expect(list.textContent).toContain(instantLabel(NEWEST.closes_at));
    expect(list.textContent).not.toContain(NEWEST.starts_at);
    expect(list.textContent).not.toContain(NEWEST.shift_room_id);
  });

  it("shows the page the server sent, newest included and older ones absent", async () => {
    // **R11, named rather than counted.** A limit applied to the rota's own
    // ascending order returns `OLDEST` and `OLDER` and satisfies "three rooms
    // came back" — while hiding the shift this manager just created.
    renderEmployer(bodies());

    await chooseHarbour();

    const list = await shiftList();
    const labels = within(list)
      .getAllByRole("button")
      .map((button) => button.textContent);

    expect(labels.at(0)).toBe(labelOf(THIRD));
    expect(labels.at(-1)).toBe(labelOf(NEWEST));
    expect(list.textContent).not.toContain(labelOf(OLDEST));
  });

  it("renders the rooms in the order they arrived, sorting nothing", async () => {
    renderEmployer(bodies());

    await chooseHarbour();

    const list = await shiftList();

    expect(
      within(list)
        .getAllByRole("button")
        .map((button) => button.textContent),
    ).toEqual([THIRD, SECOND, NEWEST].map(labelOf));
  });

  it("offers to load them all when the server says there are more", async () => {
    renderEmployer(bodies());

    await chooseHarbour();
    await shiftList();

    expect(screen.getByRole("button", { name: /load every shift/i })).toBeVisible();
  });

  // **The control, and it is the direction a hard-coded flag gets wrong.**
  // Offering the control unconditionally tells a manager with three shifts that
  // there are more, which is `room-view.tsx`'s stated reason for keying it on
  // `complete` rather than on a length.
  it("does not offer to load them all when the server says that is the lot", async () => {
    renderEmployer(bodies({ [SHIFT_ROOMS]: { ...recentPage, complete: true } }));

    await chooseHarbour();
    await shiftList();

    expect(
      screen.queryByRole("button", { name: /load every shift/i }),
    ).not.toBeInTheDocument();
  });

  it("asks for the unbounded extent and renders what the bound was hiding", async () => {
    // The bounded rows are asserted **first**. Without that, a fixture whose two
    // extents answer the same rows passes "load all renders more" by returning
    // one list twice — the hole #48 shipped and U3 found.
    const { paths } = renderEmployer(
      bodies({ [`${SHIFT_ROOMS}?extent=all`]: wholePage }),
    );

    await chooseHarbour();

    const bounded = within(await shiftList()).getAllByRole("button");

    expect(bounded).toHaveLength(3);
    expect(bounded.at(0)?.textContent).toBe(labelOf(THIRD));

    await userEvent.click(screen.getByRole("button", { name: /load every shift/i }));

    await waitFor(async () => {
      expect(within(await shiftList()).getAllByRole("button")).toHaveLength(5);
    });

    const whole = within(await shiftList())
      .getAllByRole("button")
      .map((button) => button.textContent);

    expect(whole.at(0)).toBe(labelOf(OLDEST));
    expect(whole.at(-1)).toBe(labelOf(NEWEST));
    // A word, never a number: the bound lives in `Rooms.recent_shift_room_limit/0`
    // and this client must not learn it.
    expect(paths).toContain(`${SHIFT_ROOMS}?extent=all`);
    expect(paths.join(" ")).not.toContain("limit");
  });

  it("says so when the shift list cannot be read", async () => {
    // A failure has to read as a failure rather than as a venue with no shifts.
    // The sentence is `readsFrom`'s own 404 fixture, verbatim — worded for a
    // room because the fake is shared, and reading it back here is the point:
    // what is on screen came off the envelope.
    renderEmployer(bodies({ [SHIFT_ROOMS]: undefined }));

    await chooseHarbour();

    expect(
      await screen.findByText("no such room, or it is not one you can reach"),
    ).toBeVisible();
    expect(
      screen.queryByText(/no shifts have been created here/i),
    ).not.toBeInTheDocument();
  });
});

describe("a refused shift", () => {
  it("renders the sentence the server sent, per-field messages included", async () => {
    const write = writesTo({
      [CREATE_SHIFT]: {
        failure: {
          kind: "api_field_error",
          status: 422,
          code: "unprocessable_entity",
          rawCode: "unprocessable_entity",
          message: "the shift was not accepted",
          fields: { ends_at: ["must be after the start"] },
        },
      },
    });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");
    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("the shift was not accepted");
    expect(alert).toHaveTextContent(/must be after the start/i);
  });

  // **The control.** Same code, different sentence, and the first asserted
  // absent. `EmployerController` answers `404` with three different sentences —
  // `@no_venue`, `@no_shift_type`, `@no_roster_target` — so a switch keyed on
  // the code can say one of them and must be wrong about the other two.
  it("renders a different server sentence under the same code", async () => {
    const write = writesTo({
      [CREATE_SHIFT]: {
        failure: refusal(404, "not_found", "no such shift type at this venue"),
      },
    });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");
    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("no such shift type at this venue");
    expect(alert).not.toHaveTextContent(
      "no such venue, or it is not one you can act for",
    );
  });

  it("words the session's own failure itself, because that one is not this route's", async () => {
    // The control for the two above: without it, "renders the envelope's
    // sentence" is satisfied by a surface printing every `message` it is ever
    // handed, `PersonAuth`'s log-facing one included.
    const write = writesTo({
      [CREATE_SHIFT]: {
        failure: {
          kind: "api_error",
          status: 401,
          code: "unauthorized",
          rawCode: "unauthorized",
          message: "the request carries no live session token",
        },
      },
    });
    renderEmployer(bodies(), write);

    await chooseHarbour();
    await fillShiftForm("Close");
    await userEvent.click(screen.getByRole("button", { name: /create this shift/i }));

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent(/your session has ended/i);
    expect(alert).not.toHaveTextContent("the request carries no live session token");
  });
});
