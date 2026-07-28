/**
 * The whole profile surface on one subscription: the worker's own record, the
 * ledger of decisions they have taken about it, and one peer's record at a
 * time.
 *
 * **Nothing on the server answers any of these events.** `contract.ts` is the
 * one place that says so and the only place the event names are written.
 *
 * ## One hook because there is one topic
 *
 * Same shape as `usePeerSurface` and for the same reason: the topic is the
 * person, not the thing being read, so a second hook would be a second join of
 * one topic. A peer's profile is a **selection** rather than a join, exactly as
 * a conversation is.
 *
 * ## There are no announcements, and that is a fact about U9 rather than a gap
 *
 * `usePeerSurface` handles five pushes. This handles none, because
 * `HospitalityComs.Profiles` broadcasts nothing at all — every function in it
 * reads or writes and returns, and there is no `announce/2` anywhere in the
 * module. So the surface refreshes on its **own** actions and on a rejoin, and
 * a disclosure decision taken from another device is not seen until one of
 * those.
 *
 * Written down rather than papered over with a poll: the read is cheap and the
 * fix is a broadcast on the server, so a client-side timer here would be this
 * client compensating for a decision U9 has not taken.
 *
 * ## What a rejoin re-derives, and the one thing it deliberately does not
 *
 * `onJoined` re-asks the profile and the ledger, so a reconnect re-derives the
 * worker's own record. It does **not** re-ask the open peer profile.
 * `joinGeneration` is exported for that, exactly as it is for `PeerSurface`,
 * and `PeerProfileView` names it in the effect that loads one — so the re-fetch
 * belongs to the component that knows whose profile is open, and there is one
 * of those rather than a cache of every peer ever looked at.
 *
 * ## The ledger is asked for separately, and it is not folded into the profile
 *
 * `own_profile/1` answers three lists and `list_disclosures/1` answers the
 * ledger; they are two events here because they are two functions there, and
 * because `set_disclosure` needs to re-ask one of them and not the other.
 *
 * The consequence is worth stating: the two are read at two instants, so a
 * decision taken between them shows in one and not the other for one render.
 * It is harmless — the ledger is what the disclosure controls read, and an
 * entry with no decision renders "Not decided", which is the truth in both
 * readings — and folding them into one event to avoid it would make every
 * disclosure decision re-read the whole record.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { decodeChannelRefusal } from "../../socket/channel-failure";
import type { PushOutcome, TopicSubscription } from "../../socket/session-socket";
import { useSessionSocket } from "../../socket/socket-context";
import { PROFILE_EVENTS } from "./contract";
import {
  decodeCorrectionRequest,
  decodeDeclaredEntry,
  decodeDisclosure,
  decodeDisclosures,
  decodeJoinedProfile,
  decodeProfile,
} from "./decode";
import type {
  AudienceKind,
  CorrectionRequest,
  DeclaredEntry,
  Disclosure,
  Profile,
} from "./profile";
import { EMPTY_PROFILE, normalisePersonId, profileTopic } from "./profile";
import type { ProfileAction, ProfileFailure, ProfileNotice } from "./refusal-message";
import { PROFILE_ERROR_CODES, endsSession } from "./refusal-message";

export type ProfileConnection =
  /** No transport: nobody is signed in, or the socket has not been built. */
  | { readonly status: "no_socket" }
  /**
   * The session's own person id is not an id.
   *
   * It comes from `GET /api/me`, so this cannot happen against this API. It is
   * a state rather than a `throw` for `PeerConnection`'s reason: the
   * alternative to a sentence is a blank surface, and the topic must not be
   * built from it either way.
   */
  | { readonly status: "no_person" }
  | { readonly status: "joining" }
  | {
      readonly status: "joined";
      readonly personId: string;
      /**
       * `Profiles.incompleteness_notice/0`, taken from the **join reply**.
       *
       * It lives on the connection and not beside a profile because that is
       * arity zero expressed as state: a value held per session cannot vary
       * per subject, so no rendering of it can become the oracle a computed
       * "this record has hidden entries" flag would be.
       */
      readonly incompletenessNotice: string;
    }
  | { readonly status: "refused"; readonly failure: ProfileFailure }
  | { readonly status: "timed_out" };

