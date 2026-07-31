/**
 * The two functions in this client that *produce* an instant, and the one that
 * reads a calendar day back out of one.
 *
 * Everything else in `instant.ts` renders and never computes, so this file is
 * small and the whole of it is about one question: **which timezone is the
 * question asked in?**
 *
 * ## Every assertion here names its zone, and one zone is never enough
 *
 * A conversion that ignores timezones entirely — `value + "T00:00:00.000Z"` —
 * round-trips perfectly and answers correctly for every reader on UTC. So a
 * test run in one zone cannot tell it from a correct one, and a test run in
 * *whatever zone the machine happens to be in* is a fixture chosen by accident.
 * `room.test.ts` says the same thing about rendering and this is the computing
 * half of it.
 *
 * So the pairs below assert the same input in two zones against two **different**
 * literals. `Pacific/Kiritimati` is the far one — UTC+14, so its local midnight
 * on 1 March is the previous day in UTC — and it is the zone this suite already
 * uses elsewhere.
 *
 * ## Why `process.env.TZ` is enough here, where `room.test.ts` re-imports
 *
 * That file has to re-import because `room.ts` builds its `Intl.DateTimeFormat`s
 * once at module load and each holds the zone in force at that moment. Nothing
 * here builds a formatter: `new Date` and `getFullYear` read the zone per call,
 * and Node applies a change to `process.env.TZ` immediately — measured, not
 * assumed, since it has not always been true of every runtime.
 */

import { afterEach, describe, expect, it } from "vitest";

import {
  endOfLocalDate,
  instantFromLocal,
  localDateFromInstant,
  startOfLocalDate,
} from "./instant";

const ORIGINAL_TZ = process.env.TZ;

afterEach(() => {
  if (ORIGINAL_TZ === undefined) {
    delete process.env.TZ;
  } else {
    process.env.TZ = ORIGINAL_TZ;
  }
});

function inTimeZone<T>(timeZone: string, ask: () => T): T {
  process.env.TZ = timeZone;

  return ask();
}

describe("the instant a chosen day names", () => {
  it("is that day's midnight where the reader is, not where the server is", () => {
    // **The pair is the test and neither half is the whole of it.** The same
    // day converted in two zones has to answer two different instants; a
    // function that ignored the zone would satisfy either line alone.
    //
    // Kiritimati is UTC+14, so its midnight on 1 March is 29 February in UTC —
    // a different *calendar day*, which is what makes this the strong case
    // rather than an offset that only moves the hour.
    expect(inTimeZone("Pacific/Kiritimati", () => startOfLocalDate("2024-03-01"))).toBe(
      "2024-02-29T10:00:00.000Z",
    );
    expect(inTimeZone("Etc/UTC", () => startOfLocalDate("2024-03-01"))).toBe(
      "2024-03-01T00:00:00.000Z",
    );
  });

  it("appends the time, because a bare date is parsed as UTC and a date-time is not", () => {
    // The mechanism the test above rests on, asserted directly so that its
    // failure names the cause rather than an offset. This is the whole reason
    // `instantFromLocalDate` is not `new Date(value).toISOString()`:
    //
    //     new Date("2024-03-01")       -> UTC midnight, per the grammar
    //     new Date("2024-03-01T00:00") -> local midnight
    //
    // Dropping `T00:00` from the implementation makes the two expressions below
    // equal, and it is the mutation that leaves every round trip in this file
    // still passing.
    inTimeZone("Pacific/Kiritimati", () => {
      expect(new Date("2024-03-01").toISOString()).toBe("2024-03-01T00:00:00.000Z");
      expect(startOfLocalDate("2024-03-01")).not.toBe(
        new Date("2024-03-01").toISOString(),
      );
    });
  });

  it("answers null for anything that is not a calendar day", () => {
    // `type="date"` yields `""` or `YYYY-MM-DD` and nothing else, so none of
    // these is reachable through the DOM. This is the exported function's
    // contract for whoever calls it next.
    //
    // **An explicit `^\d{4}-\d{2}-\d{2}$` guard stood in front of this and
    // review measured it at zero kills** — every value here is refused without
    // it, because a `datetime-local` value becomes `"…T09:00T00:00"`, which
    // really is `Invalid Date`, and `2024-3-1` reads back as `2024-03-01` and
    // fails the round trip. The guard is gone and these assertions are what
    // hold the contract it claimed to.
    inTimeZone("Etc/UTC", () => {
      expect(startOfLocalDate("")).toBeNull();
      expect(startOfLocalDate("March 2024")).toBeNull();
      expect(startOfLocalDate("01/03/2024")).toBeNull();
      expect(startOfLocalDate("2024-03-01T09:00")).toBeNull();
    });
  });

  it("refuses a day that is shaped like one and is not", () => {
    // **This was written as a `NaN` assertion and measurement said no.**
    // `new Date("2024-02-31T00:00")` is not `Invalid Date`: V8's lenient parser
    // rolls it forward, so the function answered `2024-03-02T00:00:00.000Z` —
    // an instant two days from the one asked for, silently.
    //
    // What refuses it now is the round trip against `localDateFromInstant`, so
    // this is also the pair's invariant asserted from the outside.
    inTimeZone("Etc/UTC", () => {
      expect(new Date("2024-02-31T00:00").getTime()).not.toBeNaN();
      expect(startOfLocalDate("2024-02-31")).toBeNull();
      expect(startOfLocalDate("2024-13-01")).toBeNull();

      // The control: a real end-of-month day, which the same round trip must
      // let through. A guard that refused everything would pass the two lines
      // above.
      expect(startOfLocalDate("2024-02-29")).toBe("2024-02-29T00:00:00.000Z");
    });
  });
});

