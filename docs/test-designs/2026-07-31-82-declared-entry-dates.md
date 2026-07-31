# Test Design Brief — #82, a declared entry needs a date control, not a text box

Issue: #82, "fix: a declared entry cannot be written, because its dates are bare text boxes".
Reported from running the application: *"Writing custom jobs doesn't seem to work, once it's input
it's not shown anywhere."* Entirely under `client/`. No Elixir file and nothing under `test/` is
edited.

Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate", and its `client/` subsection. **Committed
alone, first, ahead of every line of production code**, which is the whole of what the gate asks and
is what #80 failed to do one commit ago — `docs/test-designs/2026-07-31-80-no-paste-box.md` records
that failure and the review finding that caught it. Nearest precedent read before writing:
`docs/test-designs/2026-07-30-73-peer-names-client.md`.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began.

## What is being built

`DeclaredEntryForm` in `client/src/features/profile/profile-route.tsx` renders **From** and **Until**
as bare `<input>` — no `type`, no placeholder, no example — and `draftPayload` sends whatever was
typed as `starts_at` / `ends_at`. The column is `:utc_datetime`, so Ecto casts it. Measured against
the running application:

| Typed | `Ecto.Type.cast(:utc_datetime, …)` |
| --- | --- |
| `2024-03-01` | `:error` |
| `01/03/2024` | `:error` |
| `March 2024` | `:error` |
| `2024` | `:error` |
| `2024-03-01T09:00:00Z` | `{:ok, ~U[2024-03-01 09:00:00Z]}` |

So the only input that is accepted is a full ISO-8601 instant with a zone, which nothing on screen
asks for or hints at. Everything else is `unprocessable_entity`, the entry is never written, and the
list stays empty — which is precisely the report.

**The refusal is rendered, which is why this reads as "nothing happened" rather than as an error.**
`<Notice>` sits at the top of the route, far above a form near the bottom, and says "That was not
accepted as written. Anything the server said about a particular field is below" over Ecto's
`is invalid`. Neither sentence names a format. The employer's shift form, by contrast, renders its
`<Refusal>` directly beneath itself.

The fix is a date control plus a conversion. The conversion already exists for shifts and is tested;
this unit hoists it and adds the inverse.

## Decision 1 — `type="date"`, not `type="datetime-local"`

The employer's shift form uses `datetime-local` because a shift genuinely has a time — 18:00 on
9 March. A declared job entry does not: somebody writing down that they were a chef somewhere in 2024
has no hour to give, and would have to invent one.

**And inventing one is not optional with `datetime-local`.** That control yields `""` until *both*
halves are filled, so the form's `incomplete` guard keeps the submit button disabled — which is the
reported bug reappearing in a different costume: a form that will not go through and does not say
why. `type="date"` yields a value as soon as a day is chosen.

The cost is that a date must be widened into an instant, which is Decision 2.

## Decision 2 — the day is read in the reader's zone, and `T00:00` is what makes that true

This is the trap the unit exists around, and it is silent:

```
new Date("2024-03-01")        -> 2024-03-01T00:00:00.000Z   // UTC midnight
new Date("2024-03-01T00:00")  -> 2024-03-01T05:00:00.000Z   // local midnight (America/New_York)
```

A date-only string is parsed as **UTC** per the ECMAScript grammar, while a date-*time* string
without an offset is parsed as **local**. So the naive `new Date(value).toISOString()` is wrong for
every reader not on UTC, and wrong in the direction that shifts a declared job to the previous day
for anybody east of it. Appending the time part is load-bearing, not decoration.

The reader's zone is the right one for the same reason `instantFromLocal`'s moduledoc already gives
for shifts: the value carries no offset, and the person choosing the day is the person holding the
device. It is also the zone the entry will be *rendered* back in, by `termLabel`, so the round trip
is closed.

**Both bounds are the start of their day.** A declared entry is checked against nothing — no
exclusion constraint, no overlap rule, only `ends_at > starts_at` — so there is no half-open interval
to be careful about, and "start of day" for both is what makes `termLabel` render back the two days
the worker chose.

## Decision 3 — the helpers go in `src/app/instant.ts`, and `instantFromLocal` moves with them

`instantFromLocal` lives in `client/src/features/employer/employer.ts` because U4 wrote it there.
`src/app/instant.ts`'s own moduledoc records the rule for exactly this situation: it was created when
`instantLabel` and `termLabel` acquired a second caller across a feature boundary, and it says *"new
callers import from here."* This unit is that second caller.

