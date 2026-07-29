---
date: 2026-07-29
topic: crude-employer-view
---

# A crude employer view, and the handshake it declines to hide

## Summary

An employer-facing surface — deliberately unstyled, fields and buttons — that lets a venue
manager do three things they can currently do only from an Elixir console: bring a person onto
the venue, create a shift, and put a person on that shift.

The domain is finished. Every context function these three flows need already exists, already
takes an `EmployerScope`, and already refuses correctly. What is missing is transport and a
page: `HospitalityComsWeb.EmployerVenueChannel` handles `join/3` and answers every event
`bad_request`, and `lib/hospitality_coms_web/router.ex` declares no employer route at all.

The one product decision is that this surface **shows the two-party handshake rather than
hiding it**. The employer issues an offer and receives a claim code; the worker claims it under
their own account. That is not a limitation being tolerated — it is the POC's central claim
made visible, and the crude version is the version where the audience watches the code change
hands.

---

## Problem Frame

The project's thesis is that the employer holds a lease rather than an account. Twelve units
built the mechanism for it: a person record nobody but the person creates, a two-zone Postgres
boundary, engagements derived from time, rooms with no membership table.

The demo shows the worker's half. `client/src/features/rooms/`, `features/peers/` and
`features/profile/` are real surfaces a person can drive in a browser. The employer's half is
asserted — in tests, in `CLAUDE.md`, and in a channel that carries no events. So the sentence
"an employer can bring somebody onto the venue without ever creating their account" is, to an
audience, a claim about code they cannot see.

That gap is the whole problem. It is not a missing capability; it is a missing window onto a
capability that already works.

### Why the honest version, and what the dishonest one would have cost

A surface that took an email address and "added a person" would be a lie about the schema, not
a simplification of it. `invitations` has **no email column, no phone column and no
`person_id`**. `HospitalityComs.Engagements.issue_invitation/2` says so in its own doc: *"No
contact identifier is stored and no person row is created. An unclaimed invitation names nobody
and grants nothing."* There is no employer-side path that writes a `people` row, and building
one would invert KTD1 through KTD3 in a single form.

So the choice was never "handshake or no handshake". It was "show the handshake, or fake a
form and explain afterwards that it does something else". The first is roughly 8–12 hours and
demonstrates the product. The second is faster and demonstrates nothing.

---

## Key Decisions

**D1. The handshake is the feature.** The employer issues an invitation and receives a claim
code, in plaintext, exactly once. Delivery is out of band by design — the system holds no
address to send it to. The worker pastes it into their own session. Two browser windows, and
the audience watches the boundary hold.

**D2. The employer never learns a name or an address, and the interface says so instead of
papering over it.** `people` carries exactly one identifying column, `email`, and
`employer_role` holds no privilege on it — `boundary_test.exs` sweeps table *and* column
grants. **There is no person-name column anywhere in the schema.** A worker therefore renders
as a role label, a term, and an engagement id: "Runner — 29 Jul to 27 Oct". The mitigation is
that the seed already gives every demo person a distinct role label, so the list reads as
people rather than as rows.

**D3. Every id the employer names is venue-local.** Rostering names an `engagement_id`, which
is venue-local by construction (KTD15b). No employer-facing payload carries `person_id`. This
is U9's precedent applied to a new surface: the employer-visible views expose no `person_id`
either, and their column lists are pinned in `test/hospitality_coms/boundary_test.exs`.

**D4. The claim code is shown once and is unrecoverable afterwards.** The row stores only a
SHA-256 digest. If the page loses it before the manager copies it, the only remedy is a second
invitation. The interface must make that obvious at the moment it matters, not in a footnote.

**D5. Refusals are flat, and the copy is written for flatness rather than fighting it.** A
wrong venue, a revoked grant, an engagement that has ended, and an id naming nothing all answer
`:no_grant` or `:not_found` identically, on purpose (AE1, not-found-rather-than-forbidden). The
interface cannot explain which happened because the server does not know it should. One
sentence covers all of them.

**D6. Every date the crude form needs has a server-computed default.** An invitation requires
three instants. A form with three date pickers is not a crude form, and a client that computes
them is a second clock that desynchronises from `HospitalityComs.Clock` the moment U11's demo
control moves it. So the fields are optional and the server fills them from the scope's
instant.

**D7. Crude means unstyled, not unsound.** `AGENTS.md` applies in full: a `@spec` with
enumerated error atoms on every public function, the test-design gate with its brief committed
first, a test for every change. The visual budget is zero; the engineering budget is not
reduced.

**D8. The employer surface is a page in the existing React client, not a separate artefact.**
It reuses the session the client already holds, the router it already runs, and the request
core `client/src/api/client.ts` already exposes. An employer session *is* a person session plus
a venue; a separate login would invent a credential the system does not have.

---

## Actors

- **A1. Venue manager** — a person holding an engagement at a venue that carries a live grant.
  In the seed: `mira@demo.invalid` at Harbour Tavern (General Manager),
  `ana@demo.invalid` at Kolektiv Coffee (Owner).
