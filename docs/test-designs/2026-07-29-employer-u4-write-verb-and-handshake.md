# Test Design Brief — employer U4, the client's write verb and the handshake on screen

Plan: `docs/plans/2026-07-29-001-feat-crude-employer-view-plan.md`, section `### U4`, plus
KTD-E8 and OQ1.
Origin: `docs/brainstorms/2026-07-29-crude-employer-view-requirements.md` (R2, R5, R6, R7, R19;
AE1, AE2, AE6, AE10).
Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate". Nearest precedent:
`docs/test-designs/2026-07-29-employer-u3-shifts-and-roster.md`, whose branch this one is cut
from.

## ⚠️ This brief was written after the implementation, and the gate did not run

Every other brief in this directory is the first commit on its branch, ahead of every line of
production code. **This one is not.** The branch `feat/employer-u4-handshake-on-screen` was one
commit — `2512c54`, production code and tests together — and this file arrives behind it, in
response to Greptile's review of PR #61.

`AGENTS.md` is explicit about what that costs: *"The commit ordering is the evidence, so the
ordering is the rule … A reviewer reading `git log` can then tell a unit that ran the gate from
one that skipped it — and nothing else in the tree can tell them."* **So the ordering evidence
for U4 is absent and cannot be manufactured.** A brief committed now proves nothing about what
was designed before the code, and back-dating it into the history would be a declaration
standing in for a fact — the exact substitution this project spent a day removing.

**Whose omission it was.** The orchestrating dispatch required the gate for employer U1, U2 and
U3 and did not repeat the requirement for U4. It is the second time client work has skipped it;
U12's four slices did too, and that gap is now issue **#62**.

**What this file therefore is, and is not.**

- It **is** an accurate record of what the unit built, what it turns on, and what its tests
  prove. The `Fails without` column and the mutation record below were **measured against the
  tree as shipped** — every row was applied to a clean checkout, run, and reverted (see
  `## Mutation record`). They are evidence, not recollection.
- It **is not** a prediction. Nothing here was written before the code it describes, so no row
  below can claim to have anticipated a defect.
- The decision sections are reconstructed from the moduledocs the implementation wrote, which
  carry the arguments in the ordinary way. Where a decision was reached *during* implementation
  rather than before it, the section says so.
- There is no `## Revisions made during implementation` section, and there cannot be one: a
  revision is a gap between a claim and a tree, and there was no prior claim to differ from.

**Approver: the orchestrating agent, in the human's place**, as with U1 through U3 — and here
that substitution is weaker than usual, because there was no artifact to approve at the time
approval would have mattered.

## What is being built

Flow F1 in a browser, both halves, and one verb underneath them. This is client-only: no Elixir,
no migrations, no route changes on the server. **374 → 439 client tests.**

```
/employer   pick a venue → see the people → issue an offer → copy the code once
/claim      paste the code → see the engagement it produced
```

The two are used by two different people in two windows at the same time; that simultaneity is
the demo. Underneath, `ApiClient` gains `write` — the first authenticated non-GET this client has
had — and `fake-api.ts` gains `writesTo` plus a default-failing `write` to drive it.

Three things here are behaviour rather than transport, and each gets a headed decision below: the
shape of `write`, which list the venue picker reads, and where a refusal's sentence comes from.

## Decision 1 — `write` is one verb with an optional decoder, and the decoder is the whole difference from `read`

KTD-E8 asks for one verb beside `read` rather than a method per route, and the reasoning holds:
*"a feature owns its paths and its wire shapes; this file owns 'an authenticated request that
decodes or fails'."* `features/rooms/rooms-api.ts` is already the first tenant of that rule for
reads, and a `venueRooms()`/`shiftRooms()`/`invitations()` grab-bag in `client.ts` is what the
rule exists to prevent.

What the plan does not say, and what this unit had to settle, is **the signature**. It takes the
method *and* the single status that counts as success, because the two callers it already has
disagree about both: `POST …/invitations` succeeds `201` with a body, and U5's roster removal
succeeds `204` with none.

**The decoder is optional, and that is the load-bearing part.** Omitting it means the response
body is never read — which is what makes a bodiless `204` a success rather than
`malformed_response`. A `read`-shaped `write` gets exactly this wrong, and gets it wrong in the
direction that matters: U5's DELETE would report a removal as failed *after it succeeded*.
`read` cannot have that branch, because every route it serves answers `200` with a body, so a
`204` there is contract drift and is reported as one.

**Both halves are pinned, and one is the other's control.** "Treats a bodiless 204 as a success"
and "still refuses a 204 that was not the status the caller named" fail to different mutations
(rows 1 and 2 of the mutation record), so *"no body was read"* did not quietly become *"any
status is fine"*.

## Decision 2 — the picker reads the grant-based list, and the plan's approach section is wrong

The plan's U4 approach says venue discovery *"reuses `GET /api/venue-rooms` from #48"*. Its own
decisions section settles OQ1 the other way — *"OQ1 — venue discovery: a new grant-based read.
Not `GET /api/venue-rooms`"* — and U1 built `GET /api/employer/venues` for it. **The approach text
was never updated.** This unit follows the decision, not the approach.

