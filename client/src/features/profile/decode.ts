/**
 * Turning the profile channel's payloads into the types this surface renders.
 *
 * Same posture as `src/api/decode.ts`, `features/rooms/decode.ts` and
 * `features/peers/decode.ts`: every decoder answers `null` for "this is not
 * that", never a partial value and never a throw. Keys are the wire's
 * snake_case, the types are camelCase, and this file is the only place the two
 * meet.
 *
 * ## These shapes were derived, not read off a channel
 *
 * The other three slices could say "read out of the channel module, not
 * inferred from prose". This one cannot: **no channel emits any of this**, and
 * `contract.ts` is the whole of why. What each field *is* comes from
 * `HospitalityComs.Profiles` and its four render/schema modules, which are
 * settled; what each field is *called on the wire* is `contract.ts`'s ask.
 *
 * That difference is why the decoders here are, if anything, stricter than the
 * peers': for the peer surface a decode failure means the server drifted, and
 * here it means the transport was written to a different contract than this
 * file. Both are worth a named absence rather than `undefined` in a heading,
 * and the second is worth one loudly.
 *
 * ## Nullability is taken from the database, field by field
 *
 * Nothing is optional because it looked optional. `venues.name` and
 * `engagements.role_label` are `null: false`; `VisibleEntry` types every one of
 * its eight fields as non-nullable; `VisibleCorrection` types exactly two as
 * nullable (`resolved_at` and `resolution`) and
 * `correction_requests_resolution_complete` pairs them with `IS NULL` on both
 * sides — so `decodeCorrectionRequest` refuses the two half-states rather than
 * trusting a constraint on the far side of a transport this client cannot see.
 */

import { isRecord } from "../../api/decode";
import type {
  AttestedEntry,
  AudienceKind,
  CorrectionRequest,
  DeclaredEntry,
  Disclosure,
  Profile,
  Resolution,
} from "./profile";
import { AUDIENCE_KINDS, RESOLUTIONS } from "./profile";

/** Every entry or nothing: a list with one bad row is not a shorter list. */
function decodeList<Value>(
  value: unknown,
  decode: (entry: unknown) => Value | null,
): readonly Value[] | null {
  if (!Array.isArray(value)) return null;

  const decoded: Value[] = [];

  for (const entry of value) {
    const one = decode(entry);
    if (one === null) return null;
    decoded.push(one);
  }

  return decoded;
}

/**
 * `%{person_id:, incompleteness_notice:}` — the join reply.
 *
 * The notice is required rather than optional, and that is the point of it
 * arriving here at all. `Profiles.incompleteness_notice/0` is arity zero so it
 * cannot depend on the worker it is shown beside; a transport that carried it
 * per profile would make it arity one however carefully the server computed it,
 * and nothing on this side could tell that it had not.
 *
 * Taking it from the join is what makes that structural: a join reply is about
 * the session, and no profile read can influence one. So the string this client
 * renders beside a worker with three concealed entries is the *same object*
 * it renders beside one who has never worked anywhere else.
 */
export function decodeJoinedProfile(
  payload: unknown,
): { readonly personId: string; readonly incompletenessNotice: string } | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.person_id !== "string") return null;
  if (typeof payload.incompleteness_notice !== "string") return null;

  return {
    personId: payload.person_id,
    incompletenessNotice: payload.incompleteness_notice,
  };
}

/**
 * `%{attested_entry_id:, entry_engagement_id:, venue_id:, venue_name:,
 * role_label:, starts_at:, ends_at:, attested_at:}` — `VisibleEntry`.
 *
 * All eight required and none nullable, which is `VisibleEntry.t()` field for
 * field. `@enforce_keys` on that struct turns a `select:` that dropped a field
 * into a `KeyError` at the Elixir boundary; this is the same check on this one.
 */
export function decodeAttestedEntry(payload: unknown): AttestedEntry | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.attested_entry_id !== "string") return null;
  if (typeof payload.entry_engagement_id !== "string") return null;
  if (typeof payload.venue_id !== "string") return null;
  if (typeof payload.venue_name !== "string") return null;
  if (typeof payload.role_label !== "string") return null;
  if (typeof payload.starts_at !== "string") return null;
  if (typeof payload.ends_at !== "string") return null;
  if (typeof payload.attested_at !== "string") return null;

  return {
    attestedEntryId: payload.attested_entry_id,
    entryEngagementId: payload.entry_engagement_id,
    venueId: payload.venue_id,
    venueName: payload.venue_name,
    roleLabel: payload.role_label,
    startsAt: payload.starts_at,
    endsAt: payload.ends_at,
    attestedAt: payload.attested_at,
  };
}

/**
 * `%{declared_entry_id:, role_label:, organisation_name:, starts_at:, ends_at:,
 * declared_at:}` — a rendered `DeclaredEntry`.
 *
 * `declared_entry_id` and not `id`: the schema says `id` because it has no
 * render struct, and `contract.ts` asks the transport for the rendered
 * spelling. Refusing `id` here rather than accepting either is deliberate — a
 * decoder that took both would let the two spellings coexist, which is exactly
 * how one entity ends up with two key names.
 */
export function decodeDeclaredEntry(payload: unknown): DeclaredEntry | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.declared_entry_id !== "string") return null;
  if (typeof payload.role_label !== "string") return null;
  if (typeof payload.organisation_name !== "string") return null;
  if (typeof payload.starts_at !== "string") return null;
  if (typeof payload.ends_at !== "string") return null;
  if (typeof payload.declared_at !== "string") return null;

  return {
    declaredEntryId: payload.declared_entry_id,
    roleLabel: payload.role_label,
    organisationName: payload.organisation_name,
    startsAt: payload.starts_at,
    endsAt: payload.ends_at,
    declaredAt: payload.declared_at,
  };
}