- **A2. Claimant** — any person with a session, holding a claim code they received out of band.
  Needs no prior relationship to the venue.
- **A3. Demo audience** — watches both windows. Not a user; the reason the surface is honest.

---

## Requirements

### Bringing a person onto the venue

- **R1.** A manager can issue an invitation to their venue naming a role label, and receives a
  claim code in plaintext in the response.
- **R2.** The claim code is displayed until the manager dismisses it, and is never retrievable
  afterwards by any route. The interface says this before it is lost, not after.
- **R3.** Issuing an invitation requires only a role label. Term start, term end and code expiry
  are optional and default server-side from the request's instant.
- **R4.** No rendered invitation payload carries `claim_code_digest`.
- **R5.** A person holding a claim code can redeem it in their own session, and receives the
  engagement it produced.
- **R6.** A code that is unknown, already claimed, or expired is refused with a sentence that
  distinguishes those three, because none of them discloses anything the holder of a code does
  not already know.
- **R7.** A manager can list the people currently engaged at their venue. Each row shows the
  role label, the term, and the engagement id. **No row carries `person_id` or an email
  address.**

### Creating a shift

- **R8.** A manager can list their venue's shift types.
- **R9.** A manager can create a shift room by naming a shift type and a start and end instant.
- **R10.** A manager can list their venue's shift rooms, each labelled by its shift type's name
  rather than by an id.
- **R11.** The shift-room list is bounded, and the bounded read contains the **most recent**
  shifts. A bound applied to the venue's oldest shifts satisfies every count and hides the shift
  the manager just created.

### Rostering

- **R12.** A manager can add an engagement to a shift room's roster.
- **R13.** A manager can list a shift room's current roster, each entry naming the engagement and
  the role label. The label must be available for **every** entry the roster can hold, including
  an engagement whose term has not opened yet — those are rosterable and are absent from the
  venue's people list, so a label sourced from that list would leave them unnamed.
- **R14.** A manager can remove an engagement from a roster.
- **R15.** Rostering an engagement that is already rostered, or naming a shift room or
  engagement that does not belong to this venue, is refused without disclosing which.

### Across the surface

- **R16.** Every employer request resolves its grant against the database, at that request's
  instant. Nothing is cached on the connection or in the client.
- **R17.** A session with no live grant at the named venue is refused identically whether the
  venue is somebody else's, the grant was revoked, or the venue does not exist.
- **R18.** The JSON key set of every employer-facing payload is pinned by a test against a
  written-out literal.
- **R19.** The surface is reachable in a browser without a console, from log-in to a rostered
  worker.
- **R20.** A claim code never reaches a log. It is a bearer credential for an engagement, and the
  demo runs in an environment where request parameters are logged by default.

---

## Key Flows

### F1 — A person joins the venue

1. Mira logs in by magic link and opens the employer page.
2. She picks Harbour Tavern from her venues.
3. She types `Runner` and submits. The page shows a claim code and a warning that it will not
   be shown again.
4. She copies it and sends it to the new starter by whatever means she already uses.
5. In a second window, the new starter logs in with their own address, pastes the code, and
   sees the engagement they now hold.
6. Mira refreshes her people list. A `Runner` row is there.

The engagement in step 6 is visible because its term has already opened — which is why R3's
default start is the request's instant and not tomorrow (see **Assumptions**).

### F2 — Tonight's shift

1. Mira picks a shift type — the seed provides `Close` and `Day` at Harbour.
2. She gives a start and an end and submits.
3. The shift appears in the venue's shift list, labelled `Close`.

### F3 — Putting the new starter on it

1. Mira opens the shift.
2. She picks the `Runner` engagement from the venue's people and adds it.
3. The roster shows one entry.
4. In the other window, the new starter opens the shift room and can read it.

Step 4 is the payoff and needs no new code: shift-room readability is derived from the roster
entry intersecting the room's open window, and `client/src/features/rooms/` already renders it.

---

## Acceptance Examples

- **AE1.** Mira issues an invitation; the response body contains a plaintext claim code and no
  key named `claim_code_digest`.
- **AE2.** The same invitation is issued twice; two different codes come back and both work,
  because an invitation is an offer and nothing deduplicates offers.
- **AE3.** A claim code is submitted twice; the second attempt is refused as already claimed and
  no second engagement exists.
- **AE4.** A code older than its expiry is refused, and the refusal names expiry.
- **AE5.** Ana, who holds an engagement at Harbour but no grant there, opens the employer page
  for Harbour and is refused with the same sentence a nonexistent venue produces.
- **AE6.** Mira's people list contains no `person_id` and no email address, asserted against the
  exact key set.
- **AE7.** Mira rosters an engagement onto a shift room belonging to Kolektiv; refused as
  not-found, with no indication that the room exists.
- **AE8.** Mira rosters the same engagement onto the same shift twice; the second is refused and
  the roster still has one entry.