So `instantFromLocal` is hoisted, `employer.ts` re-exports it as `room.ts` already re-exports the
other two, and the two new functions are written beside it. A second copy under `features/profile/`
is the one-rule-two-spellings shape this tree has fixed four times under other names.

## Decision 4 — the amend form needs the inverse, and it is not the same function backwards

`DeclaredEntryForm` serves both writing and amending. The amend path passes `initial` from a stored
entry, whose `startsAt`/`endsAt` are ISO instants — and a `type="date"` input given
`2024-03-01T05:00:00.000Z` shows **nothing at all**, silently, because the value does not match the
control's expected format. So amending would present two blank date fields over an entry that has
dates, and saving would then be refused for the fields being empty.

`localDateFromInstant` is therefore part of the fix rather than a nicety. It reads the local calendar
parts, so it composes with Decision 2 to round-trip.

## Acceptance criteria

1. **From** and **Until** are `type="date"`.
2. A day chosen in the form reaches the channel as an ISO-8601 instant with a `Z`, not as the typed
   string.
3. That instant names local midnight of the chosen day, in the reader's zone.
4. Amending an existing entry pre-fills both date fields with the entry's own days.
5. A value that is not a date yields `null` rather than throwing out of a submit handler.
6. `instantFromLocal` has one definition; the employer surface is unchanged in behaviour.
7. The refusal notice is rendered where the form is, not only at the top of the route.

## Edge cases

- **A zone east of UTC**, where local midnight falls on the *previous* UTC day. `Pacific/Kiritimati`
  is UTC+14 and this suite already runs in it: local midnight on 1 March is `2024-02-29T10:00:00Z`.
  A round trip that survives this survives the ones that matter.
- **DST at or near midnight.** `America/Santiago` springs forward *at* midnight, so local midnight
  does not exist on that day; JS resolves it to 01:00 and the calendar day is preserved. Swept 2020
  to 2027 across `America/Santiago`, `Asia/Beirut` and `Australia/Lord_Howe` before writing this —
  every day round-trips.
- An empty date field — the submit stays disabled, as now.
- A stored instant that is not midnight (written through the API rather than this form): the date
  field shows its day, and re-saving moves it to that day's midnight. Accepted, and named below.

## Regression risks, by path

- `client/src/features/employer/employer.ts` and `employer.test.ts` — `instantFromLocal` moves.
  Its tests must keep passing against the re-export or be repointed.
- `client/src/features/employer/shifts.test.tsx` — drives the shift form end to end.
- `client/src/features/profile/profile-route.test.tsx` — drives `declare_entry` and asserts the
  exact payload pushed (`starts_at: "2024-01-01T00:00:00Z"`), so it moves with the conversion.
- `client/src/app/instant.ts` — gains exports; `room.ts` re-exports from it.

## Test matrix