describe("the calendar day an instant falls on", () => {
  it("is read where the reader is, so the pair round-trips", () => {
    // A round trip alone is satisfied by two functions wrong in compensating
    // directions — both treating the value as UTC — which is why the absolute
    // assertions above come first. This adds the property those cannot: that
    // the two halves resolve the *same* zone as each other.
    //
    // The days include a DST transition at midnight (`America/Santiago` springs
    // forward at 00:00, so local midnight does not exist that day and JS
    // resolves it to 01:00) and both sides of a year boundary.
    for (const zone of ["Pacific/Kiritimati", "America/Santiago", "Etc/UTC"]) {
      for (const day of ["2024-03-01", "2024-09-08", "2025-12-31", "2026-01-01"]) {
        const instant = inTimeZone(zone, () => startOfLocalDate(day));

        if (instant === null) throw new Error(`${zone} refused ${day}`);

        expect(inTimeZone(zone, () => localDateFromInstant(instant))).toBe(day);
      }
    }
  });

  it("reads a stored instant as the day it falls on locally, not in UTC", () => {
    // The control on the round trip: it is symmetric, so it survives both
    // halves reading UTC. This is asymmetric — an instant that is one day in
    // UTC and another where the reader is standing.
    //
    // 21:00 UTC on 8 September is already the 9th in Kiritimati.
    expect(
      inTimeZone("Pacific/Kiritimati", () =>
        localDateFromInstant("2024-09-08T21:00:00.000Z"),
      ),
    ).toBe("2024-09-09");
    expect(
      inTimeZone("Etc/UTC", () => localDateFromInstant("2024-09-08T21:00:00.000Z")),
    ).toBe("2024-09-08");
  });

  it("pads, so the value is one a date input accepts", () => {
    // `2024-3-1` is not a value `type="date"` will display — it renders blank,
    // silently, which is the failure this function exists to prevent. A missing
    // `padStart` is invisible for three quarters of the year.
    expect(
      inTimeZone("Etc/UTC", () => localDateFromInstant("2024-03-01T00:00:00.000Z")),
    ).toBe("2024-03-01");
  });

  it("answers the empty string for an instant it cannot read", () => {
    // `""` and not `null`: the one consumer is a controlled input's `value`,
    // where React warns on `null`, and `""` is what an untouched control holds.
    expect(localDateFromInstant("not an instant")).toBe("");
    expect(localDateFromInstant("")).toBe("");
  });
});

describe("the instant a wall clock names", () => {
  it("still resolves the reader's zone after moving out of the employer surface", () => {
    // `instantFromLocal` moved here from `features/employer/employer.ts` in #82
    // and `employer.test.ts` still covers its behaviour through the re-export.
    // What that file cannot show is that the move did not change the zone the
    // question is asked in, because it runs in one zone at a time.
    expect(
      inTimeZone("Pacific/Kiritimati", () => instantFromLocal("2026-03-09T18:00")),
    ).toBe("2026-03-09T04:00:00.000Z");
    expect(inTimeZone("Etc/UTC", () => instantFromLocal("2026-03-09T18:00"))).toBe(
      "2026-03-09T18:00:00.000Z",
    );
  });

  it("answers null rather than throwing on a value that is not a date-time", () => {
    expect(instantFromLocal("tonight")).toBeNull();
    expect(instantFromLocal("")).toBeNull();
  });
});

describe("the instant that ends a chosen day", () => {
  it("is late on that day, so one day is a term rather than an empty one", () => {
    // **F3, from #82's review.** Both bounds converted to the start of their
    // day, so a worker who worked one day chose the same date twice and got two
    // identical instants — refused by `declared_entries_term_ordered` with
    // "must be after the start" against two dates they picked on purpose.
    const from = inTimeZone("Etc/UTC", () => startOfLocalDate("2024-03-01"));
    const to = inTimeZone("Etc/UTC", () => endOfLocalDate("2024-03-01"));

    if (from === null || to === null) throw new Error("a real day answered nothing");

    expect(from).toBe("2024-03-01T00:00:00.000Z");
    expect(to).toBe("2024-03-01T23:59:59.000Z");
    // The property the server actually checks, asserted as the server checks it.
    expect(new Date(to).getTime()).toBeGreaterThan(new Date(from).getTime());
  });

  it("carries no milliseconds, because the column is second-precision", () => {
    // `:utc_datetime` truncates, so a `.999` would come back differing from
    // what was sent and the amend form would re-send a third value.
    const to = inTimeZone("Etc/UTC", () => endOfLocalDate("2024-03-01"));

    expect(to).toMatch(/T23:59:59\.000Z$/);
  });

  it("reads back as the day that went in, in the reader's zone", () => {
    // The inverse has to hold for *both* bounds or the amend form shows a day
    // the worker never picked — which is the argument against using the next
    // day's midnight for the end.
    for (const zone of ["Pacific/Kiritimati", "America/Santiago", "Etc/UTC"]) {
      for (const day of ["2024-03-01", "2024-09-08", "2025-12-31"]) {
        const to = inTimeZone(zone, () => endOfLocalDate(day));

        if (to === null) throw new Error(`${zone} refused ${day}`);

        expect(inTimeZone(zone, () => localDateFromInstant(to))).toBe(day);
      }
    }
  });

  it("refuses what the other half refuses", () => {
    inTimeZone("Etc/UTC", () => {
      expect(endOfLocalDate("2024-02-31")).toBeNull();
      expect(endOfLocalDate("March 2024")).toBeNull();
      expect(endOfLocalDate("")).toBeNull();
      // The control, as above: a real day must still pass.
      expect(endOfLocalDate("2024-02-29")).toBe("2024-02-29T23:59:59.000Z");
    });
  });
});