The two answer the same two keys and are not the same list. `Rooms.list_venue_rooms/1` applies
`unsuspended/2`; `Engagements.fetch_grant_holding_engagement/2` never consults a suspension. So a
manager who used the person-side venue-room opt-out — their own choice, about their own reading,
at their own venue — would **keep every authority they had and vanish from their own picker**,
with no other way in and nothing failing anywhere to say why: every employer request they made by
hand would still be answered. That is the coupling KTD18 exists to prevent, arriving at the
transport after both tiers below it got it right.

**The test asserts the path, not the response**, and that is forced rather than stylistic: both
reads render `{venue_id, name}`, so a content assertion cannot tell them apart and would pass
against the wrong endpoint. It asserts the positive path *and* the negative one, because a page
that read both would satisfy the first alone.

## Decision 3 — this surface renders the server's sentence, against a standing client rule

`src/app/failure-message.ts` states the rule: the envelope's `code` is the machine-readable
discriminator, `message` is for a human reading a log, so the copy lives client-side keyed on the
code. The rooms, peers and profile surfaces each carry a switch built that way. **This surface
deliberately does the opposite, and it is a measurement rather than a preference.**

`HospitalityComsWeb.ErrorEnvelope`'s `code` *is* the response's status atom, and
`HospitalityComsWeb.ClaimController` answers `409` for two different refusals on purpose:
`:already_claimed` — the offer is gone for good — and `:grant_not_live` — the code is fine and
**unspent**, and re-issuing the authority makes the same code work. Those are opposite
instructions to the person reading them. **A switch keyed on `conflict` can say one of them and
must be wrong about the other**, and R6 asks in as many words for *"a sentence that distinguishes
those three"*.

So `failure.message` is rendered, and the cost is written down rather than left implicit: this
client no longer controls that copy, and a server-side rewording changes what a worker reads with
nothing here to review it.

**Three failures keep local copy**, and they are the ones the route did not author: a network
failure and a malformed body carry no sentence from this API at all, and `unauthorized` comes
from `HospitalityComsWeb.PersonAuth`, a pipeline above every controller here.

**Each surface therefore gets two tests and not one.** One watches a sentence arrive; the second
sends a *different* sentence under the same code and asserts the first is **absent**. A component
hard-coding a string that happened to match the first fixture passes the first test and fails the
second.

## Decision 4 — the claim panel is its own feature directory

`POST /api/claims` is not under `/api/employer` and must not be: a claimant needs no grant, no
engagement and no prior relationship to the venue. The code is the whole of what they hold, and
that is the boundary the demo exists to show. **A claim panel filed under `features/employer/`
would say the opposite with its directory name.**

`/claim` is likewise a route rather than a tab on `/employer`. Two people use the two surfaces in
two windows at once, and a mode switch would put a manager one wrong click from a claim box and a
new starter one wrong click from issuing offers at a venue they do not manage. Both sit behind
`RequireSession`: the claimant needs their **own** session, because a code confers a job and not
a log-in, and that is the property the second demo window exists to show.

## Decision 5 — three hoists, and each earns its place rather than being tidying

- **`src/app/use-fetched.ts`** — `features/rooms/use-room-lists.ts`'s private hook, hoisted on its
  second caller and generalised past lists. Two lists in rooms and two here, all four with the
  same three hazards and the same three non-answers. `Loaded` is re-exported from
  `use-room-lists.ts`, so **no rooms file changed**. It lives in `src/app/` rather than
  `src/api/` because it is React state and **nothing in `src/api/` imports React** — which is
  what lets the client and its decoders be tested with no renderer at all.
- **`src/app/session-bar.tsx`** — `HomeRoute`'s identity block, moved verbatim, so log out exists
  on every page a session rests on. Hospitality is a shared-terminal industry and U4 adds two
  full pages of their own.
- **`Rooms.termLabel` and `Rooms.instantLabel` are exported** and imported from
  `features/employer/` and `features/claim/`. A term rendered one way beside a shift room and
  another way beside an engagement is one product speaking twice — the defect this tree has fixed
  three times under other names.

**The third hoist is incomplete and this brief is where that is on the record.** `room.ts`'s own
moduledoc says the cross-feature import is debt: *"`instantLabel` and this belong in a shared
module the way `src/socket/topic-id.ts` does, and the move belongs to whichever unit adds the
caller after U4's two."* U4 **is** that unit — it added both callers — so by the rule the code
itself states, the move was due in this unit and was deferred by one commit. It is paid in the
commit that follows this brief on the same branch, and the reason it is called out here rather
than silently fixed is that the debt was created by the same change that owed it.

## Acceptance criteria

1. `write` sends the method it was given, the body as JSON, and the bearer token.
2. `write` carries a method that is **not** `POST` unchanged, and sends no body when given none.
3. `write` answers the decoded value on the status the caller named, and treats any other
   status — including a `200` where `201` was promised — as a failure carrying that status.
4. `write` reads the error envelope out of a refusal, keeping both `code` and `message`, and
   keeps a `422`'s per-field messages attached to the fields they name.
5. `write` turns a decoder's `null` into `malformed_response`, and a rejected `fetch` into
   `network_error`, rather than throwing either.
6. `write` with **no decoder** treats a bodiless `204` as a success with the value `null`.
7. `write` with no decoder **still refuses** a `204` that was not the status the caller named.
8. `createFakeApi`'s `write` fails by default, and takes an override.
9. `writesTo` keys on the method **and** the path, puts fixtures through the real decoders, and
   can express a refusal as well as a success.
