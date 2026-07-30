/**
 * What a profile is to this client: two kinds of entry, a contest, and a ledger
 * of decisions that is **not** an answer to "who can see this".
 *
 * The wire shapes are `contract.ts`'s and nothing on the server emits them yet.
 * What is settled is `HospitalityComs.Profiles`' own vocabulary, which is what
 * this file names.
 *
 * ## Two kinds of entry, and only one of them is the worker's word (R16)
 *
 * An **attested** entry is an employer's assertion that an engagement happened.
 * It is written inside the claim's transaction and by nothing else, and **a
 * person cannot edit one** — `Profiles` exports no function that would, and
 * `profiles_test.exs` pins the module's whole export list against a literal so
 * that `edit_entry/3` cannot appear later. The remedy is a correction request,
 * and resolving one writes no entry either: an attested entry derives from its
 * engagement, so accepting is an acknowledgement and any real correction is a
 * change to the engagement.
 *
 * A **declared** entry is the worker's own statement about work this
 * application knows nothing about. They write it, amend it, and are the only
 * one who can. It has no venue and no engagement behind it — that absence *is*
 * the distinction — and it carries no disclosure ledger at all, because
 * publishing it is what writing it means.
 *
 * ## The ledger holds overrides, and this client must not read it as more
 *
 * `attested_entry_disclosures` stores **the worker's departures from the
 * default** and nothing else. Both defaults are computed server-side from
 * periods that are already stored, and neither is on the wire:
 *
 *   * for an **employer** audience, an entry attested by venue A is hidden from
 *     venue B when the engagement it attests *overlapped* any engagement the
 *     same person held at venue B — computed inside
 *     `employer_visible_attested_entries`, over two stored periods, naming no
 *     instant;
 *   * for a **peer** audience, an entry is disclosed unless the worker said
 *     otherwise **and** unless a venue that binds that peer would hide it,
 *     which is the same overlap rule reached through `Records.concealed_from/3`.
 *
 * So a client holding the ledger knows which decisions the worker has *taken*
 * and cannot compute who can currently see anything. `disclosureState` says
 * exactly that and returns `"default"` where there is no row — see its own
 * note, and `README.md`'s "What the profile surface cannot render".
 *
 * ## The incompleteness notice is a constant and arrives once
 *
 * `Profiles.incompleteness_notice/0` is arity zero so it cannot become an
 * oracle naming which workers conceal something. It reaches this client on the
 * **join reply** and never on a profile reply, which is arity zero expressed on
 * a transport — see `contract.ts`. Nothing in this file derives it, and nothing
 * anywhere derives anything else from what a profile does not contain.
 */

import { shortId } from "../../app/short-id";
import { PROFILE_TOPIC_PREFIX } from "./contract";

export { normaliseTopicId as normalisePersonId } from "../../socket/topic-id";

/** Joined as `profile:<person_id>`, the session's own person. */
export function profileTopic(personId: string): string {
  return `${PROFILE_TOPIC_PREFIX}${personId}`;
}

/**
 * `HospitalityComs.Profiles.VisibleEntry`: one attested entry as it is rendered
 * to somebody entitled to see it.
 *
 * **No `person_id`, and that absence is U9 acting on a recorded disclosure.**
 * `engagements.person_id` is a globally stable UUID that `employer_role` can
 * read, so two venues comparing ids out of band could determine that the same
 * human works at both — which is precisely the concurrency the disclosure
 * default exists to hide. The employer names a worker by *their own*
 * engagement, and the entries that come back name venues.
 *
 * `entryEngagementId` identifies the entry's engagement so that a correction
 * request can be attached to it and a disclosure decision can name it. It is
 * **not** venue-local: two venues reading the same worker's third-venue entry
 * get the same value. `VisibleEntry`'s moduledoc corrected an earlier claim
 * that it was, and this client does not restate the mistake.
 */
export type AttestedEntry = {
  readonly attestedEntryId: string;
  readonly entryEngagementId: string;
  readonly venueId: string;
  readonly venueName: string;
  readonly roleLabel: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly attestedAt: string;
};

/**
 * `HospitalityComs.Profiles.DeclaredEntry`, rendered.
 *
 * `declaredEntryId` is `contract.ts`'s ask rather than the schema's `id`: three
 * of U9's five shapes are Ecto schemas with no render struct, and putting `id`
 * on a wire where two other entities say `<entity>_id` is the defect class this
 * project has fixed twice.
 *
 * `declaredAt` is untouched by an amendment — amending a statement is not
 * re-declaring it — so it and `updatedAt` would answer different questions.
 * Only `declaredAt` is rendered: this surface has no use for the second and
 * asking for a field nothing consumes is how an employer-facing column survives
 * by default, which `boundary_test.exs` pins the views against.
 */
export type DeclaredEntry = {
  readonly declaredEntryId: string;
  readonly roleLabel: string;
  readonly organisationName: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly declaredAt: string;
};

/** The two answers an employer may give, and the only two the CHECK admits. */
export type Resolution = "accepted" | "declined";

export const RESOLUTIONS: readonly Resolution[] = ["accepted", "declined"];

