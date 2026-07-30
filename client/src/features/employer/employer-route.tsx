/**
 * The employer's half of the handshake: pick a venue, see who is on it, offer
 * somebody a job, and copy the code once.
 *
 * ## The picker is a different list from the rooms surface's, on purpose
 *
 * It reads `GET /api/employer/venues` — venues where this person holds an
 * engagement carrying a grant the venue has not revoked, **suspensions not
 * consulted**. `GET /api/venue-rooms` looks like the same list and subtracts
 * suspensions, so a manager who opted out of their own venue room would keep
 * every authority they had and disappear from this page. `employer-api.ts`
 * carries the argument.
 *
 * The page says so out loud, because a manager who suspended a room and still
 * sees the venue here should be able to tell that it is deliberate.
 *
 * ## Nothing on this page names a human
 *
 * `GET /api/employer/venues/:venue_id/engagements` renders `{engagement_id,
 * role_label, starts_at, ends_at}` and nothing else — no `person_id`, no email,
 * and there is no name column anywhere in the schema to omit. So a worker here
 * is a role, a term, and an id that means nothing at any other venue, and the
 * page states that rather than leaving it as an absence somebody might read as
 * an oversight. It is the sentence the demo audience is meant to be able to
 * repeat back.
 *
 * ## The people list is a moment, not a membership
 *
 * `list_engagements/1` is active-at-instant and nothing stores membership, so
 * this list shrinks by itself when a term's upper bound passes and no job ran.
 * Hence a **Refresh** control that is always there rather than only after a
 * failure, and hence the reload after an offer is claimed in the other window —
 * which is F1's last step and the moment the surface exists to show.
 *
 * ## The claim code is shown once and this page is the only place it exists
 *
 * `useOfferDesk` holds it in component state and nothing else touches it: no
 * store, no URL, no log. Dismissing loses it, which is why the warning sits
 * beside the code rather than appearing after it is gone (R2), and why nothing
 * on this page offers to show it again.
 */

import { useState } from "react";
import { Link } from "react-router";

import type { FieldErrors, RequestFailure } from "../../api/errors";
import { instantLabel } from "../../app/instant";
import { SessionBar } from "../../app/session-bar";
import type { ShiftRoomListing } from "../../app/shift-room";
import { shiftRoomLabel } from "../../app/shift-room";
import type { Fetched, Loaded } from "../../app/use-fetched";
import type { IssuedOffer, ManagedVenue, ShiftType, VenueEngagement } from "./employer";
import {
  engagementLabel,
  expiryLabel,
  instantFromLocal,
  offerLabel,
  rosterEntryLabel,
  shiftTypeLabel,
} from "./employer";
import { employerFailureMessage, fieldProblems } from "./refusal-message";
import { useRoster } from "./use-employer-roster";
import type { ShiftDesk, ShiftRooms } from "./use-employer-shifts";
import { useShiftDesk, useShiftRooms, useShiftTypes } from "./use-employer-shifts";
import type { OfferDesk } from "./use-employer-venue";
import {
  useManagedVenues,
  useOfferDesk,
  useVenueEngagements,
} from "./use-employer-venue";

export function EmployerRoute() {
  const venues = useManagedVenues();
  const [chosenId, setChosenId] = useState<string | null>(null);

  const chosen =
    venues.state.status === "ready"
      ? (venues.state.value.find((venue) => venue.venueId === chosenId) ?? null)
      : null;

  return (
    <section>
      <h1>Venues you manage</h1>
      <SessionBar />
      <p>
        <Link to="/">Back to your rooms, peers and record</Link>
      </p>

      <p>
        These are the venues you hold a live authority at, right now. A venue whose room
        you have suspended is still here — suspending a room is about your own reading of
        it and takes nothing away from what you can do on this page.
      </p>

      <Unlisted
        state={venues.state}
        onRetry={venues.reload}
        empty="You cannot act for any venue. That is not an error: an authority is granted at one venue at a time, and nobody has granted you one. Ask somebody who already manages a venue to send you an offer that carries it."
      />

      {venues.state.status === "ready" && venues.state.value.length > 0 && (
        <ul aria-label="Venues you can act for">
          {venues.state.value.map((venue) => (
            <li key={venue.venueId}>
              <button
                type="button"
                aria-current={venue.venueId === chosenId}
                onClick={() => {
                  setChosenId((current) =>
                    current === venue.venueId ? null : venue.venueId,
                  );
                }}
              >
                {venue.name}
              </button>
            </li>
          ))}
        </ul>
      )}

      {chosen !== null && <VenueDesk key={chosen.venueId} venue={chosen} />}
    </section>
  );
}

