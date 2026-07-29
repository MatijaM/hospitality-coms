/**
 * What the employer surface holds, and how it is written on screen.
 *
 * Three shapes, all of them `HospitalityComsWeb.EmployerController`'s render
 * functions in this client's camelCase. Every one of them is a **field list on
 * both sides**: the controller renders one because `Engagement` and
 * `Invitation` carry columns no employer may see, and this file names exactly
 * the same fields so that a column the server starts sending has nowhere to
 * arrive. `decode.ts` is where that is enforced and `decode.test.ts` is where
 * it is pinned.
 *
 * ## What is not here is the point of the surface
 *
 * There is **no `personId` and no email**, on any of these, because there is
 * none on the wire — `render_engagement/1` is `{engagement_id, role_label,
 * starts_at, ends_at}` and `people` has exactly one identifying column, which
 * no employer route touches. And there is **no `claimCodeDigest`**: the row
 * keeps only a SHA-256 of the code, `render_invitation/1` withholds even that,
 * and the plaintext arrives **beside** the invitation rather than inside it,
 * which is the shape saying it is not a property of the row.
 *
 * A worker on this surface is therefore a role label, a term, and an engagement
 * id that means nothing at any other venue. The interface says so rather than
 * papering over it.
 */

import { instantLabel, termLabel } from "../../app/instant";
import type { ShiftRoomListing } from "../../app/shift-room";

/** `%{venue_id:, name:}` — one venue this session may act for. */
export type ManagedVenue = {
  readonly venueId: string;
  readonly name: string;
};

/**
 * `%{engagement_id:, role_label:, starts_at:, ends_at:}` — one person engaged
 * at the venue, at the instant the request was answered.
 *
 * "At the instant" is not decoration: `list_engagements/1` returns the venue's
 * engagements **active now**, nothing stores membership, and the same request a
 * minute after a term's upper bound answers a shorter list with no job having
 * run. So this is never cached and the surface offers a reload rather than
 * pretending the list is stable.
 */
export type VenueEngagement = {
  readonly engagementId: string;
  readonly roleLabel: string;
  readonly startsAt: string;
  readonly endsAt: string;
};

/** `%{invitation_id:, role_label:, starts_at:, ends_at:, code_expires_at:}`. */
export type OfferedInvitation = {
  readonly invitationId: string;
  readonly roleLabel: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly codeExpiresAt: string;
};

/**
 * The whole `201` of `POST /api/employer/venues/:venue_id/invitations`.
 *
 * `claimCode` is plaintext and this response is the only place it will ever
 * exist. Nothing stores it here — not the token store, not the room store, not
 * a URL — so it lives exactly as long as the component holding it, which is
 * what makes "dismissing it loses it" true rather than merely displayed.
 */
export type IssuedOffer = {
  readonly invitation: OfferedInvitation;
  readonly claimCode: string;
};

/**
 * How one engaged person is named on screen: the role, then the term.
 *
 * The role label is the employer's own words and the term is two instants; put
 * together they are everything this API discloses about a worker, and writing
 * them as one string is what stops the engagement id becoming the way a row is
 * recognised.
 *
 * `termLabel` is `src/app/instant.ts`'s, deliberately shared: a term rendered
 * one way beside a shift room and another way beside an engagement would be one
 * product speaking twice. It was the rooms surface's until this surface became
 * its second caller, which is what moved it.
 */
export function engagementLabel(engagement: VenueEngagement): string {
  return `${engagement.roleLabel} · ${termLabel(engagement.startsAt, engagement.endsAt)}`;
}

/** The same, for the offer that has not been claimed yet. */
export function offerLabel(invitation: OfferedInvitation): string {
  return `${invitation.roleLabel} · ${termLabel(invitation.startsAt, invitation.endsAt)}`;
}

/**
 * When a claim code stops working, written for a person.
 *
 * The server defaults it to seven days out and bounds it at fourteen; neither
 * number is computed here, and this client must not start computing one —
 * `HospitalityComs.Clock` is offsettable and moves the server's instant while
 * this browser's stays real, so anything derived from a comparison against
 * `Date.now()` would be wrong during exactly the demo the offset exists for.
 * The instant is rendered and never compared, which is the rule
 * `ShiftRoomListing.closesAt` already carries.
 */
export function expiryLabel(invitation: OfferedInvitation): string {
  return instantLabel(invitation.codeExpiresAt);
}

/**
 * `%{shift_type_id:, name:, grace_period_minutes:}` — one kind of shift this
 * venue runs.
 *
 * `venue_id` is not on the wire because the caller named it in the path, and a
 * shift type has no other field. The grace **is** on the wire, and
 * `render_shift_type/1` says why: *"it is the only thing that distinguishes two
 * types with similar names, and … it is what a manager is choosing between."*
 */
export type ShiftType = {
  readonly shiftTypeId: string;
  readonly name: string;
  readonly gracePeriodMinutes: number;
};

/**
 * `%{shift_rooms: [...], complete:}` — one page of the venue's shifts.
 *
 * **`complete` is the server's answer and cannot be derived here**, for
 * `MessagePage`'s reason: a full page and a full history of the same length are
 * the same list. It is what decides whether the "load every shift" control
 * exists, so offering that control unconditionally would tell a manager with
 * three shifts that there are more.
 *
 * The page's rooms are the venue's **most recent**, oldest first within the
 * page. That ordering is `Records.most_recent_rooms/2`'s — a descending scan
 * re-ordered ascending in SQL around it — and nothing here re-sorts: a limit
 * applied to the rota's own order returns the venue's oldest rooms, satisfies
 * every count assertion, and hides the shift the manager just created.
 */
export type ShiftRoomPage = {
  readonly rooms: readonly ShiftRoomListing[];
  readonly complete: boolean;
};

/**
 * `%{engagement_id:, role_label:, joined_at:}` — one live entry on a shift's
 * roster.
 *
 * **`roleLabel` comes off the server and could not be joined here.**
 * `RosterEntry` carries no label, so U3 preloaded the engagement and
 * `render_roster_entry/1` projects it (KTD-E10). The alternative was joining
 * against the venue's people list, which has a hole that only shows in use:
 * `add_to_roster/3` accepts an engagement whose term has **not opened** while
 * `list_engagements/1` answers only with engagements active at the instant, so
 * next Monday's starter on next Tuesday's rota would render as a bare uuid.
 *
 * There is no `personId` — the render is a field list off a struct that carries
 * one — and no entry id, because no route takes one: a removal names the
 * engagement.
 */
export type RosterEntry = {
  readonly engagementId: string;
  readonly roleLabel: string;
  readonly joinedAt: string;
};

/** How a shift type reads in the picker: the name, then what tells two apart. */
export function shiftTypeLabel(type: ShiftType): string {
  return `${type.name} · ${type.gracePeriodMinutes} min grace`;
}

/** How one rostered person reads: the role, then when the entry opened. */
export function rosterEntryLabel(entry: RosterEntry): string {
  return `${entry.roleLabel} · on since ${instantLabel(entry.joinedAt)}`;
}

/**
 * The instant a `datetime-local` value names, or `null` if it names none.
 *
 * ## This is the only place this client produces an instant, and it is not a clock
 *
 * Everything else here *renders* an instant and never computes with one, which
 * is `src/app/instant.ts`'s rule and KTD5's. This is the exception and it is a
 * narrow one: `POST …/shift-rooms` has **no server-side defaults** — the
 * controller's `@term_fields` is `~w(starts_at ends_at)` with no `Map.put_new`,
 * unlike the invitation's three — because a shift *is* a term somebody chose.
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