| # | Scenario | Asserts | Fails without |
| --- | --- | --- | --- |
| 1 | `instantFromLocalDate("2024-03-01")` under `Pacific/Kiritimati` | `2024-02-29T10:00:00.000Z` | the `T00:00` append — without it the answer is `2024-03-01T00:00:00.000Z`, the same for every reader |
| 2 | The same, under `Etc/UTC` | `2024-03-01T00:00:00.000Z` | nothing — this is the **control** showing test 1 is not vacuous |
| 3 | `localDateFromInstant(instantFromLocalDate(d))` for a spread of days, in a pinned non-UTC zone | equals `d` | either half using a different zone from the other |
| 4 | `instantFromLocalDate` given `""`, `"March 2024"`, `"2024-13-45"`, `"2024-03-01T09:00"` | `null` each | the `^\d{4}-\d{2}-\d{2}$` guard |
| 5 | `localDateFromInstant("not an instant")` | `""` | the `Number.isNaN` guard |
| 6 | Type a day into **From**/**Until** and submit | the pushed payload's `starts_at` ends in `Z` and is not the typed string | the conversion at the submit boundary |
| 7 | Open the amend form on an entry | both date inputs hold the entry's own days | `localDateFromInstant` on the `initial` path |
| 8 | Submit a draft the server refuses with `unprocessable_entity` | the field message is rendered inside the form's own fieldset | the `<Refusal>` beside the form |

**Row 2 is the control for row 1 and is the point of the pair.** A conversion that ignores timezones
entirely — `value + "T00:00:00.000Z"` — passes row 1's *shape* and every round trip run under UTC. It
fails row 1 under Kiritimati and only there. Asserting the round trip alone, in whatever zone the
runner happens to be in, is the "agrees with itself for any value" shape.

## Controls, listed explicitly

- **Row 1's control is row 2**: the same input in two zones, asserted to two *different* literals. One
  zone alone cannot distinguish a correct conversion from one that ignores zones.
- **Row 3's control is row 1**: a round trip is satisfied by two functions that are wrong in
  compensating directions (both treating the value as UTC), so the round trip needs an absolute
  assertion beside it.
- **Row 6's control** is that the pushed value is asserted `not.toBe` the typed string as well as
  matching `/Z$/` — a form that passed the raw text through would satisfy a `toBeTruthy`.
- **Row 7's control** is an entry whose day differs from today, so a pre-fill that rendered "now"
  rather than the entry's value fails.

## Implementation constraints

- One definition of `instantFromLocal`; no second copy under `features/profile/`.
- Nothing in this client may read `Date.now()` or compare against a clock — `src/app/instant.ts`
  says so and the offsettable server clock is why.
- The suite forbids `!` and casts; narrow a `string | null` with a `throw`.

## Quality scores, self-assessed

| Dimension | Score | Note |
| --- | --- | --- |
| Acceptance criteria assertable | 5/5 | each maps to a matrix row |
| `Fails without` honest | 5/5 | each names a deletable mechanism |
| Controls real | 5/5 | rows 1/2 are the pair that matters and were measured before writing |
| Gate followed | 5/5 | committed alone, first |

## Residue, accepted and on the record

A declared entry stored with a non-midnight instant — written through the API rather than this form —
shows its day in the date field, and re-saving normalises it to that day's midnight in the reader's
zone. Nothing in this application writes such a row, and the alternative is keeping a time control the
worker has no answer for. Named here rather than discovered later.

## Revisions made during implementation

**Criterion 7 and matrix row 8 were not built, and the reason is a design question
this unit should not answer alone.** The plan was to render the refusal beside the
form, because the notice at the top of the route is far above the fieldset and a
worker reading "nothing happened" is how this bug was reported in the first place.

It was built, and it made the surface worse: `<Notice>` is generic across all four
write actions, already renders the sentence *and* `FieldMessages`, and carries a
Dismiss button — so the form-side copy was a **second** rendering of the same
message, and `profile-route.test.tsx` failed with "Found multiple elements". Making
it the only rendering means either scoping `FieldMessages` out of `<Notice>` for
two of the four actions, which is a conditional nobody will be able to read in six
months, or moving notices per-action across the whole surface, which is a
restructure #82 did not ask for and the report does not need.

Reverted, and recorded rather than left implicit. The date control is the fix: the
reported failure was that *no value a person would type was ever accepted*, and
that is closed whether or not the refusal moves.

**The `NaN` check does not catch an unreal day, and the brief said it did.** Matrix
row 4 listed `2024-13-45` under "the regex guard" and the implementation's first
comment claimed `new Date` answers `Invalid Date` for a day like `2024-02-31`.
Measured: it does not. V8's lenient parser rolls `2024-02-31T00:00` forward to
2 March, so the function answered an instant **two days** from the one asked for,
silently, and the regex cannot see it because the shape is right.

`instantFromLocalDate` now closes with a round trip — convert, read the day back
with `localDateFromInstant`, refuse if it is not the day that went in — which
states the pair's invariant where it can be enforced rather than only asserted.
Its own test carries the control: a real end-of-month day must still pass, or a
guard that refused everything would satisfy the negative half.

**One acceptance criterion could not be asserted the way the matrix assumed.**
Row 6 covers the conversion, and measurement showed that removing `type="date"`
from both inputs kills **nothing**: jsdom's text input accepts `2024-01-01` as
readily as a date input, so every payload assertion passes against exactly the
bare boxes this unit removes. What a date control buys is a person not having to
guess a format, which is a claim about a human rather than about a DOM. The
attribute is therefore asserted directly, which is the pair `shifts.test.tsx`
already keeps for `datetime-local`, and it is the only assertion that kills that
mutation.

## Mutations run

| Mutation | Kills |
| --- | --- |
| Drop the `T00:00` append | 4 |
| Read the day back with `getUTC*` | 5 |
| Drop the round-trip guard on an unreal day | 1 |
| Drop `padStart` | 8 |
| Send the typed day through unconverted (the reported bug) | 1 |
| Pre-fill the amend form from the raw instant | 1 |
| Remove `type="date"` from both inputs | 0 → **1** after the attribute assertion was added |

## Revisions made after review

`ce-code-review`, four reviewers. Standards passed with the gate verified
mechanically rather than trusted. Three findings acted on:

**The header of `src/app/instant.ts` had become false, and this unit is what made
it false.** It ended *"these functions render, and that is all they do"* — an
unqualified claim about the whole file — while the `instantFromLocal` doc comment
added a hundred lines below named itself as an exception to it. Three of the five
functions there now compute. The header says the rule is **nothing here reads a
clock** instead, which is the property KTD5 actually needs: a conversion is a pure
mapping, so the offsettable clock cannot make it wrong, where a comparison against
`Date.now()` could.

**A branded day type was written to separate days from instants, measured at zero
kills, and rejected.** The reviewer's point is fair — `DeclaredEntryDraft` holds
instants, the form's state holds `YYYY-MM-DD`, both are `string`, and only
`submit`'s conversion stands between them. But TypeScript's excess-property check
applies to object *literals* and not to variables, so a structurally wider
`{…, __days: true}` is freely assignable to the narrower type and `onSubmit(days)`
still compiles. Branding the *instant* side is what would work, and that means
changing a type the whole profile surface and `contract.ts` share for one call
site. The reasoning is in the code beside `localDays` so nobody re-derives it.

**`client/README.md` described `instant.ts` as holding two functions.** It holds
five now, three of which go the other way.

### Correctness pass — three defects, two of them this brief's own reasoning

The correctness reviewer verified the pair inverse across **all 418 IANA zones
for every day 1970–2035**, reproduced every row of the mutation table, and found
three things wrong. Two of them trace to decisions written above.

**F1 — the list rendered raw ISO instants, and Decision 2's last sentence was
false.** That sentence says *"it is also the zone the entry will be rendered back
in, by `termLabel`, so the round trip is closed"*. `profile-route.tsx` imported
neither `termLabel` nor `instantLabel`: its `Term` printed the two strings
verbatim. So east of UTC a worker chose 1 January, the conversion correctly
stored `2023-12-31T23:00:00.000Z`, and the entry they had just written was listed
under **the previous day**, in a spelling nobody reads, beside an amend form
showing the date they picked. Demonstrated in the project's own harness under
`TZ=Europe/Zagreb`.

`Term` calls `termLabel` now. **The test that would have caught it did not exist
and does**: every assertion in the write test is about the payload that *left*,
and the fixture answers with a fixed wire row rather than the one just sent, so a
render that printed instants satisfied all of them. The new test asserts the
stored strings are absent and a formatted day is present, with an independently
built `Intl.DateTimeFormat` as the oracle rather than the module's.

**F3 — a one-day job could not be written, and Decision 2 reasoned past it.**
"Both bounds are the start of their day" was argued from there being no
half-open interval to honour, and never considered the two bounds being *equal*.
`declared_entries_term_ordered` and `validate_term/1` both require strictly
greater, so a worker choosing the same date twice — an ordinary one-day gig in
this industry — was refused with "must be after the start" about two dates they
had picked on purpose.

`instantFromLocalDate` is now `startOfLocalDate` and `endOfLocalDate`, the second
answering 23:59:59. **Not** the next day's midnight, which is the other way to
close it: this column is compared against nothing, so there is no half-open
convention to honour, and end-of-day keeps `localDateFromInstant` an exact
inverse of both bounds — next midnight would read back as the following day and
the amend form would show a date the worker never picked. Seconds rather than
milliseconds because `:utc_datetime` truncates.

**F2 — the `^\d{4}-\d{2}-\d{2}$` guard killed nothing and its justification was
false.** It claimed to be what refuses a `datetime-local` value; measured,
`"…T09:00" + "T00:00"` really is `Invalid Date`, and `2024-3-1` reads back as
`2024-03-01` and fails the round trip. Every value it was written to refuse is
refused without it. Deleted, and the round-trip check is stated as the whole of
the validation.

**Two residues accepted, both named by the reviewer:** on the 23 (zone, day)
pairs in the entire tz database where the whole midnight hour is skipped across a
date-line change, the guard answers `null` and the submit stays disabled with
nothing on screen to say why; and amending an entry whose stored instant is not
local midnight rewrites both bounds even when only the label changed. Nothing in
this product reaches 1994 Kiritimati, and both bounds move together so the
ordering cannot break.

**Mutations, from a committed base:** `Term` prints the instant again (1), both
bounds start-of-day again (1), `endOfLocalDate` returns start-of-day (4).