10. Every employer and claim decoder builds its object field by field: a payload carrying
    `person_id`, `email` or `claim_code_digest` decodes **without them**, and the resulting key
    set equals a literal written out in the test file.
11. A `201` with no `claim_code` is refused rather than defaulted; a claim body with no
    `accepted_at` is refused rather than rendered as an undefined instant.
12. `accepted_at` and `starts_at` survive the trip as two different values (KTD13).
13. The venue picker reads `/api/employer/venues` and **not** `/api/venue-rooms`.
14. **AE10**: a person who manages nothing sees one sentence — not an empty page, not an error.
15. No people are fetched until a venue is chosen; choosing one fetches that venue's.
16. **R7 / AE6**: a person on the list is a role, a term and an engagement id. No `person_id` and
    no email address reaches the DOM however the server answers.
17. Refreshing the people list is a **second request**, not a re-render.
18. A list that cannot be read renders the failure, not the empty-list sentence, and offers a
    retry.
19. **R2 / AE1**: issuing sends `role_label` and nothing else, and shows the plaintext code with
    the warning that it will not be shown again, above it.
20. **AE2**: two clicks issue one offer.
21. A blank role does not reach the API.
22. Dismissing the code loses it: **re-rendering does not bring it back**, logging out does not,
    and switching venue does not.
23. **R6**, both surfaces: a refusal renders the envelope's sentence, and a *different* sentence
    under the same code renders that one instead.
24. A `409` — outside `KNOWN_ERROR_CODES` — renders its sentence rather than "a status this
    client does not know about".
25. `unauthorized` renders this client's own copy on both surfaces, and not the server's.
26. **R5**: a claim sends `{claim_code}` and nothing else, and renders the engagement it produced
    including both instants.
27. An empty or whitespace-only claim never reaches the API.
28. Two clicks claim once.
29. A refused claim leaves the code in the box and the form usable.
30. The rooms surface's files are **unchanged** by the `useFetched` hoist, and its suite passes.

## Edge cases

- **A `204` where a `201` was promised.** Success by status, not by 2xx. Criterion 7 is the half
  people forget once criterion 6 exists.
- **A `200` where a `201` was promised.** Same rule from the other side; it means something in
  front of Phoenix answered.
- **A `409` this client has no code for.** `KNOWN_ERROR_CODES` is traced through the four session
  endpoints alone, so `conflict` and `gone` decode as `unrecognised` with `rawCode` kept. That is
  harmless here **only because** the sentence is rendered — a code-keyed surface would answer "a
  status this client does not know about" to every R6 refusal. `errors.ts` is untouched.
- **A venue with no people.** `200 {engagements: []}` is a sentence, not a failure, and must not
  render as the failure arm.
- **A person who manages nothing.** AE10. The picker is empty, with a sentence, and no alert.
- **A claim response carrying no venue name.** `ClaimController` renders `venue_id` and no name.
  Not fixable from the client — joining a name is a server change — so the panel labels the uuid
  and points at `/rooms`, where the name arrives.
- **A code dismissed and then re-rendered.** The plaintext code exists in component state and
  nowhere else in the world, so "hidden" and "never rendered" are the same DOM. The negative
  assertion is worthless unless the positive state is reached first.
- **Two venues in one session.** Switching remounts rather than re-renders, so a code issued at
  venue A cannot appear beside venue B's name.
- **A term that crosses midnight, rendered in the reader's timezone.** Inherited from
  `termLabel` rather than re-tested here; every fixture reads its expected string back out of the
  renderer rather than spelling `9 Mar`, because a spelled fixture is green on one machine and red
  on another.

## Regression risks — existing files at risk, by path

| Path | Why | How it is covered |
|---|---|---|
| `client/src/features/rooms/use-room-lists.ts` | `useFetched` moves out of it | `Loaded` re-exported; the file's public shape is unchanged and `room-lists.test.tsx` passes untouched |
| `client/src/features/rooms/room-lists.test.tsx` | consumes the hoisted hook through the rooms surface | unchanged, and mutation 22 kills a body in it — the hoist is still load-bearing there |
| `client/src/features/rooms/room.ts` | `termLabel` and `instantLabel` become exports | `room.test.ts` unchanged; the timezone matrix is the thing at risk and it is re-run under two zones |
| `client/src/app/routes/home-route.tsx` | the identity block becomes `SessionBar`; two links are added | `app.test.tsx`'s tab-strip keyboard wrapping is asserted over exactly three entries, so the two new doors are **links under their own heading**, not tabs |
| `client/src/app/app.tsx` | seven routes become nine | existing route tests unchanged |
| `client/src/test-support/fake-api.ts` | every surface test in the client is written against it | `write` is **added**, `read`'s default untouched; `fake-api.test.ts` asserts both defaults directly |
| `client/src/api/client.ts` | `expectStatus`/`expectBody` are now shared by `read`, `write` and the session calls | mutations 2 and 5 each kill tests in more than one describe block, which is the evidence that the sharing is real |
| the Elixir tree | must not move: client-only unit | asserted by not changing |

⚠️ **POTENTIAL REGRESSION** — one, disclosed per `AGENTS.md`'s format.

**`useFetched` moves from `features/rooms/use-room-lists.ts` to `src/app/use-fetched.ts`.**

- Current behavior: a private hook in a feature directory, with `Loaded<T>` exported from that
  file.
- Proposed change: the hook and its types move to `src/app/use-fetched.ts`, generalised past
  lists; `use-room-lists.ts` re-exports `Loaded`.