/**
 * `HospitalityComs.Profiles.VisibleCorrection`: a worker's contest of an
 * employer's assertion, and the employer's answer if there is one.
 *
 * `resolution` is `null` until it is answered, and
 * `correction_requests_resolution_complete` pairs `resolved_at` and
 * `resolution` with `IS NULL` on both sides — so a resolved request always says
 * when *and* how, and an outstanding one says neither. The decoder holds both
 * halves rather than trusting the constraint, because a constraint on the other
 * side of a transport this client cannot see is not a guarantee this client
 * has.
 */
export type CorrectionRequest = {
  readonly correctionRequestId: string;
  readonly entryEngagementId: string;
  readonly venueId: string;
  readonly body: string;
  readonly requestedAt: string;
  readonly resolvedAt: string | null;
  readonly resolution: Resolution | null;
};

/** Who a decision is about: one venue, or one other person. */
export type AudienceKind = "venue" | "person";

export const AUDIENCE_KINDS: readonly AudienceKind[] = ["venue", "person"];

/**
 * One decision the worker has taken about one entry and one audience.
 *
 * `engagementId` is the entry's `entryEngagementId`: an attested entry is an
 * employer-zone row and a person-zone table pointing at one would reach across
 * the boundary for no gain, so the ledger names the engagement, which
 * `attested_entries.engagement_id` makes unique.
 *
 * There is **one row per (entry, audience)** — two partial unique indexes say
 * so — and deciding twice replaces the answer rather than adding a second row.
 * So `disclosureState` can look a decision up rather than fold a history.
 */
export type Disclosure = {
  readonly disclosureId: string;
  readonly engagementId: string;
  readonly audienceKind: AudienceKind;
  readonly audienceId: string;
  readonly disclosed: boolean;
  readonly decidedAt: string;
};

/**
 * The three lists a reader gets, whoever they are.
 *
 * `own_profile/1` and `fetch_peer_profile/2` build the same shape, which is
 * what makes U9's own verification a comparison of two lists of one struct.
 * **The ledger is not part of it**, and there is no event that would hand a
 * viewer somebody else's: what a worker has decided about their own record is
 * theirs.
 */
export type Profile = {
  readonly attestedEntries: readonly AttestedEntry[];
  readonly declaredEntries: readonly DeclaredEntry[];
  readonly correctionRequests: readonly CorrectionRequest[];
};

export const EMPTY_PROFILE: Profile = {
  attestedEntries: [],
  declaredEntries: [],
  correctionRequests: [],
};

/**
 * What this client can honestly say about one entry and one audience.
 *
 * Three values, and `"default"` is the important one. The ledger holds the
 * worker's **overrides**; both defaults are applied server-side from stored
 * periods and appear on no wire this client reads. So the absence of a row
 * means "you have not decided about this audience", which is *not* the same
 * claim as "they can see it" and must never be rendered as one.
 *
 * Getting that wrong is not cosmetic. The employer default hides an entry
 * exactly where the worker's terms overlapped, so a surface that showed
 * "Visible" for every audience with no row would tell a worker their second job
 * was disclosed to the venue it is in fact hidden from — and the decision they
 * would then not take is the one the whole unit exists to let them take.
 */
export type DisclosureState = "shown" | "hidden" | "default";

export function disclosureState(
  disclosures: readonly Disclosure[],
  entry: AttestedEntry,
  audienceKind: AudienceKind,
  audienceId: string,
): DisclosureState {
  const decision = disclosures.find(
    (one) =>
      one.engagementId === entry.entryEngagementId &&
      one.audienceKind === audienceKind &&
      one.audienceId === audienceId,
  );

  if (decision === undefined) return "default";

  return decision.disclosed ? "shown" : "hidden";
}

/** Every decision taken about one entry, whatever the audience. */
export function decisionsFor(
  disclosures: readonly Disclosure[],
  entry: AttestedEntry,
): readonly Disclosure[] {
  return disclosures.filter((one) => one.engagementId === entry.entryEngagementId);
}

export function disclosureStateLabel(state: DisclosureState): string {
  switch (state) {
    case "shown":
      return "Shown";
    case "hidden":
      return "Hidden";
    case "default":
      return "Not decided";
  }
}

export function audienceKindLabel(kind: AudienceKind): string {
  switch (kind) {
    case "venue":
      return "Employer";
    case "person":
      return "Peer";
  }
}

export function resolutionLabel(resolution: Resolution | null): string {
  if (resolution === null) return "Waiting for an answer";

  switch (resolution) {
    case "accepted":
      return "Accepted";
    case "declined":
      return "Declined";
  }
}

/**
 * What a resolution means, in a sentence.
 *
 * `accepted` is the one worth spelling out: it changes no entry and cannot.
 * A worker told "Accepted" beside an entry that still reads the same way would
 * reasonably think the system had failed them, when what actually happened is
 * that the acknowledgement and the correction are two different acts.
 */
export function resolutionMessage(resolution: Resolution | null): string {
  if (resolution === null) {
    return "The venue that made this assertion has not answered yet.";
  }

  switch (resolution) {
    case "accepted":
      return "They agreed. That is an acknowledgement and not an edit — an attested entry follows its engagement, so if they change anything it is the engagement that changes and this entry follows it.";
    case "declined":
      return "They said no. The entry and this request both stay readable to everyone who can see the entry, so a refusal cannot make a contest disappear.";
  }
}

/**
 * How long an id is shown for. Never a name: there is no name on the wire.
 *
 * Hoisted to `src/app/short-id.ts` on its third caller, with `peer.ts`'s
 * identical copy — see there. Re-exported so no profile call site moved.
 */
export { shortId };