/**
 * One venue: who is on it, and the form that brings somebody new.
 *
 * Keyed on the venue in `EmployerRoute`, so switching venue remounts rather
 * than re-rendering — which is what drops a claim code issued at the venue
 * being left. A code belongs to one offer at one venue and carrying it across
 * would put it beside the wrong venue's name.
 */
function VenueDesk({ venue }: { readonly venue: ManagedVenue }) {
  const people = useVenueEngagements(venue.venueId);
  const desk = useOfferDesk(venue.venueId);

  return (
    <section aria-label={venue.name}>
      <h2>{venue.name}</h2>

      <h3>People here now</h3>
      <p>
        Everyone whose term is open at this moment. No name and no address, and the
        engagement id below is this venue&rsquo;s alone — it says nothing about where else
        somebody works.
      </p>

      <Unlisted
        state={people.state}
        onRetry={people.reload}
        empty="Nobody is engaged here at the moment. An offer claimed in the other window shows up on this list as soon as you refresh it."
      />

      {people.state.status === "ready" && people.state.value.length > 0 && (
        <ul aria-label="People here now">
          {people.state.value.map((engagement) => (
            <li key={engagement.engagementId}>
              {engagementLabel(engagement)} <code>{engagement.engagementId}</code>
            </li>
          ))}
        </ul>
      )}

      <button type="button" onClick={people.reload}>
        Refresh this list
      </button>

      <h3>Offer a job</h3>
      <OfferForm desk={desk} />

      <ShiftDeskSection venueId={venue.venueId} people={people.state} />
    </section>
  );
}

/**
 * The venue's shifts: the types it runs, the form that creates one, the list,
 * and the roster of whichever shift is open.
 *
 * ## The list is bounded and the bound is invisible here
 *
 * `Rooms.recent_shift_room_limit/0` is the number and it stays in the context.
 * What arrives is a page plus `complete`, and `complete` is the only thing this
 * side knows about the bound — a full page and a full history of the same
 * length are the same list, so the "load every shift" control cannot be derived
 * from a length and is not offered when the server says this is the lot.
 *
 * ## The roster panel is keyed on the shift
 *
 * `VenueDesk`'s manoeuvre for the claim code, one level in: opening another
 * shift remounts rather than re-renders, so a roster fetched for one shift can
 * never be on screen under another one's heading while the second read is in
 * flight.
 */
function ShiftDeskSection({
  venueId,
  people,
}: {
  readonly venueId: string;
  readonly people: Loaded<readonly VenueEngagement[]>;
}) {
  const types = useShiftTypes(venueId);
  const rooms = useShiftRooms(venueId);
  const desk = useShiftDesk(venueId, rooms.reload);
  const [openId, setOpenId] = useState<string | null>(null);

  const listed = rooms.state.status === "ready" ? rooms.state.value.rooms : [];
  const open = listed.find((room) => room.shiftRoomId === openId) ?? null;

  return (
    <>
      <h3>Shifts here</h3>
      <p>
        A shift room <em>is</em> the shift — there is no separate thing to book. It is a
        kind of shift, a start and an end, and whoever is on the roster can read it while
        it is open.
      </p>

      <h4>Create a shift</h4>
      <ShiftForm types={types} desk={desk} />

      <h4>Shifts at this venue</h4>
      <ShiftList rooms={rooms} openId={openId} onOpen={setOpenId} />

      {open !== null && (
        <RosterPanel
          key={open.shiftRoomId}
          venueId={venueId}
          room={open}
          people={people}
        />
      )}
    </>
  );
}

/**
 * A type, a start and an end.
 *
 * **The two instants are this client's only production of one, and it is not a
 * clock read.** `POST …/shift-rooms` has no server-side defaults, unlike the
 * invitation's three, because a shift is a term somebody chose. See
 * `instantFromLocal` for why converting a wall clock the manager typed is not
 * the second clock KTD-E5 forbids.
 *
 * The submit is closed while an answer is outstanding and while anything is
 * blank. Those are two guards on two inputs: the attribute covers "nothing
 * typed", and `onSubmit`'s `null` check covers a value that will not parse —
 * `new Date("tonight").toISOString()` throws, so without it a non-conforming
 * input takes an exception out of this handler.
 *
 * **Neither of those is what stops a duplicate, and this form has nothing
 * behind it that would.** Two shift rooms of one type over one term are
 * legitimately creatable, so no constraint refuses the second and nothing on
 * screen undoes it. Emptying the three inputs on success is therefore the only
 * guard there is: the submit closes on `blank` a moment later for the same
 * reason it was closed before anything was typed, and a manager who did not
 * notice the new row appear below cannot click through it a second time.
 *
 * Cleared **on success, never on submit** — `room-view.tsx`'s rule, and here it
 * matters more: a refused create is a `422` naming a field, and a form that
 * emptied itself would leave the manager reading which of the two instants was
 * wrong with neither of them still on screen.
 */
