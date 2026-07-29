/**
 * Flow F3 — putting the new starter on tonight's shift — driven through the
 * real components against a fake `read` and a fake `write`.
 *
 * ## Two properties here are not "does it render"
 *
 * **A roster entry's role label comes off the server and a client-side join
 * could not produce it.** KTD-E10: `RosterEntry` carries no label, so U3
 * preloaded the engagement and `render_roster_entry/1` projects it. The row
 * that proves the preload is an entry whose engagement is **absent from the
 * venue's people list** — legal to roster, because `add_to_roster/3` accepts a
 * term that has not opened, and invisible to `list_engagements/1`, which is
 * active-at-instant. Without that row, "the label came off the server" and "the
 * label came off the people list" are the same green.
 *
 * **The removal is the bodiless `204`.** U4 gave `write` an optional decoder
 * for this call and nothing exercised it: omitting the decoder is what stops a
 * `204` being read as `malformed_response`, and a `read`-shaped `write` would
 * report a removal as failed *after it had succeeded*. `writesTo` answers
 * `ok(null)` whether or not a decoder was passed, so the only thing that can
 * tell the two apart is the call's own shape — hence the argument-count
 * assertion.
 *
 * **The picker forgets its choice on success and keeps it on a refusal.** There
 * *is* a server-side guard behind this one — `roster_entries_no_overlap`, with
 * `Rosters.unrostered/3` in front of it — so a repeated add stores nothing. What
 * it stores instead is R15's flat `404`, one sentence for four conditions, which
 * a manager cannot tell from the shift room having gone away. Both directions
 * are asserted and each reaches its positive state first: the choice is in the
 * picker, and the engagement is on the wire, before "the picker is empty" is
 * asked of it.
 */

import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../../api/client";
import type { RequestFailure } from "../../api/errors";
import { instantLabel } from "../../app/instant";
import { shiftRoomLabel } from "../../app/shift-room";
import { writesTo } from "../../test-support/fake-api";
import {
  HARBOUR,
  PEOPLE,
  SHIFT_ROOMS,
  SHIFT_TYPES,
  VENUES,
  chooseHarbour,
  engagementBody,
  removalPath,
  renderEmployer,
  rosterPath,
  twoVenues,
} from "../../test-support/employer-harness";

const TONIGHT = "66666666-6666-4666-8666-666666666661";
const TOMORROW = "66666666-6666-4666-8666-666666666662";

/** On the venue's people list: a term open at the scope's instant. */
const RUNNER = "33333333-3333-4333-8333-333333333331";
/** Rosterable and **not** on the people list: a term that has not opened. */
const PORTER = "33333333-3333-4333-8333-333333333332";

function shiftRoomBody(id: string, typeName: string, day: string) {
  return {
    shift_room_id: id,
    venue_id: HARBOUR,
    shift_type_name: typeName,
    starts_at: `2026-03-0${day}T21:00:00Z`,
    ends_at: `2026-03-0${String(Number(day) + 1)}T05:00:00Z`,
    closes_at: `2026-03-0${String(Number(day) + 1)}T05:30:00Z`,
  };
}

const TONIGHTS = shiftRoomBody(TONIGHT, "Close", "9");
const TOMORROWS = shiftRoomBody(TOMORROW, "Day", "1");

function labelOf(body: ReturnType<typeof shiftRoomBody>): string {
  return shiftRoomLabel({
    shiftRoomId: body.shift_room_id,
    venueId: body.venue_id,
    shiftTypeName: body.shift_type_name,
    startsAt: body.starts_at,
    endsAt: body.ends_at,
    closesAt: body.closes_at,
  });
}

function entry(engagementId: string, roleLabel: string) {
  return {
    engagement_id: engagementId,
    role_label: roleLabel,
    joined_at: "2026-03-09T18:00:00Z",
  };
}

function refusal(status: number, code: string, message: string): RequestFailure {
  return { kind: "api_error", status, code: "unrecognised", rawCode: code, message };
}

function bodies(overrides: Readonly<Record<string, unknown>> = {}) {
  return {
    [VENUES]: twoVenues,
    [PEOPLE]: { engagements: [engagementBody(RUNNER, "Runner")] },
    [SHIFT_TYPES]: { shift_types: [] },
    [SHIFT_ROOMS]: { shift_rooms: [TONIGHTS, TOMORROWS], complete: true },
    [rosterPath(TONIGHT)]: { roster: [] },
    [rosterPath(TOMORROW)]: { roster: [] },
    ...overrides,
  };
}

/** Opens tonight's shift and waits for its roster panel. */
async function openTonight() {
  await chooseHarbour();
  await userEvent.click(await screen.findByRole("button", { name: labelOf(TONIGHTS) }));

  return screen.findByRole("region", { name: /roster/i });
}

