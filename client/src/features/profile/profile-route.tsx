/**
 * The profile surface: the worker's own record, and what they have decided
 * about who sees it.
 *
 * ## Somebody else's record is not on this screen, and that is #73
 *
 * There was a third section — a text box for a person's uuid and a button
 * reading "Read their record". The surface behind it is real and works:
 * `peer_profile` is one of `ProfileChannel`'s eight events, `#71` verified it
 * end to end against a live server, and `useProfileSurface`'s `loadPeerProfile`
 * is untouched and still tested. **What was wrong was the way in.** The only
 * peers a worker can name are the ones whose uuid they have somehow already
 * got, and nothing on this channel enumerates one — so the control asked for
 * the answer as its input.
 *
 * So it is **not rendered** rather than hidden with a style rule or a flag: a
 * component still mounted still joins, still fetches, and still leaves a
 * focusable input in the accessibility tree, which is a uuid box a screen
 * reader can find and a sighted worker cannot.
 *
 * **What brings it back is a picker, and the list it needs now exists.** #76's
 * `list_audiences` answers `people` as `Peers.list_reachable_peers/1` — visible
 * **or** connected, which is exactly the pair `Profiles.fetch_peer_profile/2`
 * gates on, so it is the list of people this worker may read and not an
 * approximation of one. `DisclosureControl` reads it below.
 *
 * This section is still **not** brought back, and that is scope rather than an
 * obstacle: #73's client half is the names and the disclosure audience, and
 * reviving a whole surface is a decision about what the profile screen is for.
 * Whoever does it takes `surface.audiences.people` and a chooser where the text
 * box was, and brings `ProfileView` back with it — see below for the rule that
 * component existed to hold, which has to be **re-asserted, not assumed**, at
 * the same time.
 *
 * ## The one rule this file exists to not break
 *
 * `Profiles.incompleteness_notice/0` is arity zero so that a worker who is
 * concealing something is **indistinguishable** from one who has nothing to
 * conceal. The views' column lists are pinned server-side so a `hidden_count`
 * cannot be added quietly, and `profiles_test.exs` asserts that an employer
 * read of a concealing worker is identical in length and key set to a read of
 * one who has never worked anywhere else.
 *
 * All of that is defeated by a render layer that computes the difference back.
 * A count, a gap, an ordinal, "3 entries shown", a different notice, an empty
 * slot where a hidden entry would sit — any of them turns a guarantee the
 * database and the context both hold into a claim the screen contradicts. So:
 *
 *   * **Nothing here renders somebody else's record at all**, which is the
 *     render-layer half of that rule holding vacuously rather than by
 *     construction. It used to hold by construction: `ProfileView` took a
 *     heading, a profile and the notice, and could not be handed a ledger or a
 *     count. That component and the tests that read its DOM went with the
 *     section, deliberately — an assertion that a component nothing renders
 *     discloses nothing is the "both operands empty" shape this project keeps
 *     finding — and the property has to be **re-asserted, not assumed**, by
 *     whoever puts a peer's record back on screen.
 *   * The notice comes off the **connection**, so it is one string per session
 *     rather than one per subject, and it cannot be influenced by a profile
 *     reply.
 *   * No list here is numbered and none renders its length.
 *
 * ## An attested entry has no edit control, and that is R16
 *
 * A person cannot edit an employer's assertion — `Profiles` exports no function
 * that would, and `profiles_test.exs` pins the whole export list against a
 * literal so that `edit_entry/3` cannot appear later. The remedy offered beside
 * each attested entry is therefore a **correction request**, and the copy says
 * what resolving one does and does not do: accepting is an acknowledgement, and
 * any real correction is a change to the engagement.
 *
 * Declared entries are the worker's own word, so those *do* have an edit
 * control. The two sit in separate sections with separate headings for that
 * reason rather than for tidiness.
 */

import { useId, useState } from "react";

