/**
 * How this client writes an instant on screen, and the one place it decides
 * what "another day" means.
 *
 * ## Why it lives here now
 *
 * `features/rooms/room.ts` wrote both of these for the shift room label, and
 * U4's employer and claim surfaces reached across for them rather than
 * spelling a second term format — a term written two ways on two screens of
 * one product is the defect this tree has fixed three times under other names.
 * That made it a cross-feature import into a feature directory, which nothing
 * else in `src/features/` production code does, and `room.ts` said where the
 * line was: *"`instantLabel` and this belong in a shared module the way
 * `src/socket/topic-id.ts` does, and the move belongs to whichever unit adds
 * the caller after U4's two."*
 *
 * U4 **is** that unit — it added both callers — so this is that hoist. It is
 * one commit behind the code that owed it rather than in front of it, and
 * `docs/test-designs/2026-07-29-employer-u4-write-verb-and-handshake.md`
 * records why.
 *
 * It sits in `src/app/` beside `failure-message.ts` and `use-fetched.ts` — the
 * two other things every surface shares and no surface owns — rather than in a
 * `shared/` bucket or a directory of its own. It could not go in `src/api/`:
 * nothing there may know how anything is *displayed*, and the whole argument
 * below is that display is where the timezone question gets its only honest
 * answer.
 *
 * **`room.ts` re-exports both under these names**, so no rooms file changed and
 * `shiftRoomLabel` still reads as one sentence. New callers import from here;
 * the re-export is a compatibility shim for the surface that wrote them, not a
 * second home.
 *
 * ## The formatting is client-side, and that is not a convenience
 *
 * Rendering an instant means choosing a timezone. `venues` carries one and this
 * device carries another, and the person reading the label is the one holding
 * the device — so the choice is made where the answer is known.
 *
 * ## Nothing here compares an instant against a clock, and nothing may
 *
 * `HospitalityComs.Clock` is offsettable and U11's demo controls move it while
 * this browser's clock stays real, so anything derived from a comparison
 * against `Date.now()` would be wrong during exactly the demo the offset exists
 * for. Whether a room still accepts a message, whether a code still works,
 * whether a term is open — all of those are the server's answers. These
 * functions render, and that is all they do.
 */

// Built once: `Intl.DateTimeFormat` is expensive to construct and these run per
// row per render.
const DAY_AND_TIME = new Intl.DateTimeFormat(undefined, {
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
});

const TIME_ONLY = new Intl.DateTimeFormat(undefined, {
  hour: "2-digit",
  minute: "2-digit",
});

/**
 * The calendar day an instant falls on, as a string that is only ever compared
 * with another one from this same formatter.
 *
 * **It is built exactly like the two above and that is the whole point.** All
 * three pass `undefined` for the locale and name no `timeZone`, so all three
 * resolve the same one — this device's. "Does this shift end on another day"
 * is a question with a different answer in every timezone, and the only answer
 * that is not a lie is the one taken in the timezone the label is *rendered*
 * in. `getUTCDate` would ask it in UTC and `venues` carries a timezone that
 * would ask it where the shift happens; a worker in Auckland reading a term
 * that is one evening to them would be told it spans two days, or the reverse.
 *
 * The year is in there because two instants a year apart share a day and a
 * month. Nothing in a shift term goes near that, and a comparison that is
 * right by luck is one somebody has to re-derive later.
 *
 * **All three are built at module load, and no test would notice if they were
 * not.** A formatter holds whatever timezone was in force when it was
 * constructed, which is why `features/rooms/room.test.ts` sets
 * `process.env.TZ`, calls `vi.resetModules()` and re-imports to reach them. But
 * that helper leaves `TZ` set for the duration of its callback, so formatters
 * built lazily *inside* these functions would resolve the same zone and the
 * matrix would stay green — measured, zero kills. Building once is a
 * performance property (`Intl.DateTimeFormat` is expensive and these run per
 * row per render) held here by nothing but this paragraph. The day comparison
 * below is the part the matrix does hold, in both directions.
 */
const CALENDAR_DAY = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "numeric",
  day: "numeric",
});