function rosterList() {
  return screen.findByRole("list", { name: /on this shift/i });
}

describe("a shift's roster", () => {
  it("reads the roster of the shift that was opened", async () => {
    const { paths } = renderEmployer(
      bodies({ [rosterPath(TONIGHT)]: { roster: [entry(RUNNER, "Runner")] } }),
    );

    await openTonight();

    expect(await rosterList()).toHaveTextContent(/runner/i);
    expect(paths).toContain(rosterPath(TONIGHT));
    expect(paths).not.toContain(rosterPath(TOMORROW));
  });

  it("names an entry whose engagement is not on the venue's people list", async () => {
    // **KTD-E10.** `add_to_roster/3` accepts an engagement whose term has not
    // opened; `list_engagements/1` answers only with engagements active at the
    // instant. So this entry is legitimately rostered and unlabellable from
    // anything this page holds — the label has to come off the server's
    // preload, and a client-side join renders a bare uuid here.
    renderEmployer(
      bodies({
        [rosterPath(TONIGHT)]: {
          roster: [entry(PORTER, "Kitchen Porter"), entry(RUNNER, "Runner")],
        },
      }),
    );

    await openTonight();

    const list = await rosterList();

    expect(list).toHaveTextContent(/kitchen porter/i);
    // The control: an entry that **is** on the people list, so the absent row is
    // not the only path exercised and a join is not accidentally sufficient.
    expect(list).toHaveTextContent(/runner/i);
    expect(list.textContent).toContain(instantLabel("2026-03-09T18:00:00Z"));
    expect(list.textContent).not.toContain("2026-03-09T18:00:00Z");
    // No `person_id` reaches this list either: the render is a field list off a
    // preloaded `Engagement`, which is one field access from the identity key.
    expect(list.textContent).not.toContain(PORTER);
  });

  it("says so when the shift has nobody on it, without reading as a failure", async () => {
    renderEmployer(bodies());

    await openTonight();

    expect(await screen.findByText(/nobody is on this shift yet/i)).toBeVisible();
  });

  it("shows the opened shift's roster and not the one before it", async () => {
    // **This is `useFetched`'s doing rather than the panel's `key`**, and that
    // is measured: removing the key kills nothing here, because the hook stamps
    // each answer with the request it answers and reports `loading` until the
    // new one arrives. The key earns its place one property over — see "forgets
    // who was chosen" below.
    renderEmployer(
      bodies({
        [rosterPath(TONIGHT)]: { roster: [entry(RUNNER, "Runner")] },
        [rosterPath(TOMORROW)]: { roster: [entry(PORTER, "Kitchen Porter")] },
      }),
    );

    await openTonight();

    expect(await rosterList()).toHaveTextContent(/runner/i);

    await userEvent.click(screen.getByRole("button", { name: labelOf(TOMORROWS) }));

    await waitFor(async () => {
      expect(await rosterList()).toHaveTextContent(/kitchen porter/i);
    });

    expect(await rosterList()).not.toHaveTextContent(/runner/i);
  });

  it("forgets who was chosen when another shift is opened", async () => {
    // **What the panel's `key` is actually for.** A selection made against one
    // shift and carried to another is one click from putting somebody on a
    // shift nobody meant — the mistake this demo can least afford, since the
    // remedy is the removal control two panels down.
    //
    // The positive state is reached first: the picker is asserted to hold the
    // choice before the switch, or "empty" and "never chosen" are the same DOM.
    renderEmployer(bodies());

    await openTonight();

    const picker = await screen.findByLabelText(/add somebody/i);
    await userEvent.selectOptions(
      picker,
      screen.getByRole("option", { name: /runner/i }),
    );

    expect(picker).toHaveValue(RUNNER);

    await userEvent.click(screen.getByRole("button", { name: labelOf(TOMORROWS) }));

    await waitFor(() => {
      expect(screen.getByLabelText(/add somebody/i)).toHaveValue("");
    });
  });
});

