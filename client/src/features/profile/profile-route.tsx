/**
 * The profile surface: the worker's own record, and what they have decided
 * about who sees it.
 *
 * ## Somebody else's record is not on this screen, and that is #73
 *
 * There was a third section — a text box for a person's uuid and a button
 * reading "Read their record". The surface behind it is real and works:
 * `peer_profile` is one of `ProfileChannel`'s seven events, `#71` verified it
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
 * **What brings it back is a picker**, and the picker needs a list of people
 * this worker may read — the same gap `DisclosureControl` records for the
 * audience it cannot enumerate. `Peers.list_visible_peers/1` is the nearest
 * thing and it lives on another channel; the server half of #73 is building
 * the lists that would make one possible. When it lands, this section comes
 * back with a chooser where the text box was, and `ProfileView` comes back with
 * it — see below for the rule that component existed to hold, which has to be
 * re-asserted at the same time.
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
  CorrectionRequest,
  DeclaredEntry,
  Disclosure,
} from "./profile";
import {
  audienceKindLabel,
  decisionsFor,
  disclosureState,
  disclosureStateLabel,
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
      <EntryAudiences entry={entry} disclosures={surface.disclosures} />
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
}: {
  readonly entry: AttestedEntry;
  readonly disclosures: readonly Disclosure[];
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
              <strong>{shortId(decision.audienceId)}</strong>{" "}
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
 * Show or hide one entry from one audience.
 *
 * **There is no picker, and the reason is a gap in what U9 puts on a wire.**
 * An audience is a venue or a person, and nothing this client can read
 * enumerates either: `VisibleEntry.venue_id` is the venue that *asserted* the
 * entry rather than a venue that might read it, and there is no event that
 * lists the venues a worker holds an engagement at or the peers who can see
 * them. `Peers.list_visible_peers/1` is the nearest thing and it lives on
 * another channel.
 *
 * So the audience is typed in, which is honest and poor, and the alternative —
 * offering only the attesting venue, which is the one venue whose id is on
 * screen — would be worse than poor: an entry is never hidden from the venue
 * that wrote it, so the only picker this surface *could* build is a picker of
 * the one audience the control is useless for. Recorded in `README.md`.
 */
function DisclosureControl({
  entry,
  surface,
}: {
  readonly entry: AttestedEntry;
  readonly surface: ProfileSurface;
}) {
  const [kind, setKind] = useState<AudienceKind>("venue");
  const [audienceId, setAudienceId] = useState("");
  const [saving, setSaving] = useState(false);

  const kindField = `audience-kind-${entry.attestedEntryId}`;
  const idField = `audience-id-${entry.attestedEntryId}`;

  // What is already true of the audience being typed, so the worker is not
  // deciding blind. This is the one place the three-valued answer is rendered
  // as such — the list above always has a decision in hand, and here there
  // usually is not one, which is exactly where "Not decided" has to appear
  // instead of a guess at what the default resolves to.
  const trimmed = audienceId.trim();
  const current =
    trimmed === "" ? null : disclosureState(surface.disclosures, entry, kind, trimmed);

  async function decide(disclosed: boolean): Promise<void> {
    setSaving(true);
    await surface.setDisclosure(
      entry.entryEngagementId,
      kind,
      audienceId.trim(),
      disclosed,
    );
    setSaving(false);
  }

  return (
    <>
      <label htmlFor={kindField}>Who this is about</label>
      <select
        id={kindField}
        value={kind}
        disabled={saving}
        onChange={(event) => {
          setKind(event.target.value === "person" ? "person" : "venue");
        }}
      >
        <option value="venue">{audienceKindLabel("venue")}</option>
        <option value="person">{audienceKindLabel("person")}</option>
      </select>

      {/*
        The label names the entry, and it has to: this control is rendered once
        per attested entry, so a bare "Their id" would be one accessible name
        pointing at several fields — indistinguishable to a screen reader and
        ambiguous to anything else that resolves a control by its label.
      */}
      <label htmlFor={idField}>
        Their id, for {entry.roleLabel} at {entry.venueName}
      </label>
      <input
        id={idField}
        value={audienceId}
        disabled={saving}
        onChange={(event) => {
          setAudienceId(event.target.value);
        }}
      />

      {current !== null && (
        <p>
          Right now, for them: <strong>{disclosureStateLabel(current)}</strong>
        </p>
      )}

      <button
        type="button"
        disabled={saving || trimmed === ""}
        onClick={() => {
          void decide(true);
        }}
      >
        Show {entry.roleLabel} at {entry.venueName} to them
      </button>
      <button
        type="button"
        disabled={saving || trimmed === ""}
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