- What may stop working: any rooms file importing `Loaded` from its old home.
- Affected callers or surfaces: `room-lists.tsx` and `rooms-route.tsx` import `Loaded`; the
  re-export is what keeps them compiling untouched.
- Evidence and remaining uncertainty: no rooms file appears in the diff, and `npm run typecheck`
  is part of `verify`. None remaining.
- Safer alternative: copy it. Rejected — forty lines of stale-answer discipline duplicated in a
  feature directory is what `src/socket/topic-id.ts` was hoisted to stop.
- Regression coverage needed: none new. `room-lists.test.tsx` passing unchanged is the coverage,
  and mutation 22 proves it is not passing vacuously.

## Test matrix

65 new test bodies across six files. Every `Fails without` entry names a mechanism, and the
bracketed number is the mutation in `## Mutation record` that was applied to a clean tree to
demonstrate it. A row with no number is one whose mechanism was not separately mutated; four rows
name **nothing**, and those are this unit's finding rather than an omission — see
`## Four guards no single mutation can reach`.

Files: **client** = `src/api/client.test.ts`; **fake** = `src/test-support/fake-api.test.ts`;
**e-dec** = `src/features/employer/decode.test.ts`; **c-dec** =
`src/features/claim/decode.test.ts`; **employer** =
`src/features/employer/employer-route.test.tsx`; **claim** =
`src/features/claim/claim-panel.test.tsx`.