function ShiftForm({
  types,
  desk,
}: {
  readonly types: Fetched<readonly ShiftType[]>;
  readonly desk: ShiftDesk;
}) {
  const [typeId, setTypeId] = useState("");
  const [startsAt, setStartsAt] = useState("");
  const [endsAt, setEndsAt] = useState("");

  const problem = desk.problem;
  const fields = problem === null ? null : fieldProblems(problem);
  const offered = types.state.status === "ready" ? types.state.value : [];
  const blank = typeId === "" || startsAt === "" || endsAt === "";

  async function create(shiftTypeId: string, from: string, to: string): Promise<void> {
    const created = await desk.create({ shiftTypeId, startsAt: from, endsAt: to });

    if (!created) return;

    setTypeId("");
    setStartsAt("");
    setEndsAt("");
  }

  return (
    <>
      <Unlisted
        state={types.state}
        onRetry={types.reload}
        empty="No shift types are configured at this venue, so no shift can be created here. Shift types are set up outside this page."
      />

      <form
        onSubmit={(event) => {
          event.preventDefault();

          const from = instantFromLocal(startsAt);
          const to = instantFromLocal(endsAt);

          if (typeId === "" || from === null || to === null) return;

          void create(typeId, from, to);
        }}
      >
        <label htmlFor="shift-type">Shift type</label>
        <select
          id="shift-type"
          name="shift-type"
          value={typeId}
          onChange={(event) => {
            setTypeId(event.target.value);
          }}
        >
          <option value="">Choose a shift type</option>
          {offered.map((type) => (
            <option key={type.shiftTypeId} value={type.shiftTypeId}>
              {shiftTypeLabel(type)}
            </option>
          ))}
        </select>

        <label htmlFor="shift-starts">Starts</label>
        <input
          id="shift-starts"
          name="shift-starts"
          type="datetime-local"
          value={startsAt}
          onChange={(event) => {
            setStartsAt(event.target.value);
          }}
        />

        <label htmlFor="shift-ends">Ends</label>
        <input
          id="shift-ends"
          name="shift-ends"
          type="datetime-local"
          value={endsAt}
          onChange={(event) => {
            setEndsAt(event.target.value);
          }}
        />

        <button type="submit" disabled={desk.creating || blank}>
          Create this shift
        </button>
      </form>

      {problem !== null && <Refusal failure={problem} fields={fields} />}
    </>
  );
}

/**
 * The venue's shifts, in the order the server sent them.
 *
 * **Nothing is sorted here.** `Records.most_recent_rooms/2` selects descending
 * and re-orders ascending in SQL around the scan, so the page is the venue's
 * *latest* shifts read forwards. A sort on this side would satisfy every count
 * assertion while hiding the shift the manager created a minute ago, which is
 * the whole reason that query is written the way it is.
 */
function ShiftList({
  rooms,
  openId,
  onOpen,
}: {
  readonly rooms: ShiftRooms;
  readonly openId: string | null;
  readonly onOpen: (id: string | null) => void;
}) {
  const page = rooms.state.status === "ready" ? rooms.state.value : null;

  return (
    <>
      <Unready state={rooms.state} onRetry={rooms.reload} />

      {page !== null && page.rooms.length === 0 && (
        <p aria-live="polite">
          No shifts have been created here yet. The form above is where the first one
          comes from.
        </p>
      )}

      {page !== null && page.rooms.length > 0 && (
        <ul aria-label="Shifts at this venue">
          {page.rooms.map((room) => (
            <li key={room.shiftRoomId}>
              <button
                type="button"
                aria-current={room.shiftRoomId === openId}
                onClick={() => {
                  onOpen(room.shiftRoomId === openId ? null : room.shiftRoomId);
                }}
              >
                {shiftRoomLabel(room)}
              </button>{" "}
              <span>Stops taking messages {instantLabel(room.closesAt)}</span>
            </li>
          ))}
        </ul>
      )}

      {page !== null && !page.complete && (
        <div>
          <p aria-live="polite">
            These are the most recent shifts at this venue. There are more before them.
          </p>
          <button type="button" onClick={rooms.loadAll}>
            Load every shift
          </button>
        </div>
      )}
    </>
  );
}