/**
 * What an action came back with.
 *
 * `value` is nullable on the success path on purpose, as it is for
 * `PeerOutcome`: the server accepted the event, and a reply this client cannot
 * decode does not un-accept it. What is affected is re-read either way.
 */
export type ProfileOutcome<Value> =
  | { readonly status: "ok"; readonly value: Value | null }
  | { readonly status: "refused"; readonly failure: ProfileFailure }
  /** The subscription was gone before the push went out. Nothing was sent. */
  | { readonly status: "unsent" };

/** What `declare_entry` and `amend_declared_entry` carry. */
export type DeclaredEntryDraft = {
  readonly roleLabel: string;
  readonly organisationName: string;
  readonly startsAt: string;
  readonly endsAt: string;
};

export type ProfileSurface = {
  readonly connection: ProfileConnection;
  /** The worker's own record, unfiltered: concealed entries included. */
  readonly own: Profile;
  /** Their decisions, which are overrides and not an answer to "who sees it". */
  readonly disclosures: readonly Disclosure[];
  /** How many times this surface has been admitted. See the header. */
  readonly joinGeneration: number;
  /** One at a time, and always the most recent. Rendered in one place. */
  readonly notice: ProfileNotice | null;
  readonly clearNotice: () => void;
  readonly setDisclosure: (
    engagementId: string,
    audienceKind: AudienceKind,
    audienceId: string,
    disclosed: boolean,
  ) => Promise<ProfileOutcome<Disclosure>>;
  /**
   * The three writes carry back **what the server says it wrote**, one entity
   * each, which is `contract.ts`'s reply for each of them.
   *
   * They were typed `ProfileOutcome<Profile>` against a decoder of `() => null`
   * — a type naming a shape none of the three replies has, over a value that
   * was always absent. Neither half was true, and the pair is this project's
   * standing defect: a declaration disagreeing with the code beneath it.
   */
  readonly declareEntry: (
    draft: DeclaredEntryDraft,
  ) => Promise<ProfileOutcome<DeclaredEntry>>;
  readonly amendDeclaredEntry: (
    declaredEntryId: string,
    draft: DeclaredEntryDraft,
  ) => Promise<ProfileOutcome<DeclaredEntry>>;
  readonly requestCorrection: (
    engagementId: string,
    body: string,
  ) => Promise<ProfileOutcome<CorrectionRequest>>;
  readonly loadPeerProfile: (personId: string) => Promise<ProfileOutcome<Profile>>;
};

const NO_SOCKET: ProfileConnection = { status: "no_socket" };
const NO_PERSON: ProfileConnection = { status: "no_person" };
const JOINING: ProfileConnection = { status: "joining" };
const NO_DISCLOSURES: readonly Disclosure[] = [];