| # | Scenario | File | Kind | Fails without |
|---|----------|------|------|---------------|
| 1 | `write` sends the method, the body as JSON and the bearer token | client | unit | the bearer header on `write`'s own init [4] |
| 2 | it carries a method that is **not** POST, unchanged, and sends no body when given none | client | control | `method: request.method` rather than a literal [3]. **This is row 1's control** — row 1 asks for a POST, so a hard-coded POST passes it |
| 3 | it answers the decoded value on the status it was told to expect | client | unit | `expectBody` reaching the decoder at all |
| 4 | a `200` is a failure when `201` is what the route promises | client | boundary | the exact-status comparison [2] |
| 5 | it reads the error envelope out of a refusal, keeping code **and** message | client | boundary | `failureFrom`; R6 needs both halves to survive the trip |
| 6 | it keeps a `422`'s per-field messages attached to the fields they name | client | unit | the field-error branch of `decodeErrorEnvelope` |
| 7 | a decoder's `null` becomes `malformed_response`, not a value | client | boundary | the `value === null` guard [5] |
| 8 | a rejected `fetch` becomes `network_error` rather than a throw | client | boundary | `perform`'s try/catch |
| 9 | **a bodiless `204` is a success** | client | boundary | the optional decoder and the `expectStatus` branch [1]. The case U5's DELETE needs and the one a `read`-shaped `write` gets wrong |
| 10 | **a `204` that was not the status named is still refused** | client | control | the exact-status check inside `expectStatus` [2]. Row 9's control: "no body was read" must not become "any status is fine" |
| 11 | `createFakeApi`'s `write` fails when nobody stubbed it | fake | boundary | the default-failing `write` [6]. Every surface test runs in this environment and none of them can see it |
| 12 | `read`'s default fails too, which is the default `write` copies | fake | regression | the default-failing `read`, unchanged by this unit |
| 13 | an override is honoured, so a test that wants an answer gets one | fake | control | — . Rows 11–12 would hold for a fake that could never succeed |
| 14 | `writesTo` keys on the method **as well as** the path | fake | boundary | the `"<METHOD> <path>"` key. U5 puts a `DELETE` beside a `POST` on one path |
| 15 | a fixture goes through the real decoder, so a wrong shape fails in the fake too | fake | boundary | the `decode` call inside `writesTo` [5] |
| 16 | it can answer a named refusal, not only a success | fake | boundary | the `failure` member of `WriteReply`. Most of these surfaces are driven through refusals |
| 17 | a managed venue takes the `venue_id` and `name` the route renders | e-dec | unit | the two type guards |
| 18 | an entry with no name is refused rather than rendering an unnamed button | e-dec | boundary | the `name` guard |
| 19 | one bad entry fails the **whole** list | e-dec | boundary | `decodeEach`'s all-or-nothing. A list silently one entry short is a person missing from a venue's roll with no sentence saying why |
| 20 | an empty list decodes as an empty list, not as an absence | e-dec | boundary | the `Array.isArray` check preceding the loop |
| 21 | **an engagement has exactly the four keys the route renders** | e-dec | boundary | the field-by-field object [7] |
| 22 | **a payload carrying `person_id` decodes without it** | e-dec | boundary | the same object [7]. This is R18's fourth pin and the only one that holds when the server starts sending a field it should not |
| 23 | an entry missing the role label, or whose term is not two strings, is refused | e-dec | unit | the per-field guards |
| 24 | the list is read off the `engagements` key and nowhere else | e-dec | boundary | the envelope key |
| 25 | an issued offer carries the invitation and the plaintext code **beside** it | e-dec | unit | `decodeIssuedOffer`'s two-part shape — the code is not a property of the row |
| 26 | it keeps no `claim_code_digest`, whatever the response carries | e-dec | boundary | the field-by-field object |
| 27 | **a `201` with no claim code is refused, not defaulted** | e-dec | boundary | the required `claim_code` [8]. Defaulting it would show a successful-looking panel with nothing in it to copy, after the invitation had already been written |
| 28 | a `201` whose invitation does not decode is refused | e-dec | boundary | the nested decode |
| 29 | a claimed engagement has exactly the six keys the route renders | c-dec | boundary | the field-by-field object |
| 30 | a payload carrying the schema's other columns decodes without them | c-dec | boundary | the same object |
| 31 | **`accepted_at` and `starts_at` stay apart** | c-dec | boundary | the two separate reads [9]. KTD13: an engagement accepted before its term opens is confirmed and not yet active |
| 32 | a body with no `accepted_at` is refused, not rendered as an undefined instant | c-dec | boundary | the `accepted_at` guard [9] |
| 33 | it is read off the `engagement` key and nowhere else | c-dec | boundary | the envelope key |
| 34 | `isSubmittable` refuses a blank code and one that is only spaces, and accepts one with content | c-dec | unit | the `trim()`. The third assertion is the control |
| 35 | **the picker reads `/api/employer/venues`, and not `/api/venue-rooms`** | employer | boundary | `fetchManagedVenues`'s path [10]. Decision 2. Asserted on the path because both reads render `{venue_id, name}` and a content assertion could not tell them apart |
| 36 | each venue is named rather than shown as an id | employer | unit | the button label, with the id asserted **absent** |
| 37 | **AE10**: a person who manages nothing gets a sentence, no alert and no list | employer | boundary | the `empty` arm of `Unlisted` on a ready-and-empty list |
| 38 | no people are fetched until a venue is chosen | employer | control | **nothing** — the guard it was aimed at is unreachable [20]. Row 39's control regardless: a page fetching every venue's people on arrival would still pass row 39 |
| 39 | choosing a venue loads that venue's people | employer | integration | `useVenueEngagements` keyed on the choice |
| 40 | **R7 / AE6**: the row is a role and a term; no `person_id` and no email reach the DOM, and the fixture **sends both** | employer | boundary | the decoder's field list. The fixture carrying them is what stops this passing for the wrong reason |
| 41 | **refreshing is a second request**, not a re-render | employer | boundary | `useFetched`'s attempt bump [22]. `list_engagements/1` is active-at-instant and nothing here caches |
| 42 | a list that cannot be read says so, and offers to ask again | employer | boundary | `Unlisted`'s `failed` arm [21] and the envelope's sentence reaching it [12] |
| 43 | **R2 / AE1**: the offer sends `role_label` and nothing else; the code and its warning appear | employer | boundary | the body literal [11]. A client computing the term would be a second clock — `Clock.Offset` moves the server's instant and not this browser's |
| 44 | **AE2**: two clicks issue one offer | employer | boundary | the submit's `disabled` attribute [17]. Two clicks are two live claim codes, and the manager is only ever shown the second |
| 45 | a blank role does not reach the API | employer | boundary | the blank check on the attribute **and** in `onSubmit`, together [18b] — neither alone [18a] |
| 46 | **the code is gone after dismissal, and re-rendering does not bring it back** | employer | boundary | `dismiss` clearing `issued` [15]. The positive state is reached first, or "hidden" and "never rendered" are the same DOM |
| 47 | logging out drops the code | employer | boundary | the code living in component state alone — no store, no URL, no log |
| 48 | choosing another venue loses the code | employer | boundary | the `key={venueId}` remount [16] |
| 49 | **R6**: a refused offer renders the sentence the server sent, per-field messages included | employer | boundary | `failure.message` reaching the alert [12], [14] |
| 50 | **a different sentence under the same code renders that one**, and the first is absent | employer | control | the same [12]. Row 49's control: a hard-coded string that matched the first fixture passes 49 and fails this |
| 51 | a `409` this client has no code for renders its sentence | employer | boundary | the same [12]. A code-keyed surface answers "a status this client does not know about" |
| 52 | `unauthorized` gets this client's own words, and the server's are absent | employer | control | the `unauthorized` branch. The control for rows 49–51: it proves the surface is not simply printing every `message` it is given |
| 53 | **R5**: the claim sends `{claim_code}` and nothing else, and renders what it produced | claim | boundary | the body literal. `claim_invitation/2` casts nothing from the caller |
| 54 | **KTD13**: both instants are written, and they are different values | claim | boundary | two separate renders [26] and the decoder keeping them apart [9]. The fixture pulls them apart so a panel showing one twice fails |
| 55 | an empty submission does not call the API | claim | boundary | `isSubmittable` [23]. Asserted on the call count, because the sentence on screen is the same either way |
| 56 | a whitespace-only submission does not call the API | claim | boundary | the `trim()` [23] |
| 57 | two clicks claim once | claim | boundary | the submit's `disabled` attribute [24b] — not the hook's guard [24a]. The second attempt would write "already redeemed" over the engagement the first just produced |
| 58 | **R6**: a refused claim renders the sentence the server sent | claim | boundary | `failure.message` reaching the alert |
| 59 | a different sentence under the same code renders that one | claim | control | the same. Row 58's control |
| 60 | **the other `409` renders**, sharing a code with row 59 and meaning the opposite | claim | boundary | the same. This is the row Decision 3 exists for: `already_claimed` and `grant_not_live` are one status and opposite instructions |
| 61 | `unauthorized` gets this client's own words | claim | control | the `unauthorized` branch [13] |
| 62 | a refusal leaves the code in the box and the form usable | claim | boundary | not clearing `code` on the failure path [25]. It is cleared only on success, where keeping it would invite a second claim of a spent code |
| 63 | the rooms suite passes **unchanged** after `useFetched` is hoisted | rooms | regression | the re-export, and the hook's behaviour surviving the move [22 kills a body in `room-lists.test.tsx`] |
| 64 | the landing page's tab strip still wraps over exactly three entries | app | regression | `/employer` and `/claim` being links under their own heading rather than a fourth and fifth tab |
| 65 | `room.test.ts`'s timezone matrix passes with `termLabel` exported | rooms | regression | the module-load formatters and the `vi.resetModules()` re-import that reaches them |