/**
 * Who is on one shift, and the two controls that change it.
 *
 * **The add picker offers the venue's people list, and that has a limitation
 * worth knowing.** `add_to_roster/3` accepts an engagement whose term has not
 * opened, while `list_engagements/1` answers only with engagements active at
 * the instant — so a starter who begins next Monday is rosterable by the API and
 * cannot be chosen here. A free-text engagement-id box would fix it and would
 * put a uuid paste box on a crude form for a case the demo does not reach; it is
 * recorded rather than built.
 *
 * The *labels* have no such hole: `render_roster_entry/1` projects `role_label`
 * off a preloaded engagement, so an entry this picker could not have produced is
 * still named on the list.
 *
 * **The picker forgets its choice once the add is accepted**, on that branch
 * alone. `busy` covers two clicks on one outstanding request and nothing after
 * it, so a picker that kept the selection re-enabled with the same person still
 * named — and the second add is refused by `roster_entries_no_overlap` as R15's
 * flat `404`, one sentence covering four conditions, which reads like the shift
 * having gone away rather than like the person already being on it.
 *
 * A **refused** add keeps the choice, for `ShiftForm`'s reason: the remedy for
 * a refusal is usually to choose somebody else, and a picker that reset itself
 * would make the manager re-open the list to find out who they had just tried.
 */
function RosterPanel({
  venueId,
  room,
  people,
}: {
  readonly venueId: string;
  readonly room: ShiftRoomListing;
  readonly people: Loaded<readonly VenueEngagement[]>;
}) {
  const roster = useRoster(venueId, room.shiftRoomId);
  const [chosen, setChosen] = useState("");

  const entries = roster.state.status === "ready" ? roster.state.value : [];
  const choosable = people.status === "ready" ? people.value : [];

  async function add(engagementId: string): Promise<void> {
    if (await roster.add(engagementId)) setChosen("");
  }

  return (
    <section aria-label="Roster">
      <h4>Roster · {shiftRoomLabel(room)}</h4>

      <Unlisted
        state={roster.state}
        empty="Nobody is on this shift yet. Add somebody from the venue's people below."
      />

      {entries.length > 0 && (
        <ul aria-label="On this shift">
          {entries.map((entry) => (
            <li key={entry.engagementId}>
              {rosterEntryLabel(entry)}{" "}
              <button
                type="button"
                disabled={roster.busy}
                aria-label={`Take ${entry.roleLabel} off this shift`}
                onClick={() => {
                  void roster.remove(entry.engagementId);
                }}
              >
                Take off this shift
              </button>
            </li>
          ))}
        </ul>
      )}

      {choosable.length === 0 ? (
        <p aria-live="polite">
          Nobody is engaged here to put on a shift. An offer claimed in the other window
          shows up once the people list above is refreshed.
        </p>
      ) : (
        <form
          onSubmit={(event) => {
            event.preventDefault();

            if (chosen === "") return;

            void add(chosen);
          }}
        >
          <label htmlFor="roster-engagement">Add somebody</label>
          <select
            id="roster-engagement"
            name="roster-engagement"
            value={chosen}
            onChange={(event) => {
              setChosen(event.target.value);
            }}
          >
            <option value="">Choose somebody engaged here</option>
            {choosable.map((engagement) => (
              <option key={engagement.engagementId} value={engagement.engagementId}>
                {engagementLabel(engagement)}
              </option>
            ))}
          </select>
          <button type="submit" disabled={roster.busy || chosen === ""}>
            Add to this shift
          </button>
        </form>
      )}

      {roster.problem !== null && (
        <Refusal failure={roster.problem} fields={fieldProblems(roster.problem)} />
      )}
    </section>
  );
}

/**
 * The role label, and nothing else.
 *
 * The term and the code&rsquo;s expiry are optional on the route and defaulted
 * from the request&rsquo;s instant, and this form deliberately does not ask for
 * them: a browser computing "ninety days from now" would be a second clock, and
 * the server&rsquo;s is the one U11&rsquo;s demo controls move.
 *
 * The submit is closed while an answer is outstanding **and** while the field is
 * blank. The first is because two clicks are two live claim codes and the
 * manager would only ever be shown the second; the second is so a mistake costs
 * a sentence here rather than a round trip and a `422`.
 */