/**
 * One instant, with its day: `9 Mar 21:30`, or the raw string if it will not
 * parse.
 *
 * Used on its own wherever a single instant is shown beside a term that
 * `termLabel` composed — a shift room's `closesAt`, a claim code's expiry, the
 * moment an engagement was accepted — and it is what `termLabel` writes an
 * endpoint with whenever that endpoint's day has to be said out loud. One
 * instant has one rendering on this client.
 *
 * The fallback is deliberate: an instant this client cannot read is still
 * something the reader can compare against another one, and a label reading
 * "Invalid Date" would be worse than the ISO string it replaced.
 */
export function instantLabel(value: string): string {
  const instant = new Date(value);

  return Number.isNaN(instant.getTime()) ? value : DAY_AND_TIME.format(instant);
}

/**
 * `9 Mar 13:00–21:00`, or `9 Mar 23:00–10 Mar 07:00` when the term ends on
 * another day, or the raw instants if either will not parse.
 *
 * **The second form is the common case, not the edge case.** This is a
 * hospitality product and a late shift crossing midnight is the ordinary shape
 * of the working day — the demo manifest's own live shift room is eight hours
 * from an hour ago, so it is overnight whenever the manifest is seeded after
 * about four in the afternoon. Writing the end as a time alone made that read
 * `Kitchen · 9 Mar 23:00–07:00`, which says the room closes sixteen hours
 * before it opens.
 *
 * Which day the *reader* is on is the question `CALENDAR_DAY` answers; see
 * there for why it cannot be asked in UTC.
 *
 * It renders three different things across this client — a shift room's window,
 * an engagement's term, an offer's term — and that is the reason it is here
 * rather than in any of them.
 */
export function termLabel(startsAt: string, endsAt: string): string {
  const start = new Date(startsAt);
  const end = new Date(endsAt);

  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
    return `${startsAt}–${endsAt}`;
  }

  const sameDay = CALENDAR_DAY.format(start) === CALENDAR_DAY.format(end);

  return `${DAY_AND_TIME.format(start)}–${sameDay ? TIME_ONLY.format(end) : DAY_AND_TIME.format(end)}`;
}

/**
 * The instant a `datetime-local` value names, or `null` if it names none.
 *
 * ## Hoisted from `features/employer/employer.ts`, under this file's own rule
 *
 * U4 wrote it there because U4 was its only caller. #82 gave it a second one on
 * the profile surface, which is the situation this module's header describes
 * for `instantLabel` and `termLabel` — *"new callers import from here"* — so it
 * moved rather than being copied. `employer.ts` re-exports it, exactly as
 * `room.ts` re-exports the two labels, and the employer surface is unchanged.
 *
 * ## This and `instantFromLocalDate` are the only places this client produces an instant
 *
 * Everything else here *renders* one and never computes with one, which is this
 * file's rule and KTD5's. Both exceptions are narrow: a shift and a declared
 * entry are terms somebody chose, and `POST …/shift-rooms` has no server-side
 * defaults — `@term_fields` is `~w(starts_at ends_at)` with no `Map.put_new`,
 * unlike the invitation's three.
 *
 * `HospitalityComs.Clock.Offset` moves what the server thinks *now* is. It does
 * not move the mapping from "18:00 on 9 March" to the instant that names, which
 * is all this does. Nothing here reads `Date.now()` and nothing compares.
 *
 * **The reader's zone is the right one and the only available one.** A
 * `datetime-local` value carries no offset, and `new Date` reads a date-*time*
 * form without one as local — which is what the manager meant, since they are
 * standing in the venue. `venues` carries a timezone the client never sees.
 *
 * **The `null` prevents a throw, not a bad request.**
 * `new Date("tonight").toISOString()` raises `RangeError`, so without this a
 * non-conforming input would take an exception out of a submit handler rather
 * than leaving a form that will not submit.
 *
 * **Residue, on the record:** a manager creating "tonight's shift" while the
 * demo holds the server's clock a month ahead creates a shift in the server's
 * past. That is inherent to a form taking explicit instants; the alternative is
 * this client computing a term from its own clock, which is the thing KTD-E5
 * exists to forbid.
 */
export function instantFromLocal(value: string): string | null {
  const instant = new Date(value);

  return Number.isNaN(instant.getTime()) ? null : instant.toISOString();
}