**Rows do not map one to one onto bodies.** 65 rows, 65 new bodies, but not pairwise: rows 23 and
34 are two bodies each, and rows 63–65 are existing files rather than new bodies.

## Controls, listed explicitly

- **Row 2 is row 1's control.** Row 1 asks for a `POST`, so a `write` that hard-coded `"POST"`
  passes it. Measured: mutation 3 kills row 2 and leaves row 1 green.
- **Row 10 is row 9's control**, and it is the pair the whole `write` shape exists for. Mutation
  1 (read-shaped `write`) kills 9 alone; mutation 2 (any 2xx succeeds) kills 10 alone. Neither
  mutation kills both, which is what makes them two properties rather than one restated.
- **Row 13 is rows 11–12's control.** "Fails by default" has to be a *default* — without an
  override test, both would hold for a fake that could never succeed, and no surface could be
  tested at all.
- **Row 22's fixture carries `person_id` and `email`.** Without them, "the decoder omits the
  field" and "there is no field to omit" are the same green — the shape
  `docs/solutions/test-failures/tests-that-certify-nothing.md` calls *"cleared and never set as
  the same DOM"*. Row 40 carries the same fixture at the DOM tier, and asserts against
  `document.body.textContent` as well as the list, so a leak anywhere on the page fails it.
- **Row 34's third assertion is its own control.** A validator refusing everything passes the
  first two.
- **Row 38 is row 39's control.** A page that fetched every venue's people on arrival passes row
  39 by itself; row 38's call-count assertion is what rules it out. Note that row 38's *stated*
  mechanism is unreachable — see the section below — but its control function is intact, because
  it is asserted on `read` having been called exactly once.
- **Row 46 reaches the positive state first, and that is the requirement rather than the style.**
  The plaintext code lives in component state and nowhere else, so a test that only asserted the
  absence would pass against a page that never rendered a code at all. Rows 47 and 48 have the
  same shape and take the same precaution.
- **Row 50 is row 49's control, and row 59 is row 58's.** Same code, different sentence, and the
  *first* sentence asserted absent — so a component keyed on `code` cannot pass both by rendering
  one sentence twice. Measured: mutation 12 kills row 49 and row 50 together, which is correct,
  because a surface that renders local copy fails both.
- **Rows 52 and 61 are the controls for rows 49–51 and 58–60.** Without them, "renders the
  envelope's sentence" would be satisfied by a surface that prints every `message` it is ever
  given, including `PersonAuth`'s log-facing one.
- **Row 42's asserted sentence is `readsFrom`'s own 404 fixture, verbatim** — worded for a room,
  because the fake is shared. Reading a *room's* sentence on the employer page is the point: what
  is on screen came off the envelope, not out of the test file.
- **Row 45's mechanism is a pair, and only the pair.** Neither half alone is reachable by a
  mutation; the section below says why that is recorded rather than fixed.
- **Every list assertion names a value the fixture actually carries**, and every negative
  assertion sits beside a positive one in the same body.

## Four guards no single mutation can reach

This is the unit's methodological finding, and it is stronger than the one the commit message
recorded. **Four guards in U4 are redundant with a second guard in front of them, so removing
either alone kills nothing.**

| Guard | Mutation | Killed | The guard in front of it |
|---|---|---|---|
| `useOfferDesk`'s `issuing` check | 19 | **0** | the submit button's `disabled` attribute |
| `OfferForm`'s blank-role `disabled` | 18a | **0** | the `onSubmit` blank guard |
| `useVenueEngagements`'s `venueId === null` branch | 20 | **0** | `VenueDesk` is only rendered once a venue is chosen |
| `ClaimPanel`'s `claiming` check in `submit()` | 24a | **0** | the submit button's `disabled` attribute |

The commit message records the first of these and acts on it: a **third** copy of the same guard
in `OfferForm`'s `onSubmit` was removed, on the reasoning that *"a guard behind two others is one
no mutation can reach"*. The other three were not measured at the time and are recorded here.

**None is removed, and the reasoning differs per row.** For rows 19 and 24a the two guards answer
different questions — the attribute is what a user sees, the hook is what it promises a caller —
and the cost of the race is a second live claim code that nothing can ever show again. For row
18a the pair is what makes row 45 fail at all, so removing either half would leave the *other*
unreachable instead. Row 20 is different in kind: `useVenueEngagements`'s null branch is
unreachable from the only caller there is, because the caller is conditionally rendered. It is
kept because the hook's signature admits `null` and a future caller that renders the desk
unconditionally would need it — but **it is not covered, and no test in this suite would notice
if it broke.**

**What this says about the four rows above:** rows 38, 44, 45 and 57 in the matrix are load-bearing
at the tier the mutation record names — the attribute, or the pair — and not at the tier a reader
might assume from the moduledoc. That gap is the thing worth carrying forward.