function OfferForm({ desk }: { readonly desk: OfferDesk }) {
  const [roleLabel, setRoleLabel] = useState("");
  const problem = desk.problem;
  const fields = problem === null ? null : fieldProblems(problem);

  return (
    <>
      <form
        onSubmit={(event) => {
          event.preventDefault();

          // No `issuing` check here. It would be a third spelling of the same
          // guard — the button carries it as the affordance and `useOfferDesk`
          // carries it as the rule — and measured, a guard behind two others
          // is one no mutation can kill.
          if (roleLabel.trim() === "") return;

          void desk.issue(roleLabel.trim());
        }}
      >
        <label htmlFor="role-label">Role</label>
        <input
          id="role-label"
          name="role-label"
          type="text"
          value={roleLabel}
          onChange={(event) => {
            setRoleLabel(event.target.value);
          }}
        />
        <button type="submit" disabled={desk.issuing || roleLabel.trim() === ""}>
          Offer this job
        </button>
      </form>

      {problem !== null && <Refusal failure={problem} fields={fields} />}

      {desk.issued !== null && (
        <ClaimCode issued={desk.issued} onDismiss={desk.dismiss} />
      )}
    </>
  );
}

/**
 * A refused write, in the server's own words.
 *
 * `refusal-message.ts` carries the argument for why this surface renders
 * `failure.message` rather than copy keyed on the code, and it is stronger for
 * the shift and roster routes than it was for the offer:
 * `EmployerController` answers `404` with three different sentences — no such
 * venue, no such shift type, no such shift room or engagement — so a switch on
 * the code can say one of them and must be wrong about the other two.
 *
 * The per-field messages are Ecto's and name an input the manager filled in,
 * which is the one exception the standing rule already makes.
 */
function Refusal({
  failure,
  fields,
}: {
  readonly failure: RequestFailure;
  readonly fields: FieldErrors | null;
}) {
  return (
    <div role="alert">
      <p>{employerFailureMessage(failure)}</p>
      {fields !== null && (
        <ul>
          {Object.entries(fields).map(([field, messages]) => (
            <li key={field}>
              {field}: {messages.join(", ")}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/**
 * The code, the warning, and the one control that loses it.
 *
 * The warning is above the code rather than below it: R2 asks the interface to
 * say the code is unrepeatable **before** it is lost, and a caution underneath a
 * button somebody already pressed is a caution nobody read.
 */
function ClaimCode({
  issued,
  onDismiss,
}: {
  readonly issued: IssuedOffer;
  readonly onDismiss: () => void;
}) {
  return (
    <div role="status">
      <h4>Claim code</h4>
      <p>
        <strong>Copy this now — it is shown once and nothing can show it again.</strong>{" "}
        Send it to the new starter however you already talk to them; this product holds no
        address for them and never will.
      </p>
      <p>
        <code>{issued.claimCode}</code>
      </p>
      <p>
        {offerLabel(issued.invitation)}. The code stops working{" "}
        {expiryLabel(issued.invitation)}.
      </p>
      <button type="button" onClick={onDismiss}>
        I have copied it — hide it
      </button>
    </div>
  );
}

/**
 * The three states a fetched list has before it has rows, and nothing when it
 * has them.
 *
 * `aria-live="polite"` without `role="status"`, which is
 * `features/rooms/rooms-route.tsx`&rsquo;s choice for its reason: this page
 * already has one region a manager is waiting on — the claim code — and two
 * competing status regions make the important one harder to find.
 */
function Unlisted<T>({
  state,
  empty,
  onRetry,
}: {
  readonly state: Loaded<readonly T[]>;
  readonly empty: string;
  readonly onRetry?: () => void;
}) {
  if (state.status === "ready") {
    return state.value.length === 0 ? <p aria-live="polite">{empty}</p> : null;
  }

  return <Unready state={state} onRetry={onRetry} />;
}

/**
 * The same three non-answers for a fetch whose value is not a list.
 *
 * The shift-room read answers a *page* — rows plus `complete` — so "ready and
 * empty" is the caller's question rather than this component's, and `Unlisted`
 * above is this plus that one sentence. Splitting them was what U5 needed;
 * neither changed behaviour.
 */
function Unready<T>({
  state,
  onRetry,
}: {
  readonly state: Loaded<T>;
  readonly onRetry?: (() => void) | undefined;
}) {
  switch (state.status) {
    case "idle":
    case "ready":
      return null;
    case "loading":
      return <p aria-live="polite">Loading…</p>;
    case "failed":
      return (
        <div>
          <p aria-live="polite">{employerFailureMessage(state.failure)}</p>
          {onRetry !== undefined && (
            <button type="button" onClick={onRetry}>
              Try again
            </button>
          )}
        </div>
      );
  }
}