/**
 * `%{correction_request_id:, entry_engagement_id:, venue_id:, body:,
 * requested_at:, resolved_at:, resolution:}` — `VisibleCorrection`.
 *
 * **The two nullable fields are decoded as a pair, not independently.**
 * `correction_requests_resolution_complete` says a resolved request carries
 * both and an outstanding one carries neither, and this refuses the two
 * half-states the constraint forbids. A decoder that took them separately would
 * accept `resolved_at` with a null `resolution` and render "Waiting for an
 * answer" beside an instant saying it was answered.
 *
 * `resolution` is narrowed against `RESOLUTIONS` rather than taken as any
 * string, for `decodePeerRequest`'s reason: everything the surface says about a
 * resolution switches on it, and a value with no case would fall out of an
 * exhaustive switch.
 */
export function decodeCorrectionRequest(payload: unknown): CorrectionRequest | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.correction_request_id !== "string") return null;
  if (typeof payload.entry_engagement_id !== "string") return null;
  if (typeof payload.venue_id !== "string") return null;
  if (typeof payload.body !== "string") return null;
  if (typeof payload.requested_at !== "string") return null;

  const resolved = decodeResolution(payload.resolved_at, payload.resolution);
  if (resolved === null) return null;

  return {
    correctionRequestId: payload.correction_request_id,
    entryEngagementId: payload.entry_engagement_id,
    venueId: payload.venue_id,
    body: payload.body,
    requestedAt: payload.requested_at,
    resolvedAt: resolved.resolvedAt,
    resolution: resolved.resolution,
  };
}

/** Both or neither, which is what the CHECK constraint says. */
function decodeResolution(
  resolvedAt: unknown,
  resolution: unknown,
): { readonly resolvedAt: string | null; readonly resolution: Resolution | null } | null {
  if (resolvedAt === null && resolution === null) {
    return { resolvedAt: null, resolution: null };
  }

  if (typeof resolvedAt !== "string") return null;

  const known: Resolution | undefined = RESOLUTIONS.find(
    (candidate) => candidate === resolution,
  );
  if (known === undefined) return null;

  return { resolvedAt, resolution: known };
}

/**
 * `%{disclosure_id:, engagement_id:, audience_kind:, audience_id:, disclosed:,
 * decided_at:}` — a rendered `Disclosure`.
 *
 * `audience_kind` plus `audience_id` rather than the table's two nullable
 * columns. The table spells one audience as `audience_venue_id XOR
 * audience_person_id`, which a wire shape would have to be validated for; the
 * tagged pair cannot express "both" or "neither" at all, and it is the same
 * spelling `set_disclosure` sends — so this entity has one set of key names in
 * both directions. See `contract.ts`.
 */
export function decodeDisclosure(payload: unknown): Disclosure | null {
  if (!isRecord(payload)) return null;
  if (typeof payload.disclosure_id !== "string") return null;
  if (typeof payload.engagement_id !== "string") return null;
  if (typeof payload.audience_id !== "string") return null;
  if (typeof payload.disclosed !== "boolean") return null;
  if (typeof payload.decided_at !== "string") return null;

  const audienceKind: AudienceKind | undefined = AUDIENCE_KINDS.find(
    (candidate) => candidate === payload.audience_kind,
  );
  if (audienceKind === undefined) return null;

  return {
    disclosureId: payload.disclosure_id,
    engagementId: payload.engagement_id,
    audienceKind,
    audienceId: payload.audience_id,
    disclosed: payload.disclosed,
    decidedAt: payload.decided_at,
  };
}

/** `%{disclosures: [...]}` — the reply to `list_disclosures`. */
export function decodeDisclosures(payload: unknown): readonly Disclosure[] | null {
  if (!isRecord(payload)) return null;

  return decodeList(payload.disclosures, decodeDisclosure);
}

/**
 * `%{attested_entries: [...], declared_entries: [...], correction_requests: [...]}`
 * — the reply to `profile` and to `peer_profile`.
 *
 * **One decoder for both readers, and that is load-bearing rather than
 * economical.** `own_profile/1` and `fetch_peer_profile/2` build the same three
 * lists of the same structs; U9's own verification is a comparison of two lists
 * of one struct for exactly that reason. A second decoder here would be a place
 * for the two readings to drift, and the shape a viewer sees is the shape the
 * worker sees minus rows — never minus or plus a *field*.
 *
 * There is deliberately no `hidden_count`, no `total`, and no notice on this
 * reply. A field whose value depended on what was withheld would be the oracle
 * `incompleteness_notice/0`'s arity exists to prevent, and it would be one this
 * client had asked for.
 */
export function decodeProfile(payload: unknown): Profile | null {
  if (!isRecord(payload)) return null;

  const attestedEntries = decodeList(payload.attested_entries, decodeAttestedEntry);
  if (attestedEntries === null) return null;

  const declaredEntries = decodeList(payload.declared_entries, decodeDeclaredEntry);
  if (declaredEntries === null) return null;

  const correctionRequests = decodeList(
    payload.correction_requests,
    decodeCorrectionRequest,
  );
  if (correctionRequests === null) return null;

  return { attestedEntries, declaredEntries, correctionRequests };
}