export function useProfileSurface(personId: string): ProfileSurface {
  const socket = useSessionSocket();
  // Normalised here rather than at the caller, because this is the only place
  // that turns it into a topic. See `src/socket/topic-id.ts`.
  const ownId = normalisePersonId(personId);
  const topic = ownId === null ? null : profileTopic(ownId);

  const [joinState, setJoinState] = useState<ProfileConnection>(JOINING);
  const [joinGeneration, setJoinGeneration] = useState(0);
  const [own, setOwn] = useState<Profile>(EMPTY_PROFILE);
  const [disclosures, setDisclosures] = useState<readonly Disclosure[]>(NO_DISCLOSURES);
  const [notice, setNotice] = useState<ProfileNotice | null>(null);

  // Derived rather than stored, as `usePeerSurface` derives `no_socket`:
  // storing it would need a write from the effect body to get in and another
  // to get out.
  const connection: ProfileConnection =
    ownId === null ? NO_PERSON : socket === null ? NO_SOCKET : joinState;

  const subscription = useRef<TopicSubscription | null>(null);

  // Each loader takes the subscription rather than reading the ref, because
  // the ones the join fires run while the ref is still being assigned — `join`
  // returns the subscription and the effect stores it on the next line.
  const loadOwn = useCallback(async (open: TopicSubscription): Promise<void> => {
    const outcome = await open.push(PROFILE_EVENTS.ownProfile, {});

    if (outcome.status !== "ok") {
      report("profile", outcome, setNotice);

      return;
    }

    const decoded = decodeProfile(outcome.payload);

    // A named absence rather than a silent no-op. Leaving the previous record
    // on screen under no explanation would be a surface asserting something
    // the server has stopped saying — and on this surface "nothing here" is
    // also a meaningful claim about somebody's working life, so it must never
    // be a failure mode that renders as an answer.
    if (decoded === null) {
      setNotice({ kind: "malformed_reply", action: "profile" });

      return;
    }

    setOwn(decoded);
  }, []);

  const loadDisclosures = useCallback(async (open: TopicSubscription): Promise<void> => {
    const outcome = await open.push(PROFILE_EVENTS.listDisclosures, {});

    if (outcome.status !== "ok") {
      report("disclosures", outcome, setNotice);

      return;
    }

    const decoded = decodeDisclosures(outcome.payload);

    if (decoded === null) {
      setNotice({ kind: "malformed_reply", action: "disclosures" });

      return;
    }

    setDisclosures(decoded);
  }, []);

  useEffect(() => {
    if (socket === null || topic === null) return;

    let open: TopicSubscription | null = null;

    open = socket.join(topic, {
      // No `events`. `HospitalityComs.Profiles` broadcasts nothing — see the
      // header. An empty map rather than an omitted key would say the same
      // thing less loudly than this comment does.
      onJoined: (payload) => {
        const joined = decodeJoinedProfile(payload);

        setJoinState(
          joined === null
            ? // The join was admitted, so the surface works; only the notice is
              // missing. Falling back to a client-side constant was the
              // alternative and is worse: two copies of one sentence in two
              // languages, drifting, with nothing to say which is current.
              // Rendering no notice is honest and visible.
              { status: "joined", personId: ownId ?? "", incompletenessNotice: "" }
            : {
                status: "joined",
                personId: joined.personId,
                incompletenessNotice: joined.incompletenessNotice,
              },
        );
        setJoinGeneration((previous) => previous + 1);

        if (joined === null) setNotice({ kind: "malformed_reply", action: "join" });

        if (open === null) return;

        void loadOwn(open);
        void loadDisclosures(open);
      },
      onRefused: (payload) => {
        // `createSessionSocket` has already left the topic: a refusal is a
        // decision, and there is nothing here that asks again.
        const failure = decodeChannelRefusal(payload, PROFILE_ERROR_CODES);
        setJoinState({ status: "refused", failure });

        // `unauthorized` is the server saying it re-derived this session and
        // does not have it. The record must not stay on screen.
        //
        // Fourth shared-terminal finding this client has acted on, and the
        // sharpest of the four: a room bookmark names a venue, a peer graph
        // names who somebody knows, and this names every term they have
        // served, every venue that asserted one, every contest they have
        // raised, and every entry they chose to conceal. The ledger is the
        // worst of it — it is the list of what somebody did not want seen.
        //
        // It clears what is rendered and does not touch the session, which is
        // the same restraint `usePeerSurface` shows: whether this person is
        // still signed in is `GET /api/me`'s answer and `RequireSession`'s to
        // act on.
        if (!endsSession(failure)) return;

        setOwn(EMPTY_PROFILE);
        setDisclosures(NO_DISCLOSURES);
      },
      onTimeout: () => {
        setJoinState({ status: "timed_out" });
      },
    });

    subscription.current = open;
    const opened = open;

    return () => {
      opened.leave();
      subscription.current = null;
    };
  }, [socket, topic, ownId, loadOwn, loadDisclosures]);

  const run = useCallback(
    async <Value>(
      action: ProfileAction,
      event: string,
      payload: object,
      decode: (reply: unknown) => Value | null,
    ): Promise<ProfileOutcome<Value>> => {
      const open = subscription.current;
      if (open === null) return { status: "unsent" };

      setNotice(null);

      const outcome = await open.push(event, payload);

      switch (outcome.status) {
        case "ok":
          return { status: "ok", value: decode(outcome.payload) };
        case "error": {
          const failure = decodeChannelRefusal(outcome.payload, PROFILE_ERROR_CODES);
          setNotice({ kind: "refused", action, failure });

          return { status: "refused", failure };
        }
        case "timeout": {
          const failure: ProfileFailure = { kind: "channel_timeout" };
          setNotice({ kind: "refused", action, failure });

          return { status: "refused", failure };
        }
        case "unsent":
          return { status: "unsent" };
      }
    },
    [],
  );

  const refresh = useCallback(
    (which: { own?: boolean; disclosures?: boolean }) => {
      const open = subscription.current;
      if (open === null) return;

      if (which.own === true) void loadOwn(open);
      if (which.disclosures === true) void loadDisclosures(open);
    },
    [loadOwn, loadDisclosures],
  );

  /**
   * Records a decision about one entry and one audience.
   *
   * Re-asks **the ledger and not the record**, and the asymmetry is the whole
   * of what this event changes: a disclosure row governs what *others* see, and
   * the worker's own read is deliberately unfiltered — `list_attested_entries/1`
   * is explicit that a worker who could not see what they were hiding could not
   * decide about it. So re-reading the profile here would be a round trip that
   * cannot come back different.
   *
   * The reply is applied as well as re-asked, for the reason `usePeerSurface`
   * applies a send's reply: the two are idempotent and the re-ask is what makes
   * the surface right if the reply could not be decoded.
   */
  const setDisclosure = useCallback(
    async (
      engagementId: string,
      audienceKind: AudienceKind,
      audienceId: string,
      disclosed: boolean,
    ): Promise<ProfileOutcome<Disclosure>> => {
      const outcome = await run(
        "set_disclosure",
        PROFILE_EVENTS.setDisclosure,
        {
          engagement_id: engagementId,
          audience_kind: audienceKind,
          audience_id: audienceId,
          disclosed,
        },
        decodeDisclosure,
      );

      if (outcome.status === "ok") refresh({ disclosures: true });

      return outcome;
    },
    [run, refresh],
  );

  /**
   * Writes a declared entry, then re-reads the record.
   *
   * The reply is one entry and the surface renders a list, so unlike
   * `setDisclosure` there is nothing useful to apply directly: appending the
   * reply would put it at the end while `list_declared_entries/1` orders by
   * term, so the row would move on the next read for no reason anybody could
   * see.
   *
   * **It is decoded anyway, and that is the ask in `contract.ts` being checked
   * from this side rather than only written down.** No channel answers this
   * event, so the first thing a real transport will do wrong is answer it in a
   * shape this file did not describe — and the specific one `contract.ts`
   * argues at length against is a reply naming the entry `id`, which is what
   * the Ecto schema calls it and what a channel putting the schema on the wire
   * would send. `decodeDeclaredEntry` refuses that spelling, so it arrives as
   * `value: null` — a named absence — instead of as an entry.
   *
   * **Nothing is *reported* from here**, and that is `run`'s rule rather than
   * an omission: the server accepted the write and a reply this client cannot
   * read does not un-accept it. What makes the drift visible to the worker is
   * the re-read on the next line — `loadOwn` decodes every declared entry
   * through the same decoder and *does* raise a notice when it cannot. See
   * `ProfileOutcome` and `malformedReplyMessage`.
   */
  const declareEntry = useCallback(
    async (draft: DeclaredEntryDraft): Promise<ProfileOutcome<DeclaredEntry>> => {
      const outcome = await run(
        "declare",
        PROFILE_EVENTS.declareEntry,
        draftPayload(draft),
        decodeDeclaredEntry,
      );

      if (outcome.status === "ok") refresh({ own: true });

      return outcome;
    },
    [run, refresh],
  );

  /** Changes one, and comes back with it. `declareEntry`'s reply, unchanged. */
  const amendDeclaredEntry = useCallback(
    async (
      declaredEntryId: string,
      draft: DeclaredEntryDraft,
    ): Promise<ProfileOutcome<DeclaredEntry>> => {
      const outcome = await run(
        "amend",
        PROFILE_EVENTS.amendDeclaredEntry,
        { declared_entry_id: declaredEntryId, ...draftPayload(draft) },
        decodeDeclaredEntry,
      );

      if (outcome.status === "ok") refresh({ own: true });

      return outcome;
    },
    [run, refresh],
  );

  /**
   * Contests an attested entry, and comes back with the request.
   *
   * `decodeCorrectionRequest` is `VisibleCorrection`'s decoder and not a
   * second one, which is the point: `contract.ts` asks the transport to render
   * a `VisibleCorrection` here rather than the `CorrectionRequest` schema its
   * `@spec` currently answers with, because otherwise the write path and the
   * four read paths are five shapes minus one. Decoding the reply with the
   * decoder the reads use is the only thing on this side that can tell whether
   * that ask was met.
   */
  const requestCorrection = useCallback(
    async (
      engagementId: string,
      body: string,
    ): Promise<ProfileOutcome<CorrectionRequest>> => {
      const outcome = await run(
        "correction",
        PROFILE_EVENTS.requestCorrection,
        { engagement_id: engagementId, body },
        decodeCorrectionRequest,
      );

      if (outcome.status === "ok") refresh({ own: true });

      return outcome;
    },
    [run, refresh],
  );

  /**
   * Reads one other person's profile.
   *
   * The answer is **returned rather than stored**, which is the one place this
   * hook parts company with `usePeerSurface`'s message cache — and it is the
   * shared-terminal rule applied ahead of a defect rather than after one. A
   * cache of every peer whose record has been opened is a list of other
   * people's working histories sitting in this tab, surviving every navigation,
   * with nothing but a log-out to clear it. There is no list this surface
   * renders from it, so there is nothing to buy with it.
   *
   * The consequence is that re-opening a peer's profile re-asks, which is also
   * what makes it correct: `fetch_peer_profile/2`'s gate is derived at the
   * instant of the event, so a viewer whose visibility lapsed between two
   * openings is refused on the second.
   */
  const loadPeerProfile = useCallback(
    async (id: string): Promise<ProfileOutcome<Profile>> => {
      const asked = normalisePersonId(id);

      // The server answers a malformed suffix exactly as it answers an id that
      // names nobody (AE1), which is right for the server and useless to
      // somebody who has mistyped their own paste. Refusing it here discloses
      // nothing: the value came from this browser.
      if (asked === null) {
        setNotice({
          kind: "refused",
          action: "peer_profile",
          failure: {
            kind: "channel_error",
            code: "bad_request",
            rawCode: "bad_request",
            message: "not an id",
          },
        });

        return {
          status: "refused",
          failure: {
            kind: "channel_error",
            code: "bad_request",
            rawCode: "bad_request",
            message: "not an id",
          },
        };
      }

      return run(
        "peer_profile",
        PROFILE_EVENTS.peerProfile,
        { person_id: asked },
        decodeProfile,
      );
    },
    [run],
  );

  const clearNotice = useCallback(() => {
    setNotice(null);
  }, []);

  return {
    connection,
    own,
    disclosures,
    joinGeneration,
    notice,
    clearNotice,
    setDisclosure,
    declareEntry,
    amendDeclaredEntry,
    requestCorrection,
    loadPeerProfile,
  };
}

function draftPayload(draft: DeclaredEntryDraft): object {
  return {
    role_label: draft.roleLabel,
    organisation_name: draft.organisationName,
    starts_at: draft.startsAt,
    ends_at: draft.endsAt,
  };
}

/**
 * What a read came back with, when it was not an answer.
 *
 * The previous record is left on screen rather than blanked: it was true a
 * moment ago, and a profile blanking itself because one round trip timed out
 * reads as "you have never worked anywhere", which is the one wrong answer this
 * surface can give. What is *not* silent is the absence of an answer, which is
 * what the notice is for.
 */
function report(
  action: ProfileAction,
  outcome: PushOutcome,
  setNotice: (notice: ProfileNotice) => void,
): void {
  switch (outcome.status) {
    case "ok":
    case "unsent":
      return;
    case "error":
      setNotice({
        kind: "refused",
        action,
        failure: decodeChannelRefusal(outcome.payload, PROFILE_ERROR_CODES),
      });

      return;
    case "timeout":
      setNotice({ kind: "refused", action, failure: { kind: "channel_timeout" } });

      return;
  }
}