## Implementation constraints

- **Client only.** No Elixir file, no migration, no route, no `config/`. `mix` is not run.
- **No new endpoint.** All three employer routes and the claim route are U1's and U2's, already
  merged.
- **The test filenames must not collide.** `docs/solutions/test-failures/a-test-file-the-typechecker-cannot-see.md`:
  a `*.test.tsx` whose basename matches an existing `*.test.ts` is invisible to `tsc` and eslint
  while vitest runs it green, and a 62-test suite escaped both for a whole unit that way. The
  plan asks for `employer.test.tsx` and `claim.test.tsx` **beside `employer.ts` and `claim.ts`** —
  which is that collision exactly. Named `employer-route.test.tsx` and `claim-panel.test.tsx`
  instead, and verified with `npx tsc --noEmit --listFiles`.
- **No clock arithmetic anywhere on this surface.** `HospitalityComs.Clock` is offsettable and
  U11's demo controls move it; this browser's clock is real. Every instant is *rendered* and never
  compared, which is the rule `ShiftRoomListing.closesAt` already carries.
- **Every decoder builds its object field by field.** No spread of the payload, no
  `Object.assign`.
- **`errors.ts` is untouched.** `KNOWN_ERROR_CODES` does not cover this surface and does not need
  to.
- **No fixture spells a formatted instant.** Every expected string is read back out of the
  renderer that produced it, because each resolves the runner's timezone.
- **R20: a claim code never reaches a log.** Nothing on this surface logs, and the code is held in
  component state alone.
- `npm run verify` — typecheck, lint, format check, test, build — and identically under
  `NODE_OPTIONS="--localstorage-file=…"`.

## Quality scores, self-assessed

| Dimension | Score | Note |
|---|---|---|
| Coverage of the stated scope | 5/5 | one verb with both its success shapes, two decoders with their key sets pinned from both directions, two surfaces end to end, and R6 asserted as *carried* rather than matched |
| Control discipline | 5/5 | the four assertions most likely to be vacuous — the `204` pair, the redacted key set, the dismissed code, the rendered sentence — each carry a control that fails when they do, and three of the four are measured as failing to *different* mutations |
| Regression protection | 4/5 | one disclosed regression, proved by rooms files *not* changing plus a mutation that kills a body in one of them. The `home-route` tab strip is proved by a design choice rather than a new assertion |
| Falsifiability | 5/5 | every row names a mechanism, 24 of 28 mutations killed the test they were aimed at, and the four that did not are enumerated rather than glossed |
| Risk of a vacuous pass | 3/5 | **the residue is real and named.** Row 38's stated mechanism is unreachable; rows 44, 45 and 57 hold at the attribute rather than at the guard the moduledoc credits; and mutation 10 kills eighteen bodies because the fake 404s an unknown path, so the path assertion in row 35 is over-determined by its environment |
| Honesty of the artifact | — | this brief did not run as a gate, and the section at the top says so rather than the score |

## Mutation record

**Twenty-eight mutations, measured for this brief** against the tree as shipped, each applied to a
clean checkout, run against the narrowest test files that could answer, and reverted. Baseline
before and after: **439 passed / 15 skipped**.

These are not the implementation run's twenty-five. That run reported 24 kills and one survivor
in `2512c54`'s message, and the survivor is reproduced below as row 19; the individual list was
not written down at the time, so this set was designed fresh from the shipped code rather than
recalled. **Where the two disagree, this table is the measured one.**

| # | Mutation | Tests killed |
|---|----------|--------------|
| 1 | `write` is read-shaped: the body is always read and decoded | 1 |
| 2 | any status under 300 counts as success, rather than the one named | 2 |
| 3 | `write` hard-codes `POST` rather than sending the method it was given | 1 |
| 4 | `write` sends no bearer token | 1 |
| 5 | a decoder answering `null` is passed through as the value | 3 (one of them `redeemMagicLink`'s, from U2) |
| 6 | `createFakeApi`'s `write` succeeds by default instead of failing | 1 |
| 7 | `decodeVenueEngagement` spreads the payload instead of naming its fields | 2 |
| 8 | `decodeIssuedOffer` defaults a missing `claim_code` to the empty string | 1 |
| 9 | `decodeClaimedEngagement` reads `accepted_at` off `starts_at` | 3 |
| 10 | the picker reads `/api/venue-rooms` rather than `/api/employer/venues` | **18** — see below |
| 11 | the offer body carries a term this client computed | 1 |
| 12 | `employerFailureMessage` renders local copy instead of the envelope's sentence | 4 |
| 13 | `claimFailureMessage` renders the envelope for `unauthorized` too | 1 |
| 14 | `fieldProblems` answers nothing, so a `422`'s per-field messages are dropped | 1 |
| 15 | `dismiss` clears the problem but not the code | 1 |
| 16 | the venue desk is not keyed on the venue, so switching re-renders | 1 |
| 17 | the offer submit loses its `disabled` in-flight attribute | 1 |
| 18a | the offer submit loses its `disabled` blank-role attribute, alone | **0** |
| 18b | …and the form's own blank-role guard goes with it | 1 |
| 19 | `useOfferDesk` loses its in-flight guard, the attribute left in place | **0** |
| 20 | `useVenueEngagements` asks before a venue is chosen | **0** |
| 21 | a failed list renders the empty-list sentence rather than the failure | 1 |
| 22 | `useFetched`'s `reload` does not bump the attempt, so it re-renders only | 2 (one of them `room-lists.test.tsx`'s) |
| 23 | the claim panel's blank guard warns and sends anyway | 2 |
| 24a | the claim panel loses its in-flight guard, the attribute left in place | **0** |
| 24b | …and the submit's `disabled` attribute goes with it | 1 |
| 25 | a refusal clears the code the worker typed | 1 |
| 26 | the claim panel writes the term's start where acceptance belongs | 1 |