- **AE9.** Mira removes the entry; the roster is empty and the row still exists in the database
  with an upper bound (KTD6b — nothing is deleted).
- **AE10.** With no grant anywhere, a person opening the employer page sees no venue they can
  act for and one sentence saying so — not an error, and not an empty page.

---

## Success Criteria

- The three flows run end to end in two browser windows with no `iex` and no `psql`.
- An audience watching F1 can say, unprompted, what the employer did and did not learn about
  the new starter.
- No employer-facing payload carries `person_id`, `email`, or `claim_code_digest`, and a test
  fails if one is added.
- `mix quality` clean, `npm run verify` clean, and every new public function carries a `@spec`
  with enumerated error atoms.

---

## Scope Boundaries

### In scope

Issuing invitations; claiming them; listing the venue's active engagements; listing shift
types; creating and listing shift rooms; adding to, listing and removing from a roster; one
unstyled page carrying all of it; one claim box on the worker's side.

### Deferred for later

- **Creating shift types.** The seed provides two at Harbour. A venue with none cannot create a
  shift, which is a real hole and a small one — one more form against
  `Venues.create_shift_type/3`, which already exists.
- **Listing outstanding invitations.** `Engagements.list_invitations/1` exists and returns whole
  `Invitation` structs carrying `claim_code_digest`. Rendering it needs the same field-list
  discipline as everything else here and adds no capability, since the code is unrecoverable
  either way. Its real value is showing what has been offered and not taken.
- **Ending and renewing engagements.** `end_engagement/2` and `renew_engagement/3` exist and are
  the revocation story, which U11's demo controls already drive.
- **Issuing and revoking grants.** Making a second manager. `Venues.issue_grant/1` exists;
  conferring it needs an invitation carrying `grant_id`, which the crude form does not offer.
- **A read of the venues a person administers.** See **Outstanding Questions**.

### Outside this product's identity

- **Any form that takes a worker's email, name or phone number.** There is nowhere to put it and
  building somewhere would be the change this whole project exists to argue against.
- **Delivering the claim code from inside the system.** The system holds no address for an
  unclaimed invitation. A delivery mechanism means storing a contact identifier, which is R1
  reversed.
- **An employer view of who a worker is elsewhere.** The disclosure default already hides
  concurrent engagements and U9 built the view that enforces it.

---

## Dependencies and Assumptions

- **Depends on issue #48 landing.** It establishes the controller shape, `EntityId.cast/1`, the
  field-list render convention, and the client's feature-owns-its-paths layering. Building
  against it before it merges means guessing at all four.
- **Assumption, load-bearing: the default term must open immediately.**
  `Engagements.list_engagements/1` returns only engagements **active at the scope's instant**, so
  an invitation whose term starts tomorrow produces, on claim, an engagement the manager's own
  people list does not show. In a demo that reads as the claim having failed. The default start
  is therefore the request's instant.
- **Assumption: the demo runs at Harbour Tavern.** Kolektiv Coffee has no shift types and no
  shift rooms in the seed, so F2 and F3 are only reachable at Harbour. The seed's venue names
  carry a suffix — `Harbour Tavern (demo)`, `Kolektiv Coffee (demo)` — which is what the picker
  will render.
- **Assumption: role labels are distinct per seeded person.** They are, in
  `dev_support/hospitality_coms/demo.ex` — General Manager, Server, Bartender, Barista, Kitchen
  Porter, Owner. This is the entire mitigation for D2, and a seed change that duplicated a label
  would quietly degrade the surface.
- **The client's request core has no authenticated write.** `client/src/api/client.ts` exposes
  four named calls and one generic `read`. This surface is mostly writes, so a generic
  authenticated write belongs beside `read` — the same layering rule, one verb further.

---

## Outstanding Questions

- **OQ1 — how does the page know which venue it is acting for?** There is no context function
  that lists the venues a person holds a *grant* at. Three answers: reuse the venue list #48
  already ships; add a new read; or paste a UUID. **Recommended: the new read.** The venue-room
  list subtracts suspensions and employer authority does not, so a manager who used the venue-room
  opt-out keeps their authority and disappears from their own picker — a correctness hole, not the
  cosmetic side effect an earlier draft named. Reuse stays defensible only if suspension is
  declared out of demo scope.
- **OQ2 — does "remove from roster" ship?** Recommended yes: `Rosters.remove_from_roster/3`
  exists, and a demo that can roster but not un-roster invites the question at the worst moment.
- **OQ3 — the default term length.** Recommended ninety days, with code expiry at seven. Seven
  rather than fourteen because fourteen is the constraint's own inclusive bound, and a default
  sitting exactly on a bound breaks the first time somebody rounds.
- **OQ4 — is bounding the shift-room list worth its cost?** `Rooms.list_shift_rooms/1` is the one
  list here that grows without limit, and `AGENTS.md` says paginate every such list. #48 built the
  shape for exactly this. R11 assumes yes, at roughly forty-five minutes; answering no means
  striking R11 rather than trimming the work.
</content>
</invoke>
