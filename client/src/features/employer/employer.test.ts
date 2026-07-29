/**
 * The employer surface's three pure functions that are not decoders: two
 * labels, and the one place this client turns something a manager typed into an
 * instant.
 *
 * **No expected string here is spelled out.** Every label resolves the runner's
 * timezone through `src/app/instant.ts`, so a fixture asserting "9 Mar 18:00"
 * is green on one machine and red on another —
 * `features/rooms/room.test.ts` learned that first. What is asserted is the
 * *composition*: that the label contains the parts, in the renderer's own
 * spelling, and never the raw ISO string.
 */

import { describe, expect, it } from "vitest";

import { instantLabel, termLabel } from "../../app/instant";
import { instantFromLocal, rosterEntryLabel, shiftTypeLabel } from "./employer";

describe("naming a shift type", () => {
  it("names the type and the grace that tells it from a similar one", () => {
    // `render_shift_type/1` renders `grace_period_minutes` because "it is the
    // only thing that distinguishes two types with similar names, and because
    // it is what a manager is choosing between" — so the picker has to show it.
    const label = shiftTypeLabel({
      shiftTypeId: "55555555-5555-4555-8555-555555555551",
      name: "Close",
      gracePeriodMinutes: 30,
    });

    expect(label).toContain("Close");
    expect(label).toContain("30");
  });

  it("says nothing different for a type with no grace at all", () => {
    // A zero grace is a real configuration and reads as one, rather than as an
    // absence. It is also the value a falsiness check quietly loses.
    const label = shiftTypeLabel({
      shiftTypeId: "55555555-5555-4555-8555-555555555552",
      name: "Day",
      gracePeriodMinutes: 0,
    });

    expect(label).toContain("Day");
    expect(label).toContain("0");
  });
});

describe("naming a roster entry", () => {
  it("names the role and when the entry opened, formatted", () => {
    const label = rosterEntryLabel({
      engagementId: "33333333-3333-4333-8333-333333333333",
      roleLabel: "Runner",
      joinedAt: "2026-03-09T18:00:00Z",
    });

    expect(label).toContain("Runner");
    expect(label).toContain(instantLabel("2026-03-09T18:00:00Z"));
    expect(label).not.toContain("2026-03-09T18:00:00Z");
  });
});

describe("the instant a manager typed", () => {
  /** The local wall clock a `datetime-local` input produces. */
  const TYPED = "2026-03-09T18:00";

  it("turns a local wall clock into the instant it names", () => {
    // **This is not a second clock.** `HospitalityComs.Clock` is offsettable and
    // the demo moves what the *server* thinks now is; it does not move the
    // mapping from "18:00 on 9 March" to the instant that names. Nothing here
    // reads `Date.now()` and nothing compares.
    //
    // The assertion is a round trip rather than a spelled ISO string, because
    // `new Date("2026-03-09T18:00").toISOString()` differs under `TZ=UTC` and
    // under `TZ=Pacific/Kiritimati` — the two zones this suite is run in.
    const instant = instantFromLocal(TYPED);

    expect(instant).not.toBeNull();

    const back = new Date(instant as string);

    expect(back.getFullYear()).toBe(2026);
    expect(back.getMonth()).toBe(2);
    expect(back.getDate()).toBe(9);
    expect(back.getHours()).toBe(18);
    expect(back.getMinutes()).toBe(0);
  });

  it("answers an instant rather than handing the local string back", () => {
    // The control for the test above: a function that returned its argument
    // unchanged round-trips to exactly the same wall clock and passes it. What
    // it does not do is answer something the server can cast — Ecto's
    // `:utc_datetime` refuses a value carrying no offset.
    const instant = instantFromLocal(TYPED);

    expect(instant).not.toBe(TYPED);
    expect(instant).toMatch(/Z$/);
    // And it is the spelling this client already renders instants from, so the
    // form's own value and the list's labels cannot disagree about the term.
    expect(termLabel(instant as string, instant as string)).not.toContain("Invalid");
  });

  it("answers null for a value that is not a date-time, rather than throwing", () => {
    // `new Date("tonight").toISOString()` throws `RangeError`. The guard is
    // what turns a non-conforming input into a form that will not submit
    // instead of an exception inside a submit handler.
    expect(instantFromLocal("tonight")).toBeNull();
    expect(instantFromLocal("")).toBeNull();
  });
});