/**
 * The instant that starts a chosen day, in the reader's zone — or `null` if the
 * value does not name a real day.
 *
 * ## `T00:00` is load-bearing, and leaving it off is silent
 *
 * A date-*only* string is parsed as **UTC** by the ECMAScript grammar, while a
 * date-*time* string carrying no offset is parsed as **local**:
 *
 *     new Date("2024-03-01")        // 2024-03-01T00:00:00.000Z, everywhere
 *     new Date("2024-03-01T00:00")  // 2024-03-01T05:00:00.000Z in New York
 *
 * So the obvious `new Date(value).toISOString()` answers the same instant for
 * every reader on earth, which is wrong for all but one of them — and wrong in
 * the direction that files a declared job under the *previous* day for anybody
 * east of UTC. Appending the time is what asks the question in the zone the
 * person choosing the day is standing in.
 *
 * ## The round trip is the whole of the validation, and a regex was not
 *
 * `new Date("2024-02-31T00:00")` is **not** `Invalid Date` — V8's lenient
 * parser rolls it forward to 2 March, so a `NaN` check alone answers an instant
 * two days from the one asked for. And an explicit `^\d{4}-\d{2}-\d{2}$`
 * guard stood here until review measured it: **it killed nothing**, because
 * every value it was written to refuse is refused anyway — a `datetime-local`
 * value becomes `"…T09:00T00:00"`, which really is `Invalid Date`, and
 * `2024-3-1` reads back as `2024-03-01` and fails the comparison.
 *
 * So the check is: build the instant, read the day back out of it, and refuse
 * unless it is the day that went in. One rule, stated where it can be enforced.
 *
 * Safe on the day it looks unsafe — a DST spring-forward *at* midnight, where
 * local midnight does not exist, JS resolves it to 01:00 and the calendar day
 * is preserved. **Not** safe on the 23 (zone, day) pairs in the whole tz
 * database where the *entire* midnight hour is skipped across a date line
 * change: there this answers `null` and the form treats the day as unfilled.
 * Recorded rather than handled; nothing in this product reaches 1994 Kiritimati.
 */
export function startOfLocalDate(value: string): string | null {
  return localDateAt(value, "00:00:00");
}

/**
 * The instant that **ends** a chosen day, in the reader's zone.
 *
 * ## Without this a one-day job could not be written at all
 *
 * `declared_entries_term_ordered` and `DeclaredEntry.validate_term/1` both
 * require `ends_at` strictly after `starts_at`. With both bounds converting to
 * the *start* of their day — which is what this unit shipped first, and what
 * its brief reasoned to without considering equality — a worker choosing the
 * same day twice produced two identical instants and the write was refused
 * with "must be after the start". A one-day gig is an ordinary thing in
 * hospitality, so that is a real hole rather than an edge.
 *
 * 23:59:59 rather than the next day's midnight, which is the other way to close
 * it: this column is compared against nothing — no exclusion constraint, no
 * overlap rule — so there is no half-open interval to honour, and end-of-day
 * keeps `localDateFromInstant` an exact inverse of *both* directions. Next
 * midnight would read back as the following day and the amend form would show a
 * date the worker never picked.
 *
 * Seconds rather than milliseconds because the column is `:utc_datetime`, which
 * is second-precision; a `.999` would be truncated on the way in and the row
 * would come back differing from what was sent.
 */
export function endOfLocalDate(value: string): string | null {
  return localDateAt(value, "23:59:59");
}

/**
 * Both of the above: a chosen day plus a wall-clock time within it, as an
 * instant, refusing anything that does not read back as the same day.
 */
function localDateAt(value: string, time: string): string | null {
  const instant = new Date(`${value}T${time}`);

  if (Number.isNaN(instant.getTime())) return null;

  const iso = instant.toISOString();

  return localDateFromInstant(iso) === value ? iso : null;
}

export function localDateFromInstant(value: string): string {
  const instant = new Date(value);

  if (Number.isNaN(instant.getTime())) return "";

  const month = String(instant.getMonth() + 1).padStart(2, "0");
  const day = String(instant.getDate()).padStart(2, "0");

  return `${instant.getFullYear().toString()}-${month}-${day}`;
}