describe("adding somebody to a shift", () => {
  it("sends the engagement and nothing else, and re-reads the roster", async () => {
    const answers: Record<string, unknown> = bodies();
    const write = writesTo({
      [`POST ${rosterPath(TONIGHT)}`]: {
        body: { roster_entry: entry(RUNNER, "Runner") },
      },
    });
    renderEmployer(answers, write);

    await openTonight();
    await userEvent.selectOptions(
      await screen.findByLabelText(/add somebody/i),
      screen.getByRole("option", { name: /runner/i }),
    );

    answers[rosterPath(TONIGHT)] = { roster: [entry(RUNNER, "Runner")] };

    await userEvent.click(screen.getByRole("button", { name: /add to this shift/i }));

    await waitFor(async () => {
      expect(await rosterList()).toHaveTextContent(/runner/i);
    });

    expect(write).toHaveBeenCalledWith(
      {
        method: "POST",
        path: rosterPath(TONIGHT),
        body: { engagement_id: RUNNER },
        status: 201,
      },
      expect.any(String),
      expect.any(Function),
    );
  });

  it("empties the picker once somebody is added, so a second click repeats nothing", async () => {
    // **The positive state is reached first, twice over**: the picker is
    // asserted to hold the choice, and the choice is asserted to have reached
    // the wire, before "the picker is empty" is asked. A picker nobody ever
    // used satisfies that assertion on its own.
    //
    // `busy` does not cover this. It is `false` again the moment the answer
    // arrives, with the same person still named — and the second add meets
    // `roster_entries_no_overlap`, which R15 flattens into the same `404` as
    // "no such shift room". The manager reads that as the shift having gone.
    const answers: Record<string, unknown> = bodies();
    const write = writesTo({
      [`POST ${rosterPath(TONIGHT)}`]: {
        body: { roster_entry: entry(RUNNER, "Runner") },
      },
    });
    renderEmployer(answers, write);

    await openTonight();
    await userEvent.selectOptions(
      await screen.findByLabelText(/add somebody/i),
      screen.getByRole("option", { name: /runner/i }),
    );

    expect(screen.getByLabelText(/add somebody/i)).toHaveValue(RUNNER);

    answers[rosterPath(TONIGHT)] = { roster: [entry(RUNNER, "Runner")] };

    await userEvent.click(screen.getByRole("button", { name: /add to this shift/i }));

    await waitFor(() => {
      expect(write).toHaveBeenCalledWith(
        expect.objectContaining({ body: { engagement_id: RUNNER } }),
        expect.any(String),
        expect.any(Function),
      );
    });

    await waitFor(() => {
      expect(screen.getByLabelText(/add somebody/i)).toHaveValue("");
    });

    // The submit closes on the empty choice, so the repeat is unavailable
    // rather than merely refused.
    expect(screen.getByRole("button", { name: /add to this shift/i })).toBeDisabled();
  });

  it("keeps the choice when the add is refused", async () => {
    // **The control for the body above.** The remedy for a refusal is usually
    // to pick somebody else, and a picker that emptied itself on *submit* would
    // make the manager re-open the list to find out who they had just tried.
    const write = writesTo({
      [`POST ${rosterPath(TONIGHT)}`]: {
        failure: refusal(
          404,
          "not_found",
          "no such shift room or engagement here, or the roster already says otherwise",
        ),
      },
    });
    renderEmployer(bodies(), write);

    await openTonight();
    await userEvent.selectOptions(
      await screen.findByLabelText(/add somebody/i),
      screen.getByRole("option", { name: /runner/i }),
    );
    await userEvent.click(screen.getByRole("button", { name: /add to this shift/i }));

    await screen.findByRole("alert");

    expect(screen.getByLabelText(/add somebody/i)).toHaveValue(RUNNER);
    expect(screen.getByRole("button", { name: /add to this shift/i })).toBeEnabled();
  });

  it("does not add nobody", async () => {
    const write = writesTo({});
    renderEmployer(bodies(), write);

    await openTonight();
    await userEvent.click(
      await screen.findByRole("button", { name: /add to this shift/i }),
    );

    expect(write).not.toHaveBeenCalled();
  });

  it("renders the sentence the server sent when the add is refused", async () => {
    // R15's four conditions are one answer: another venue's shift room, another
    // venue's engagement, an id naming nothing, and an engagement already on
    // this roster. The sentence is the only thing that distinguishes this from
    // the two other `404`s `EmployerController` can answer.
    const write = writesTo({
      [`POST ${rosterPath(TONIGHT)}`]: {
        failure: refusal(
          404,
          "not_found",
          "no such shift room or engagement here, or the roster already says otherwise",
        ),
      },
    });
    renderEmployer(bodies(), write);

    await openTonight();
    await userEvent.selectOptions(
      await screen.findByLabelText(/add somebody/i),
      screen.getByRole("option", { name: /runner/i }),
    );
    await userEvent.click(screen.getByRole("button", { name: /add to this shift/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "no such shift room or engagement here, or the roster already says otherwise",
    );
  });

  // **The control.** Same code, a different sentence, and the first asserted
  // absent — the pair that catches a component hard-coding a string which
  // happened to match the first fixture.
  it("renders a different server sentence under the same code", async () => {
    const write = writesTo({
      [`POST ${rosterPath(TONIGHT)}`]: {
        failure: refusal(
          404,
          "not_found",
          "no such venue, or it is not one you can act for",
        ),
      },
    });
    renderEmployer(bodies(), write);

    await openTonight();
    await userEvent.selectOptions(
      await screen.findByLabelText(/add somebody/i),
      screen.getByRole("option", { name: /runner/i }),
    );
    await userEvent.click(screen.getByRole("button", { name: /add to this shift/i }));

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("no such venue, or it is not one you can act for");
    expect(alert).not.toHaveTextContent("the roster already says otherwise");
  });
});

describe("taking somebody off a shift", () => {
  it("removes them with a bodiless request, and the roster is empty afterwards", async () => {
    // **AE9, and the positive state is reached first**: the entry is asserted on
    // screen before the removal, or "the roster is empty" is satisfied by a
    // roster that never rendered one.
    //
    // The row itself survives with `left_at` set (KTD6b) and this client cannot
    // see that — `employer_controller_test.exs` asserts the surviving row, and
    // `employer_role` holds no `DELETE` on `roster_entries` underneath it.
    const answers: Record<string, unknown> = bodies({
      [rosterPath(TONIGHT)]: { roster: [entry(RUNNER, "Runner")] },
    });
    const write = writesTo({
      [`DELETE ${removalPath(TONIGHT, RUNNER)}`]: { body: null },
    });
    renderEmployer(answers, write);

    await openTonight();

    expect(await rosterList()).toHaveTextContent(/runner/i);

    answers[rosterPath(TONIGHT)] = { roster: [] };

    await userEvent.click(
      screen.getByRole("button", { name: /take runner off this shift/i }),
    );

    expect(await screen.findByText(/nobody is on this shift yet/i)).toBeVisible();

    expect(write).toHaveBeenCalledWith(
      { method: "DELETE", path: removalPath(TONIGHT, RUNNER), status: 204 },
      expect.any(String),
    );
  });

  it("passes no decoder, so a bodiless 204 is a success", async () => {
    // **Row 36's control, and the only assertion that can tell the two apart.**
    // `writesTo` answers `ok(null)` for a decoder-less call *and* for one whose
    // fixture happens to decode, so the shape of the call is the evidence. A
    // `read`-shaped `write` here reports a removal as failed after it succeeded,
    // and every retry then answers `:not_rostered`.
    const answers: Record<string, unknown> = bodies({
      [rosterPath(TONIGHT)]: { roster: [entry(RUNNER, "Runner")] },
    });
    const write = writesTo({
      [`DELETE ${removalPath(TONIGHT, RUNNER)}`]: { body: null },
    });
    renderEmployer(answers, write);

    await openTonight();
    await screen.findByRole("button", { name: /take runner off this shift/i });
    await userEvent.click(
      screen.getByRole("button", { name: /take runner off this shift/i }),
    );

    await waitFor(() => {
      expect(write).toHaveBeenCalled();
    });

    expect(vi.mocked(write).mock.calls[0]).toHaveLength(2);
  });

  it("removes once however fast the button is clicked", async () => {
    // A second `DELETE` after a successful one answers `404`, so the manager
    // would be told the removal failed for the removal that worked.
    const write = vi.fn(() => new Promise<never>(() => undefined)) as ApiClient["write"];
    renderEmployer(
      bodies({ [rosterPath(TONIGHT)]: { roster: [entry(RUNNER, "Runner")] } }),
      write,
    );

    await openTonight();

    const button = await screen.findByRole("button", {
      name: /take runner off this shift/i,
    });

    await userEvent.click(button);
    await userEvent.click(button);

    expect(write).toHaveBeenCalledOnce();
    expect(button).toBeDisabled();
  });

  it("words the session's own failure itself", async () => {
    const write = writesTo({
      [`DELETE ${removalPath(TONIGHT, RUNNER)}`]: {
        failure: {
          kind: "api_error",
          status: 401,
          code: "unauthorized",
          rawCode: "unauthorized",
          message: "the request carries no live session token",
        },
      },
    });
    renderEmployer(
      bodies({ [rosterPath(TONIGHT)]: { roster: [entry(RUNNER, "Runner")] } }),
      write,
    );

    await openTonight();
    await userEvent.click(
      await screen.findByRole("button", { name: /take runner off this shift/i }),
    );

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent(/your session has ended/i);
    expect(alert).not.toHaveTextContent("the request carries no live session token");
  });
});

describe("the add picker", () => {
  it("says so when the venue's people list is not available to choose from", async () => {
    // The people read failing while the roster read succeeds is a real state,
    // and an empty `<select>` in front of a manager is not a sentence.
    renderEmployer(bodies({ [PEOPLE]: { engagements: [] } }));

    await openTonight();

    expect(
      await screen.findByText(/nobody is engaged here to put on a shift/i),
    ).toBeVisible();
  });
});