import { useSession } from "../../session/session-context";
import type {
  AttestedEntry,
  AudienceKind,
  Audiences,
  CorrectionRequest,
  DeclaredEntry,
  Disclosure,
} from "./profile";
import {
  AUDIENCE_KINDS,
  audienceKindLabel,
  audienceName,
  decisionsFor,
  disclosureState,
  disclosureStateLabel,
  noAudiences,
  resolutionLabel,
  resolutionMessage,
  shortId,
} from "./profile";
import type { ProfileFailure, ProfileNotice } from "./refusal-message";
import { noticeMessage, refusalMessage } from "./refusal-message";
import type {
  DeclaredEntryDraft,
  ProfileConnection,
  ProfileSurface,
} from "./use-profile-surface";
import { useProfileSurface } from "./use-profile-surface";

export function ProfileRoute() {
  const { state } = useSession();

  // `RequireSession` renders this only when the session is authenticated. The
  // early return narrows the union; it is not a state that happens.
  if (state.status !== "authenticated") return null;

  return <ProfileSurfaceScreen personId={state.person.id} />;
}

function ProfileSurfaceScreen({ personId }: { readonly personId: string }) {
  const surface = useProfileSurface(personId);
  const notice =
    surface.connection.status === "joined" ? surface.connection.incompletenessNotice : "";

  return (
    <section>
      <h1>Your record</h1>

      <ConnectionState connection={surface.connection} />
      <Notice notice={surface.notice} onDismiss={surface.clearNotice} />

      <IncompletenessNotice notice={notice} />

      <AttestedEntries surface={surface} />
      <DeclaredEntries surface={surface} />
      <CorrectionRequests requests={surface.own.correctionRequests} />
      {/*
        A fourth section, "Somebody else's record", was here until #73. It is
        gone rather than hidden, `surface.loadPeerProfile` is untouched, and
        what brings it back is a picker — this file's header carries the whole
        argument and the obligation that comes with reviving it.
      */}
    </section>
  );
}

/**
 * The standing notice, rendered above the worker's record.
 *
 * One component and one caller-supplied string. It took the string from a
 * caller because a peer's record was shown beside the identical one, and it
 * keeps doing so with that section gone: the alternative is reading the
 * connection here, which is one more place for a per-subject notice to be
 * introduced later, and per-subject is exactly what arity zero forbids.
 */
function IncompletenessNotice({ notice }: { readonly notice: string }) {
  if (notice === "") return null;

  return <p role="note">{notice}</p>;
}

function ConnectionState({ connection }: { readonly connection: ProfileConnection }) {
  switch (connection.status) {
    case "no_socket":
      return <p role="status">Connecting…</p>;
    case "no_person":
      return (
        <p role="alert">
          This session does not name a person this client can open a record for.
        </p>
      );
    case "joining":
      return <p role="status">Opening your record…</p>;
    case "joined":
      return null;
    case "timed_out":
      return (
        <p role="alert">
          The server has not answered yet. It will keep trying on its own; nothing has
          been refused.
        </p>
      );
    case "refused":
      return <p role="alert">{refusalMessage("join", connection.failure)}</p>;
  }
}

/** The most recent refusal, in one place. `PeersRoute`'s argument, unchanged. */
function Notice({
  notice,
  onDismiss,
}: {
  readonly notice: ProfileNotice | null;
  readonly onDismiss: () => void;
}) {
  if (notice === null) return null;

  return (
    <div>
      <p role="alert">{noticeMessage(notice)}</p>
      {notice.kind === "refused" && notice.failure.kind === "channel_field_error" && (
        <FieldMessages failure={notice.failure} />
      )}
      <button type="button" onClick={onDismiss}>
        Dismiss
      </button>
    </div>
  );
}

/**
 * The per-field messages from a changeset, shown as they arrive.
 *
 * The one exception to "the server's message is never rendered": these come
 * from Ecto's changeset traversal and name an input the worker filled in, so
 * they are the only server strings on this surface that are about the worker
 * rather than about a log.
 */
export function FieldMessages({
  failure,
}: {
  readonly failure: Extract<ProfileFailure, { kind: "channel_field_error" }>;
}) {
  return (
    <ul aria-label="What the server said about each field">
      {Object.entries(failure.fields).map(([field, messages]) => (
        <li key={field}>
          <strong>{field}</strong> {messages.join(", ")}
        </li>
      ))}
    </ul>
  );
}

