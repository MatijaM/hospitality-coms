# Test Design Brief — #73, the client half: names where the peer surface showed a uuid, and a picker for the audience

Issue: #73, "feat: names instead of uuids across the person-facing UI". Its server half merged as
**#76** and its first independent client half as **#74**. This brief covers **the remainder, and it
is entirely under `client/`**: render the names #76 now sends, and replace the disclosure audience's
raw-uuid box with a picker over the event #76 added. **No Elixir file and nothing under `test/` is
edited by this unit.**

Gate: `AGENTS.md`, "Pre-Implementation Test Design Gate", **and its new subsection "The gate applies
to `client/`, and this is what it has to ask there"** — added this morning, after #68, #72 and #74
each shipped without an artifact (issue #62). This is the first change the subsection applies to, so
its five prompts are answered in a section of their own below rather than left implicit in the
matrix. Committed alone, first, ahead of every line of production code, so the ordering is visible
in `git log` rather than asserted. Nearest precedents read before writing:
`docs/test-designs/2026-07-30-73-peer-display-names.md` (this issue's server half) and
`docs/test-designs/2026-07-30-70-profile-channel.md`.

**Approver: the orchestrating agent, in the human's place.** Nobody read this before implementation
began. Recorded here because `AGENTS.md` requires the substitution to be visible in the artifact
rather than inferred from the absence of a review.

## What is being built

Two things. They share no code and they share one defect class: a rendered uuid where a name is
available, and a decoder that would rather accept `undefined` than say so.

**Part A — six render sites and three decoders.** #76 put `peer_display_name`,
`requester_display_name`, `addressee_display_name` and `author_display_name` on
`HospitalityComsWeb.PeerChannel`'s four rendered shapes. The decoders in
`client/src/features/peers/decode.ts` **ignore unknown keys**, so every one of those names reaches
this client today and is dropped on the floor. Six places render `shortId(...)` of a person with no
name beside it: the incoming request's requester (three of them — the heading and both answer
buttons), the outgoing request's addressee, the conversation list, the conversation heading, and the
message author.

**Part B — the audience picker.** `DisclosureControl` in
`client/src/features/profile/profile-route.tsx` makes the worker type a raw uuid for an audience
that is a venue **or** a person, and its docstring explains at length that there was no alternative:
*"a gap in what U9 puts on a wire … `Peers.list_visible_peers/1` is the nearest thing and it lives on
another channel."* #76 closed that gap with `list_audiences`, so the docstring is now a file
explaining the absence of something it has. The control becomes a picker; the docstring is rewritten;
`README.md`'s two passages saying the same thing are corrected.

Both wire shapes below were read out of `lib/hospitality_coms_web/channels/peer_channel.ex` and
`profile_channel.ex` on `main` at `678c7d1`, not from the brief that commissioned this work:

```
rendered_conversation  %{connection_id, peer_id, peer_display_name, connected_at,
                         disconnected_at, disconnected_by_id, open}
rendered_request       %{request_id, requester_id, requester_display_name,
                         addressee_id, addressee_display_name, state,
                         requested_at, accepted_at, declined_at}
rendered_message       %{message_id, connection_id, author_id,
                         author_display_name, body, sent_at}
list_audiences   %{} -> %{venues: [%{venue_id, name}], people: [%{person_id, display_name}]}
```

Nothing is persisted by either part. No `localStorage` key is added, renamed or narrowed — see the
fourth client prompt below, where that is the answer rather than an omission.

## Decision 1 — the short id stays beside every name, buttons included

`peers-route.tsx:254` already renders the visible-peers list as `{peer.displayName} · {shortId(...)}`
and `CLAUDE.md` gives the reason: display-name collisions are **deliberate**, because a globally
unique readable name would be a second `person_id` in plain text readable by every worker. The id is
what tells two people with one name apart. So every site in Part A becomes `name · shortId`, and the
existing `room-view.tsx` render — `name · role · shortId` — is **not touched**, per the constraint in
the commissioning brief and the 7 kills recorded against dropping its id.

**The two answer buttons take the id too, and that is a departure from the one existing precedent.**
`peers-route.tsx:267` renders a button as `Open conversation with {peer.displayName}` — name alone.
Applied to the incoming list that is an accessibility defect rather than a style choice: two
outstanding requests from two people who happen to share a name produce two buttons whose accessible
names are identical, and a screen-reader user choosing between them has nothing to choose on. It also
makes `getByRole("button", { name })` ambiguous, which is the failure mode announcing itself. The
existing precedent is left alone because that list is keyed `personId@venueId` and shows one entry
per venue; it is not made consistent, because consistency here would mean copying the weaker of the
two.

## Decision 2 — the decoders **require** the names, and the alternative is what #66's client half did

Each new key becomes a `typeof payload.x !== "string"` refusal in `decode.ts`, exactly as
`decodeRoomMessage` requires `author_display_name` (#66) and `author_role_label` (#65). The
alternative — `payload.peer_display_name ?? ""`, or typing the field `string | undefined` — is the
thing this tree keeps calling a named absence versus `undefined` arriving in a heading. There is no
message, request or conversation the server can now produce without a name: every render heads on
`is_binary(name)` and would crash rather than ship a `null`, and the joins carry **no activeness
predicate and no `erased_at` filter**, so an erased counterpart reads
`Lifecycle.erased_display_name/0` (`"Former colleague"`) rather than nothing. A fallback would
therefore only ever mask a server that had drifted.

## Decision 3 — the kind selector is deleted, because the kind is a property of the audience

The control has two inputs today: a `<select>` for `venue`/`person` and a text `<input>` for the id.
With `{venues, people}` in hand the kind is no longer something a worker chooses — it is a fact about
whichever row they picked, and offering it separately invites the one state the server refuses
(`bad_request`: an audience that is a person id tagged `venue`). So it becomes **one** `<select>`
with two `<optgroup>`s, "Employers" and "Peers", each option's value encoding the tagged union as
`venue:<id>` / `person:<id>` and parsed back to both halves at the point of use.

That encoding is the tagged union surviving a DOM round trip, and it is the same argument
`contract.ts` already makes for why the wire carries `audience_kind` + `audience_id` rather than two
nullable columns: **the split done twice is the defect**. There is one parser and one place the
string becomes a pair.

**Consequence, warned rather than applied silently** (`AGENTS.md`, Regression and Functionality
Preservation Gate): the free-text audience box is **removed**. A worker can no longer name an
audience that is not on either list. That is the requested change and it is a real narrowing — the
audience an ended venue represents is unreachable until the worker works there again, which is
exactly the residue #76 recorded on the server side ("a venue whose term has ended is not offered,
because it cannot read the record either; a decision already taken about it stays in the ledger and
applies again if the worker returns"). The remedy is that the standing decision is not lost, only
un-retakeable, and the ledger keeps rendering it — see Decision 5.

## Decision 4 — `audiences` is `null` until answered, and that is the whole of gate prompt one

This is the sharpest thing in the unit and it is the defect `AGENTS.md` names first.

The picker has at least four render states — idle, in flight, refused, ready — and two of them
render identically to a fifth: **ready and empty**. A worker with no active engagement and no
reachable peer gets `{venues: [], people: []}`, and the honest thing to render is "there is nobody to
name yet". A worker whose read has not come back yet gets the *same* empty arrays if the state is
initialised to them — and telling somebody there is nobody they can name, because a round trip is
half a second old, is #68's venue link exactly: right until the network is slow, and wrong in the
direction that takes the control away.

So the hook holds `Audiences | null`, `null` meaning **not answered** (idle, in flight, or refused),
and the control renders three distinguishable things:

| State | Renders |
|---|---|
| `null` | a sentence saying the list is still loading, and **no claim about emptiness** |
| both lists empty | "There is nobody to name yet", and no `<select>` |
| anything present | the `<select>` |

A refusal additionally raises the surface's existing `notice`, through `report("audiences", …)`,
which is the mechanism `loadOwn` and `loadDisclosures` already use. The test for this **holds the
read open by hand** and asserts the emptiness sentence is absent, then releases it with empty lists
and asserts the sentence arrives — which is the only shape that can tell the two apart, because a
test that renders and asserts sees whichever one the scheduler happened to leave on screen.

## Decision 5 — a ledger row whose audience has left both lists renders its short id and says so

`EntryAudiences` renders `shortId(decision.audienceId)` for every past decision. With `audiences` in
hand most of those resolve to a name, and **some cannot**: `list_audiences` offers venues where the
worker holds an engagement *active at the instant* and people who are visible-or-connected *now*,
while the ledger is permanent. A decision about last year's employer is still in force and is
unnameable.

So the resolution is `audienceName(audiences, kind, id) -> string | null`, and:

- resolved → `{name} · {shortId(id)}`, the same shape as everywhere else in this unit;
- unresolved → `{shortId(id)}` alone, **plus a sibling sentence** saying the decision still applies
  and the audience is not one the worker can currently name.

It is **never an empty string**, which is the failure mode the commissioning brief asked to be named
explicitly: `{audiences && name} · {shortId(id)}` renders `" · 4a3f1b2c"` with a leading separator
and reads as a rendering bug rather than as a fact, and `{name ?? ""}` renders the separator with
nothing in front of it. Both are one character away from the correct version and neither is visible
to a test that only asserts the short id is present — hence the mutation row for it.

## Acceptance criteria

1. `decodeConversation` refuses a payload with no `peer_display_name`, and carries it as
   `peerDisplayName` when present.
2. `decodePeerRequest` refuses a payload missing either `requester_display_name` or
   `addressee_display_name`, and carries them as `requesterDisplayName` / `addresseeDisplayName`
   **on the correct sides**.
3. `decodePeerMessage` refuses a payload with no `author_display_name`, and carries it as
   `authorDisplayName`.
4. An incoming request renders the requester's name beside their short id, in the heading and in
   both answer buttons.
5. An outgoing request renders the addressee's name beside their short id, and **not the
   requester's** — the requester is the reader.
6. The conversation list renders the counterpart's name beside their short id.
7. The conversation heading renders the counterpart's name beside their short id.
8. A message by somebody else renders the author's name beside their short id; a message by this
   person still renders `"You"` and no name.
9. The profile surface asks `list_audiences` on join, alongside `profile` and `list_disclosures`,
   and asks it exactly once.
10. `decodeAudiences` refuses a reply whose venues are missing `venue_id` or `name`, or whose people
    are missing `person_id` or `display_name`; one bad row refuses the whole list.
11. The disclosure control offers every venue and every person `list_audiences` returned, grouped,
    and offers no free-text id field.
12. Choosing a venue sends `audience_kind: "venue"` with that venue's id; choosing a person sends
    `audience_kind: "person"` with that person's id.
13. Before `list_audiences` is answered the control claims nothing about emptiness; after it is
    answered with two empty lists it says there is nobody to name.
14. A ledger row whose audience is on a list renders that audience's name beside the short id; one
    whose audience is on neither renders the short id and a sentence, and never an empty name.
15. Nothing under `features/employer/` gains a display name, and no client surface renders an email
    address for a peer.

## Edge cases

- **An erased counterpart.** Renders `"Former colleague"`, which arrives as an ordinary string —
  there is no client-side special case and there must not be one, because the constant is the
  server's and a copy here would be a second spelling of it.
- **A name that collides.** Two peers called "Captain Nemo" are distinguished by the short id, which
  is why it stays. Asserted for the two answer buttons, where collision is an accessibility failure
  rather than a cosmetic one.
- **A closed conversation.** Still listed (KTD21 deletes nothing) and still carries the name — the
  join has no activeness predicate, so a conversation whose counterpart's every engagement ended
  reads the same as an open one.
- **A lapsed request.** Same: the row is in its requester's list precisely so they can make sense of
  it, and a name that lapsed with visibility would blank the one row that needs reading.
- **An audience list with venues but no people, or people but no venues.** One `<optgroup>` renders
  and the other does not; the control is offered rather than suppressed. Both halves are separately
  mutated below because a picker built from only one of the two is a picker that works for every
  fixture that carries both.
- **A `list_audiences` refusal.** The control stays in its `null` state, the notice renders, and the
  worker is told; it does not fall back to a text box, because a fallback path used once a year is a
  path nothing tests.
- **An audience chosen, then the list re-read and the chosen row gone.** The `<select>` value no
  longer matches an option; the control returns to no-selection and both buttons disable, which is
  the same guard the empty-string check gave the text box.

## Regression risks, by path

- `client/src/features/peers/decode.test.ts` — every fixture for the three decoders gains a key.
  Existing "answers null for anything missing a field" loops enumerate the complete shape, so they
  cover the new keys automatically **only if the complete fixture is updated**; if it is not, the
  loop passes while testing one key fewer, which is a silent weakening.
- `client/src/features/peers/peers.test.tsx` — `conversationWire`, `requestWire`, `incomingWire`,
  `messageWire` and `mineWire` all need the new keys or every surface test in the file starts
  rendering a decode failure. This is the file most likely to fail loudly and misleadingly.
- `client/src/features/peers/peers.integration.test.ts` — skips itself without a live server; it
  pushes and asserts refusals rather than shapes, so it is not expected to move. Checked, not assumed.
- `client/src/features/profile/profile-route.test.tsx` — `READS` grows by one, so `serverFor` must
  answer `list_audiences`, and **every** existing test that calls `openProfile` goes through it. The
  `decide()` helper types into a text field that will no longer exist. The test
  *"leaves the disclosure control's own id field alone"* asserts exactly one element labelled
  `/^their id/i` — the field it guards is being replaced, so that assertion must be re-pointed at the
  picker rather than deleted: what it exists to catch (a future cut taking the disclosure control
  with the peer-lookup control) is unchanged.
- `client/src/features/profile/decode.test.ts` — gains a decoder; nothing existing moves.
- `client/README.md` — two passages assert there is no picker and no event enumerating an audience.
  Both become false. Prose, not shapes: `contract.ts`'s **shapes** are the specification and an edit
  to one is the tell that the channel diverged, while an edit to a sentence that has stopped being
  true is maintenance. `contract.ts`'s banner also says the channel answers seven events.

## Test matrix

`Fails without` names the mechanism whose removal or inversion makes that row fail. Every row was
chosen so that the named mutation is applicable — a row I could not mutate is a row that certifies
nothing (`docs/solutions/test-failures/tests-that-certify-nothing.md`).

### Module level — `features/peers/decode.test.ts`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| A1 | conversation payload with `peer_display_name` | `peerDisplayName` carries it | the field's assignment in `decodeConversation` |
| A2 | conversation payload without it | `null` | the `typeof payload.peer_display_name !== "string"` refusal |
| A3 | request payload with both names | `requesterDisplayName` and `addresseeDisplayName` land on **their own** sides, asserted against two different literals | the two assignments being distinct rather than swapped |
| A4 | request payload missing either name (loop over the complete shape) | `null` for each | either refusal |
| A5 | message payload with `author_display_name` | `authorDisplayName` carries it | the assignment |
| A6 | message payload without it | `null` | the refusal |

A3's two literals are deliberately unequal and neither is the other's substring: a fixture naming
both parties "Captain Nemo" cannot distinguish a swap, which is gate prompt three.

### Module level — `features/profile/decode.test.ts`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| B1 | a full `list_audiences` reply | both lists decode; venues carry `venueId`/`name`, people carry `personId`/`displayName` | the wire keys being the snake_case ones the channel sends |
| B2 | a venue row missing `name`, and a person row missing `display_name` | `null` for the **whole** reply, not a shorter list | `decodeList`'s all-or-nothing rule reaching this decoder |
| B3 | `{venues: []}` with no `people` key | `null` | the `people` half being required rather than defaulted to `[]` |

B3 is the row that catches the picker being built against a one-sided reply.

### Surface — `features/peers/peers.test.tsx`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| C1 | an incoming request | the heading, the Accept button and the Decline button each carry the requester's name **and** their short id | the name in each of the three renders (three separate mutations) |
| C2 | two incoming requests from two people with the **same** name | the two Accept buttons are distinguishable | the short id in the button render |
| C3 | an outgoing request | the addressee's name renders and the requester's does **not** | the render reading `addresseeDisplayName` rather than `requesterDisplayName` |
| C4 | the conversation list | the counterpart's name beside the short id | the name in that render |
| C5 | an open conversation | the heading carries the counterpart's name beside the short id | the name in the heading render |
| C6 | a history of two messages, one by each party | the counterpart's message shows `name · shortId`; this person's shows `"You"` and neither their name nor their id | the author render's name, and its `=== ownPersonId` branch |
| C7 | an erased counterpart (`"Former colleague"`) | renders verbatim in the conversation heading | nothing client-side — this is a **control** proving no special case exists (see Controls) |

### Surface — `features/profile/profile-route.test.tsx`

| # | Scenario | Asserts | Fails without |
|---|---|---|---|
| D1 | join | the pushed events are exactly `profile`, `list_disclosures`, `list_audiences`, once each | `list_audiences` in the join effect |
| D2 | audiences answered with one venue and one person | both appear as options, under their own group labels | the venue half / the people half of the render (two mutations) |
| D3 | picking a **venue** and pressing Hide | the pushed payload is `audience_kind: "venue"` with that venue's id | the parser taking the kind from the option rather than a constant |
| D4 | picking a **person** and pressing Hide | the pushed payload is `audience_kind: "person"` with that person's id | the same, in the direction a `"venue"` constant survives D3 |
| D5 | the read **held open** | no emptiness sentence on screen, and the surface is demonstrably up | `audiences` being `null` rather than `{[], []}` before the answer |
| D6 | released with `{venues: [], people: []}` | the emptiness sentence arrives; no `<select>` | the empty branch |
| D7 | a ledger row whose audience is in the list | the audience's **name** renders beside the short id | the resolution against `audiences` |
| D8 | a ledger row whose audience is in neither list | the short id renders, a sentence explains it, and the rendered text contains no `" · "` orphaned separator and no empty name | the `null` branch of `audienceName` being handled rather than interpolated |
| D9 | one entry's control | exactly one audience control, scoped-named to that entry; no field labelled `/^their id/i` | the label scoping (this is the re-pointed guard, see Regression risks) |

D3 and D4 are one mutation apart and neither alone is sufficient: a picker hard-coding `"venue"`
passes D3, and a picker hard-coding `"person"` passes D4.

## Controls, listed explicitly

Every absence assertion below has a positive assertion in the same test proving the surface rendered.
`AGENTS.md`'s second client prompt makes this mandatory rather than stylish, because on a client
surface "rendered nothing" is the default failure of a broken mount.

1. **C3** — asserting the requester's name is absent from the outgoing row passes against a row that
   rendered nothing. Control: the addressee's name and the request's state are asserted present in
   the same row first.
2. **C6** — asserting this person's own name is absent passes against an empty message list. Control:
   the body of both messages and the counterpart's name are asserted present first.
3. **C7 is itself a control**, and it controls something no other row can: that the client has **no
   special case** for an erased counterpart. It passes trivially against a correct implementation,
   and fails against one that added an `if (name === "Former colleague")` branch, or a decoder
   filtering the constant. Recorded as a control rather than as coverage so it is not read as more
   than it is.
4. **D5** — "no emptiness sentence" passes against a profile that failed to mount. Control: an
   attested entry's role label and the entry's own disclosure heading are asserted present while the
   read is still held open.
5. **D6** — "no `<select>`" passes for the same reason. Control: the emptiness sentence is asserted
   present in the same test, so the control is offered and empty rather than missing.
6. **D9** — "no field labelled `/^their id/i`" passes against an unmounted control. Control: the
   picker is found by its own scoped label in the same test, and asserted to be exactly one.
7. **D8** — the "no orphaned separator" assertion is a string test that passes against an empty DOM.
   Control: the short id and the explanatory sentence are asserted present first.
8. **A3's two unequal literals** are the control on the swap: with one literal for both parties the
   assertion is invariant under the mutation it exists to catch.
9. **C2's colliding names** are the control on the short id in a button: with two distinct names the
   buttons are distinguishable whether or not the id is rendered.
10. **The whole-suite count** is the standing control on the fixture updates: 535 passing before,
    and any drop means a shape changed underneath a test rather than beside it.

## The five client prompts, answered

`AGENTS.md`, "The gate applies to `client/`". Each is answered against this change rather than in
general.

**Which render state is being claimed?** Decision 4, and it is the reason that decision exists. The
picker's dangerous pair is *in flight* and *answered with nothing*, which render identically unless
the state distinguishes them. D5 holds the read open by hand and D6 releases it; neither could be
written as a render-and-assert. Part A has no equivalent — a name arrives with the row it names, so
there is no state in which the row is present and the name is pending.

**What proves the fixture could have failed?** Ten controls, above. The three that matter most are
D5, D6 and D9, all of which assert an absence on a surface that has to be shown to exist first.

**Can the fixture distinguish the two things being compared?** Two places it could not, and both are
fixed in the fixture rather than in the assertion. A3's requester and addressee take **different**
literals, because #74's own defect was a fixture where the two values under comparison coincided.
C2's two peers take the **same** name deliberately, so the short id is the only thing that can
distinguish the buttons.

**Does the persisted shape change?** **No, and this is the answer rather than an omission.**
`features/peers/peer.ts`'s header records that the peer surface holds no store, no `localStorage`
key and nothing to clear at log-out, because three channel events enumerate everything it renders.
The profile surface persists nothing either. So no decoder in this unit reads a byte an earlier build
wrote, and #72's failure mode — a required field added to a stored shape, silently emptying every
existing user's list on deploy — is structurally unreachable here. The room store is not touched.

**Would a fake transport see this at all?** Partly, and the split is what decides where each
assertion goes.

- The **snake_case wire keys** are invisible to a surface test, because the fixture and the decoder
  are both written by me and agree with each other whatever they say. That is #66's client half
  exactly — `{displayName}` where the server reads `display_name`, killing nothing. So every key is
  asserted at **module level** against a literal (A1–A6, B1–B3), and the surface fixtures are built
  from the same snake_case shape rather than from the camelCase type.
- The **outbound payload** is different and is genuinely visible at the surface: `FakeChannel`
  records what was pushed verbatim rather than interpreting it, so `pushesOf(channel,
  setDisclosure)` compares the literal `{engagement_id, audience_kind, audience_id, disclosed}` map.
  D3 and D4 therefore belong where they are, and are as strong there as they would be lower down.
- What **no** client test can check is that `"list_audiences"` is the event name the server dispatches
  on, or that its reply keys are the ones `ProfileChannel` writes. That is `profile_channel_test.exs`'s
  and it already exists; this brief records the boundary rather than pretending to cover it.

## Implementation constraints

- **Nothing employer-facing gains a name.** `employer_role` holds no privilege on `people` —
  `boundary_test.exs` asserts it at table *and* column level — so an employer session cannot be shown
  one. A display name appearing anywhere under `features/employer/` is a zone-boundary violation, not
  a feature.
- **No email address reaches any client surface.** `peers_test.exs` asserts the peer list discloses
  none, by value and by key name. Nothing here adds a field to a peer shape other than a name.
- **`features/rooms/room-view.tsx` is not touched.** `name · role · shortId` is settled; all three
  values are load-bearing and dropping the id kills 7.
- **`contract.ts` stays the specification.** Its shapes are what a transport must satisfy; only its
  prose changes, plus the eighth event, which the channel already answers.
- Decoders answer `null`, never a partial value and never a throw — the posture of all four decode
  files.
- Every instant stays a string. Nothing in this unit computes with time.
- `npm run verify` — typecheck, lint, format check, vitest, build — must be clean.

## Quality scores, self-assessed

| Dimension | Score | Why |
|---|---|---|
| Coverage of the acceptance criteria | 5/5 | Fifteen criteria, each with at least one row; every row has a named mutation. |
| Strength against vacuous passes | 4/5 | Ten controls, two fixtures designed against the specific coincidence that would hide the defect. Held back from 5 because D2's two halves are asserted in one test rather than two. |
| Level-appropriateness | 5/5 | Wire keys at module level, outbound payload at surface level, and the boundary of what a fake transport can see written down rather than assumed. |
| Regression protection | 4/5 | Every at-risk file named by path with the specific way it breaks. Held back from 5 because `peers.integration.test.ts` cannot be run here — no server — so its non-involvement is inspected rather than measured. |
| Honesty about what is not covered | 5/5 | The event name and the reply keys are the server's to prove; the removed free-text audience is recorded as a narrowing rather than described as a fix. |