**Mutation 10 is the one worth reading twice, and not because it is strong.** Pointing the picker
at `/api/venue-rooms` kills eighteen bodies — every test in `employer-route.test.tsx` — because
`readsFrom` answers an unstubbed path with a `404` and the whole surface collapses. Only the first
of the eighteen is *about* the path. So the assertion in row 35 is real but its kill count is an
artifact of the fake's strictness, and a reader taking "18" as a measure of that row's strength
would be misreading it. This is the inverse of the four zero-kills above: there, a mechanism is
weaker than the moduledoc suggests; here, a number is stronger than the property it stands for.

**Mutations 5 and 22 each kill a body outside this unit** — U2's `redeemMagicLink` decoder test
and U12's rooms list test. That is the regression evidence for two shared mechanisms this unit
either reused (`expectBody`'s null guard) or moved (`useFetched`), and it is why row 63's
"unchanged file" claim is not vacuous.

Two things are deliberately **not** asserted. Nothing asserts the *absence* of a field on a form —
only that a body naming one is not sent — because a test for the absence of a thing passes for
ever whether or not anything prevents it. And nothing pins `KNOWN_ERROR_CODES`' contents; the rule
is that `errors.ts` does not change, which a diff shows.

## Revisions made after review

Greptile left two findings on PR #61 and both were valid. The first is this file, and the block
at the top is the response to it. The second is below.

**Finding 2 — the cross-feature import was due in this unit and was deferred.** `termLabel` and
`instantLabel` were imported from `features/rooms/room.ts` into `employer-route.tsx`,
`claim-panel.tsx` and `employer.ts`. `room.ts`'s own moduledoc named the condition for moving
them — *"the move belongs to whichever unit adds the caller after U4's two"* — and U4 added both
callers, so by the rule the code itself states the move was owed here. Decision 5 above records
it as debt; this records paying it.

**Where it landed and why there.** `src/app/instant.ts`, beside `failure-message.ts` and
`use-fetched.ts` — the two other things every surface shares and no surface owns. Not
`src/api/`, because nothing there may know how anything is displayed, and the whole argument for
client-side formatting is that display is where the timezone question gets its only honest
answer. Not a directory of its own, which `src/socket/topic-id.ts`'s precedent argues against:
that file sits in `src/socket/` because a topic suffix is the only thing it is for, not in a
`shared/` bucket.

**`room.ts` re-exports both under the same names, so no rooms file changed** — production or
test. That is `use-room-lists.ts`'s manoeuvre for `Loaded`, made in this same unit. The
alternative was updating `rooms-route.tsx`, `room-view.tsx`, `room-lists.test.tsx` and
`room.test.ts`, the last of which destructures `instantLabel` off a dynamically re-imported
`./room` inside its timezone helper — so updating it would have meant editing the one test whose
meaning is hardest to preserve, for no gain. The re-export is documented as a shim rather than a
second home.

**The formatting behaviour is unchanged, and it is measured rather than asserted.**

| Check | Result |
|---|---|
| `npm run verify` | 439 passed / 15 skipped, unchanged |
| Whole suite under `TZ=UTC` | 439 / 15 |
| Whole suite under `TZ=Pacific/Kiritimati` | 439 / 15 |
| All 28 mutations above, re-run after the move | **identical counts, mutation for mutation** |

Three further mutations against the hoisted module, each run under both timezones:

| # | Mutation | Killed |
|---|----------|--------|
| A | the day comparison is made in UTC (ISO date halves) rather than the reader's zone | 1 under each TZ — *"asks which day in the timezone it renders in, so one term reads two ways"* |
| B | `CALENDAR_DAY` names `timeZone: "UTC"` | 1 under each TZ, the same body |
| C | the three formatters are built per call rather than at module load | **0 under each TZ** |

A and B are the check the move was at risk of losing, and it survived: the matrix still catches a
UTC comparison from either direction, in both zones.

**C is a finding and the moduledoc was corrected for it.** The hoisted module first claimed the
tests depend on the module-load construction. They do not: `inTimeZone` leaves `process.env.TZ`
set for the duration of its callback, so formatters built lazily inside the functions resolve the
same zone and the matrix stays green. Building once is a performance property held by a paragraph
and by nothing else, and `instant.ts` now says that rather than the stronger thing. It is the
fifth guard in this unit that no mutation reaches — the four in the section above, and this.

**No test's meaning changed.** Two test files had one import line rewritten each
(`employer-route.test.tsx`, `claim-panel.test.tsx`, both from `../rooms/room` to
`../../app/instant`); no assertion, fixture or body was touched, and the mutation table is what
proves it rather than the diff.

## What is not verified

**Two real browser windows.** R19 asks for the surface to be reachable in a browser without a
console, from log-in to a rostered shift, and that needs `mix phx.server` and the Postgres cluster
another agent held while this was built. Everything above is jsdom against a fake transport.