function Term({
  startsAt,
  endsAt,
}: {
  readonly startsAt: string;
  readonly endsAt: string;
}) {
  return (
    <span>
      <time dateTime={startsAt}>{startsAt}</time> to{" "}
      <time dateTime={endsAt}>{endsAt}</time>
    </span>
  );
}

/* ------------------------------------------------------------------ *
 * The worker's own attested entries, with the controls only they get. *
 * ------------------------------------------------------------------ */

function AttestedEntries({ surface }: { readonly surface: ProfileSurface }) {
  return (
    <>
      <h2>Jobs an employer confirmed</h2>
      <p>
        Each of these was written when you claimed an invitation, and only the employer
        that made it can change it. You cannot edit one, and neither can anybody on your
        behalf — what you can do is ask for a correction.
      </p>
      <p>
        This list is everything, including entries you have hidden from somebody. You
        could not decide what to hide if you could not see it.
      </p>
      {surface.own.attestedEntries.length === 0 ? (
        <p>No employer has confirmed a job for you yet.</p>
      ) : (
        <ul aria-label="Jobs an employer confirmed">
          {surface.own.attestedEntries.map((entry) => (
            <li key={entry.attestedEntryId}>
              <OwnAttestedEntry entry={entry} surface={surface} />
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

function OwnAttestedEntry({
  entry,
  surface,
}: {
  readonly entry: AttestedEntry;
  readonly surface: ProfileSurface;
}) {
  return (
    <>
      <strong>{entry.roleLabel}</strong> <span>at {entry.venueName}</span>{" "}
      <Term startsAt={entry.startsAt} endsAt={entry.endsAt} />
      <EntryAudiences
        entry={entry}
        disclosures={surface.disclosures}
        audiences={surface.audiences}
      />
      <DisclosureControl entry={entry} surface={surface} />
      <CorrectionControl entry={entry} surface={surface} />
    </>
  );
}

/**
 * What this worker has **decided** about one entry — which is not the same
 * question as who can see it, and the copy says so.
 *
 * The ledger holds overrides only. Both defaults are computed server-side from
 * periods that are already stored — an employer is hidden an entry whose term
 * overlapped one of theirs, and a peer is shown one unless the worker said
 * otherwise *and* unless a venue binding that peer would hide it — and neither
 * is on any wire this client reads.
 *
 * So an audience with no row renders "Not decided" and the section says
 * plainly that the rest follows a rule this screen cannot compute. Rendering
 * "Visible" for every audience without a row was the tempting alternative and
 * would be actively wrong: the employer default *hides* an entry exactly where
 * a worker's jobs overlapped, so the reassuring version would tell somebody
 * their second job was disclosed to the venue it is in fact concealed from —
 * and the decision they would then not bother taking is the one this whole
 * unit exists to give them.
 */
function EntryAudiences({
  entry,
  disclosures,
  audiences,
}: {
  readonly entry: AttestedEntry;
  readonly disclosures: readonly Disclosure[];
  readonly audiences: Audiences | null;
}) {
  const decisions = decisionsFor(disclosures, entry);

  return (
    <>
      <h3>Who you have decided about</h3>
      {decisions.length === 0 ? (
        <p>You have not made a decision about this entry.</p>
      ) : (
        <ul aria-label={`Decisions about ${entry.roleLabel} at ${entry.venueName}`}>
          {decisions.map((decision) => (
            <li key={decision.disclosureId}>
              <span>{audienceKindLabel(decision.audienceKind)}</span>{" "}
              <AudienceName
                audiences={audiences}
                kind={decision.audienceKind}
                audienceId={decision.audienceId}
              />{" "}
              <span>{disclosureStateLabel(decision.disclosed ? "shown" : "hidden")}</span>{" "}
              <span>
                decided <time dateTime={decision.decidedAt}>{decision.decidedAt}</time>
              </span>
            </li>
          ))}
        </ul>
      )}
      <p>
        Anybody not named above sees this entry according to a rule worked out from the
        dates themselves, and this page cannot work out what that comes to. An employer is
        not shown a job whose dates overlapped one of theirs; a workmate is shown it
        unless a place they are bound to would hide it. Naming somebody below overrides
        whichever rule would otherwise apply to them.
      </p>
    </>
  );
}

/**
 * What one past decision's audience is called, or the short id when it has no
 * name this worker can be given.
 *
 * **The unnameable case is ordinary, not exceptional, and it is a consequence
 * of what `list_audiences` answers.** The venues on it are engagements *active
 * at the instant* and the people are visible *or connected now*, while the
 * ledger is permanent — so a decision taken about last year's employer is still
 * in force and cannot be resolved to a name. #76 records the same residue from
 * the server's side: a venue whose term has ended is not offered, because it
 * cannot read the record either, and the decision applies again if the worker
 * returns.
 *
 * So it is rendered rather than interpolated. `{name ?? ""} · {shortId(id)}`
 * and `{audiences && name} · {shortId(id)}` are each one character from correct
 * and both put a dangling "· 4a3f1b2c" on screen, which reads as a rendering
 * fault rather than as a fact about somebody's record — and neither is visible
 * to a test that only checks the short id is present.
 */
function AudienceName({
  audiences,
  kind,
  audienceId,
}: {
  readonly audiences: Audiences | null;
  readonly kind: AudienceKind;
  readonly audienceId: string;
}) {
  const name = audienceName(audiences, kind, audienceId);

  if (name === null) {
    return (
      <>
        <strong>{shortId(audienceId)}</strong>{" "}
        <span>
          — this decision still applies, and they are not somebody you can name from here
          at the moment.
        </span>
      </>
    );
  }

  return (
    <strong>
      {name} · {shortId(audienceId)}
    </strong>
  );
}

/**
 * One audience, as a `<select>` option value.
 *
 * The audience is a **tagged union** — a kind and an id — and a `<select>`
 * carries one string. So the tag travels in the value and is parsed back out at
 * the one place that needs it. `contract.ts` already argues this for the wire,
 * where the pair is `audience_kind` + `audience_id` rather than two nullable
 * columns, and the argument is the same one: the split done twice is the
 * defect. There is one writer and one reader of this encoding, both here.
 *
 * A `:` cannot appear in a uuid, so the split is unambiguous.
 */
type PickedAudience = { readonly kind: AudienceKind; readonly id: string };

function audienceValue(picked: PickedAudience): string {
  return `${picked.kind}:${picked.id}`;
}

function parseAudience(value: string): PickedAudience | null {
  const separator = value.indexOf(":");
  if (separator === -1) return null;

  const kind = AUDIENCE_KINDS.find(
    (candidate) => candidate === value.slice(0, separator),
  );
  if (kind === undefined) return null;

  const id = value.slice(separator + 1);
  if (id === "") return null;

  return { kind, id };
}

/**
 * Show or hide one entry from one audience.
 *
 * **The audience is picked from a list, and until #73 it was typed as a raw
 * uuid.** The reason it had to be is worth keeping, because it is what the
 * server change removed rather than something that stopped mattering: an
 * audience is a venue or a person, and nothing this client could read
 * enumerated either. `VisibleEntry.venue_id` is the venue that *asserted* the
 * entry rather than one that might read it, and `Peers.list_visible_peers/1`
 * lived on another channel. The only picker this surface could have built was
 * one offering the attesting venue — the single audience an entry is never
 * hidden from, and so the one the control is useless for.
 *
 * #76 added `list_audiences`, which answers both halves at one instant: the
 * venues the worker holds an engagement at **now**, and the people who can see
 * them **now**. So the picker exists, and the kind selector is gone with the
 * text box — the kind is not a choice a worker makes, it is a fact about
 * whichever row they picked, and offering it separately invited the one
 * combination the server refuses outright (a person id tagged as a venue).
 *
 * **Three render states, and two of them would otherwise be one.** `audiences`
 * is `null` until answered, so "still loading" cannot render as "there is
 * nobody to name" — see `useProfileSurface`. Both lists empty is a real answer
 * and gets its own sentence.
 */
function DisclosureControl({
  entry,
  surface,
}: {
  readonly entry: AttestedEntry;
  readonly surface: ProfileSurface;
}) {
  const [value, setValue] = useState("");
  const [saving, setSaving] = useState(false);

  const { audiences } = surface;
  const audienceField = `audience-${entry.attestedEntryId}`;

  const picked = value === "" ? null : parseAudience(value);

  // What is already true of the audience selected, so the worker is not
  // deciding blind. This is the one place the three-valued answer is rendered
  // as such — the list above always has a decision in hand, and here there
  // usually is not one, which is exactly where "Not decided" has to appear
  // instead of a guess at what the default resolves to.
  const current =
    picked === null
      ? null
      : disclosureState(surface.disclosures, entry, picked.kind, picked.id);

  async function decide(disclosed: boolean): Promise<void> {
    if (picked === null) return;

    setSaving(true);
    await surface.setDisclosure(
      entry.entryEngagementId,
      picked.kind,
      picked.id,
      disclosed,
    );
    setSaving(false);
  }

  // Not answered yet, refused, or answered in a shape this client could not
  // read. All three are "not known", and none of them is "there is nobody" —
  // saying so while a round trip is in flight would take the control away from
  // a worker who has audiences, with nothing on screen to say why. A refusal
  // additionally renders through the surface's notice.
  if (audiences === null) {
    return <p>Loading the employers and people you could name.</p>;
  }

  if (noAudiences(audiences)) {
    return (
      <p>
        There is nobody to name yet. Employers you currently work for, and people who can
        see you, appear here — and a decision you take stays in force even after they stop
        appearing.
      </p>
    );
  }

  return (
    <>
      {/*
        The label names the entry, and it has to: this control is rendered once
        per attested entry, so a bare "Who this is about" would be one
        accessible name pointing at several controls — indistinguishable to a
        screen reader and ambiguous to anything else resolving a control by its
        label. It was two fields with this problem and is now one.
      */}
      <label htmlFor={audienceField}>
        Who this is about, for {entry.roleLabel} at {entry.venueName}
      </label>
      <select
        id={audienceField}
        value={value}
        disabled={saving}
        onChange={(event) => {
          setValue(event.target.value);
        }}
      >
        {/*
          Every option carries `· <short id>`, for the reason the answer buttons
          on the peer surface do: **neither name is unique**. A display-name
          collision is deliberate — a globally unique readable name would be a
          second `person_id` in plain text — and `venues.name` has no unique
          index either, so two venues may share one as easily as two people.
          Without the id, two audiences collapse into two identical `<option>`s
          that a sighted worker cannot tell apart and a screen reader announces
          identically, while the `value` quietly carries the right id for
          whichever one happened to be picked. Getting the *wrong* audience is
          the failure here, and it is silent.
        */}
        <option value="">Choose somebody</option>
        {audiences.venues.length > 0 && (
          <optgroup label={audienceKindLabel("venue")}>
            {audiences.venues.map((venue) => (
              <option
                key={venue.venueId}
                value={audienceValue({ kind: "venue", id: venue.venueId })}
              >
                {venue.name} · {shortId(venue.venueId)}
              </option>
            ))}
          </optgroup>
        )}
        {audiences.people.length > 0 && (
          <optgroup label={audienceKindLabel("person")}>
            {audiences.people.map((person) => (
              <option
                key={person.personId}
                value={audienceValue({ kind: "person", id: person.personId })}
              >
                {person.displayName} · {shortId(person.personId)}
              </option>
            ))}
          </optgroup>
        )}
      </select>

      {current !== null && (
        <p>
          Right now, for them: <strong>{disclosureStateLabel(current)}</strong>
        </p>
      )}

      <button
        type="button"
        disabled={saving || picked === null}
        onClick={() => {
          void decide(true);
        }}
      >
        Show {entry.roleLabel} at {entry.venueName} to them
      </button>
      <button
        type="button"
        disabled={saving || picked === null}
        onClick={() => {
          void decide(false);
        }}
      >
        Hide {entry.roleLabel} at {entry.venueName} from them
      </button>
    </>
  );
}

/** The only remedy against an attested entry. See this file's header. */
function CorrectionControl({
  entry,
  surface,
}: {
  readonly entry: AttestedEntry;
  readonly surface: ProfileSurface;
}) {
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);

  const field = `correction-${entry.attestedEntryId}`;

  async function send(): Promise<void> {
    setSending(true);
    const outcome = await surface.requestCorrection(entry.entryEngagementId, body.trim());
    setSending(false);

    if (outcome.status === "ok") setBody("");
  }

  return (
    <>
      <label htmlFor={field}>
        Ask {entry.venueName} to correct this — what is wrong with it?
      </label>
      <textarea
        id={field}
        value={body}
        disabled={sending}
        onChange={(event) => {
          setBody(event.target.value);
        }}
      />
      <button
        type="button"
        disabled={sending || body.trim() === ""}
        onClick={() => {
          void send();
        }}
      >
        Ask {entry.venueName} for a correction
      </button>
    </>
  );
}

/* -------------------------------------------- *
 * The worker's own word, which they may amend.  *
 * -------------------------------------------- */

function DeclaredEntries({ surface }: { readonly surface: ProfileSurface }) {
  // The create form names no entry, because there is not one yet. `useId` is
  // the only unique thing available to it, and a literal would be unique only
  // for as long as this form is rendered once.
  const newEntryFields = useId();

  return (
    <>
      <h2>Jobs you have written down yourself</h2>
      <p>
        Work this application knows nothing about. You wrote these, you can change them,
        and nobody else can. Anybody who can read your record reads them whole — writing
        one is publishing it, so there is nothing to decide about who sees one.
      </p>
      {surface.own.declaredEntries.length === 0 ? (
        <p>You have not written any down.</p>
      ) : (
        <ul aria-label="Jobs you have written down yourself">
          {surface.own.declaredEntries.map((entry) => (
            <li key={entry.declaredEntryId}>
              <OwnDeclaredEntry entry={entry} surface={surface} />
            </li>
          ))}
        </ul>
      )}
      <DeclaredEntryForm
        heading="Write one down"
        fieldPrefix={newEntryFields}
        submitLabel="Write this down"
        onSubmit={surface.declareEntry}
      />
    </>
  );
}

function OwnDeclaredEntry({
  entry,
  surface,
}: {
  readonly entry: DeclaredEntry;
  readonly surface: ProfileSurface;
}) {
  const [amending, setAmending] = useState(false);

  return (
    <>
      <strong>{entry.roleLabel}</strong> <span>at {entry.organisationName}</span>{" "}
      <Term startsAt={entry.startsAt} endsAt={entry.endsAt} />
      <button
        type="button"
        onClick={() => {
          setAmending((open) => !open);
        }}
      >
        {amending ? "Stop changing" : "Change"} {entry.roleLabel} at{" "}
        {entry.organisationName}
      </button>
      {amending && (
        <DeclaredEntryForm
          heading={`Change ${entry.roleLabel} at ${entry.organisationName}`}
          fieldPrefix={`declared-entry-${entry.declaredEntryId}`}
          submitLabel={`Save ${entry.roleLabel} at ${entry.organisationName}`}
          initial={{
            roleLabel: entry.roleLabel,
            organisationName: entry.organisationName,
            startsAt: entry.startsAt,
            endsAt: entry.endsAt,
          }}
          onSubmit={(draft) => surface.amendDeclaredEntry(entry.declaredEntryId, draft)}
        />
      )}
    </>
  );
}

const EMPTY_DRAFT: DeclaredEntryDraft = {
  roleLabel: "",
  organisationName: "",
  startsAt: "",
  endsAt: "",
};

/**
 * One form for writing an entry and for changing one.
 *
 * Nothing is validated here beyond "not blank". The rules — a label at most 120
 * characters, an organisation name likewise, and `ends_at` strictly after
 * `starts_at` — live in `DeclaredEntry`'s changeset *and* in five check
 * constraints, so restating them in this file would be a third copy that goes
 * stale silently. A refusal arrives as `unprocessable_entity` with `fields`,
 * which is the one place the server's own words are shown.
 *
 * ## `fieldPrefix` names the entry and never the heading
 *
 * It was `heading`, which is `Change <role> at <organisation>` — **content**,
 * and content two entries can share: a worker who did two stints as Chef at one
 * place has two of them, which is exactly the record this form exists to let
 * them write. Both forms then rendered `id="Change Chef at …-role"` for their
 * first field and the same for the other three. A `<label for>` resolves through
 * `getElementById`, which answers the *first* element with that id, so the
 * second form's four fields had no label at all: clicking its "What you did"
 * put the cursor in the first form's input, and a screen reader reading the
 * second form announced the first form's names.
 *
 * So the prefix is the entry's own id, which is unique by construction, and it
 * is a required prop rather than a default so that a caller cannot fall back
 * into deriving one. `DisclosureControl` and `CorrectionControl` already key on
 * `entry.attestedEntryId`; this form was the odd one out in its own file.
 */
function DeclaredEntryForm({
  heading,
  fieldPrefix,
  submitLabel,
  initial = EMPTY_DRAFT,
  onSubmit,
}: {
  readonly heading: string;
  /** Unique per rendered form. An entity id, or `useId()` where there is none. */
  readonly fieldPrefix: string;
  readonly submitLabel: string;
  readonly initial?: DeclaredEntryDraft;
  readonly onSubmit: (draft: DeclaredEntryDraft) => Promise<{ readonly status: string }>;
}) {
  const [draft, setDraft] = useState<DeclaredEntryDraft>(initial);
  const [saving, setSaving] = useState(false);

  const incomplete =
    draft.roleLabel.trim() === "" ||
    draft.organisationName.trim() === "" ||
    draft.startsAt.trim() === "" ||
    draft.endsAt.trim() === "";

  async function submit(): Promise<void> {
    setSaving(true);
    const outcome = await onSubmit(draft);
    setSaving(false);

    if (outcome.status === "ok" && initial === EMPTY_DRAFT) setDraft(EMPTY_DRAFT);
  }

  return (
    <fieldset disabled={saving}>
      <legend>{heading}</legend>

      <label htmlFor={`${fieldPrefix}-role`}>What you did</label>
      <input
        id={`${fieldPrefix}-role`}
        value={draft.roleLabel}
        onChange={(event) => {
          setDraft((current) => ({ ...current, roleLabel: event.target.value }));
        }}
      />

      <label htmlFor={`${fieldPrefix}-organisation`}>Where</label>
      <input
        id={`${fieldPrefix}-organisation`}
        value={draft.organisationName}
        onChange={(event) => {
          setDraft((current) => ({ ...current, organisationName: event.target.value }));
        }}
      />

      <label htmlFor={`${fieldPrefix}-starts`}>From</label>
      <input
        id={`${fieldPrefix}-starts`}
        value={draft.startsAt}
        onChange={(event) => {
          setDraft((current) => ({ ...current, startsAt: event.target.value }));
        }}
      />

      <label htmlFor={`${fieldPrefix}-ends`}>Until</label>
      <input
        id={`${fieldPrefix}-ends`}
        value={draft.endsAt}
        onChange={(event) => {
          setDraft((current) => ({ ...current, endsAt: event.target.value }));
        }}
      />

      <button
        type="button"
        disabled={saving || incomplete}
        onClick={() => {
          void submit();
        }}
      >
        {submitLabel}
      </button>
    </fieldset>
  );
}

/* ------------------------------------ *
 * Corrections, from the worker's side. *
 * ------------------------------------ */

function CorrectionRequests({
  requests,
}: {
  readonly requests: readonly CorrectionRequest[];
}) {
  return (
    <>
      <h2>Corrections you have asked for</h2>
      {requests.length === 0 ? (
        <p>You have not asked for any.</p>
      ) : (
        <ul aria-label="Corrections you have asked for">
          {requests.map((request) => (
            <li key={request.correctionRequestId}>
              <p>{request.body}</p>
              <span>
                asked <time dateTime={request.requestedAt}>{request.requestedAt}</time>
              </span>{" "}
              <strong>{resolutionLabel(request.resolution)}</strong>{" "}
              <span>{resolutionMessage(request.resolution)}</span>
              {request.resolvedAt !== null && (
                <span>
                  answered <time dateTime={request.resolvedAt}>{request.resolvedAt}</time>
                </span>
              )}
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
