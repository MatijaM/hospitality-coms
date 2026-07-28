/**
 * The whole peer surface on one subscription: who this person can see, what
 * they have been asked, what they asked, every conversation and every message
 * in the ones that have been opened.
 *
 * ## One hook because there is one topic
 *
 * `useRoom` is per room, because a room *is* a topic. A conversation is not:
 * KTD10 puts the conversation in every payload and never in the topic, so there
 * is one channel per session and a second hook would mean a second join of the
 * same topic — two subscriptions receiving every announcement twice, and every
 * message rendered twice with it.
 *
 * ## An announcement is a nudge; the list is the answer
 *
 * Four of the five pushes — `peer_request`, `peer_request_declined`,
 * `peer_connected`, `peer_disconnected` — are **not** applied to local state.
 * They cause the affected list to be asked for again.
 *
 * That is not laziness, it is the only correct reading. A notice carries ids
 * and an instant; a request's `state` is **derived per read** from whether the
 * pair can see each other at that instant (`:lapsed` is R14's "expired" and
 * nothing stores it), so this client cannot compute what a notice means for a
 * request's state without asking. Patching local state from the notice would
 * mean inventing the one field the surface renders.
 *
 * `peer_message` is the exception and is applied directly, because the notice
 * carries the whole message: `connection_id`, `message_id`, `author_id`, `body`
 * and the instant. There is nothing derived about it.
 *
 * ## What the nudges do **not** cover, and what does
 *
 * The three lists are re-asked on every join, so a reconnect re-derives them.
 * An **open conversation's history is not a list**, and for one revision it was
 * the gap in that story: a message sent while the socket was down arrives on
 * nobody's push — the client was not subscribed — and nothing re-asked the
 * history, so it was missing until the conversation was closed and reopened.
 *
 * `joinGeneration` closes it. It counts admitted joins, `ConversationView`
 * names it in the effect that loads history, and a rejoin therefore re-fetches
 * the open conversation. **Only the open one**, deliberately: every other
 * conversation's cache is unreachable until it is opened, and opening one
 * remounts that view and re-fetches anyway, so backfilling all of them would
 * buy nothing and cost one push per conversation on every reconnect.
 *
 * ## Every action refreshes as well as listening
 *
 * `HospitalityComs.Peers.announce/2` publishes to **both** parties' topics, and
 * a channel is subscribed to its own — so the actor receives its own
 * announcement and a refresh driven by the push alone would usually be enough.
 * Usually is the problem: that broadcast is best effort and logged rather than
 * propagated (its own moduledoc says so), so a surface that depended on it for
 * the actor's own screen would silently fail to update the one person who is
 * definitely watching. Both paths run, and both are idempotent reads.
 *
 * ## Nothing is remembered and there is nothing to clear
 *
 * No store, no `localStorage`, nothing handed to `SessionProvider`'s
 * `onSessionEnded`. `list_peers`, `list_requests` and `list_conversations`
 * exist, so unlike the room list there is nothing this client would have to
 * write down in order to render the surface — see `peer.ts`.
 *
 * What is held in memory **is** cleared, and that is a separate rule with its
 * own reason: a join refused `unauthorized` means the server has re-derived
 * this session and does not have it, so the graph on screen may belong to
 * somebody who is no longer the person at the terminal. See `onRefused`.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import { decodeChannelRefusal } from "../../socket/channel-failure";
import type { PushOutcome, TopicSubscription } from "../../socket/session-socket";
import { useSessionSocket } from "../../socket/socket-context";
import {
  decodeConversation,
  decodeConversations,
  decodeJoinedPersonId,
  decodePeerMessage,
  decodePeerMessages,
  decodePeerRequest,
  decodePeerRequests,
  decodePeers,
} from "./decode";
import type { Conversation, Peer, PeerMessage, PeerRequest } from "./peer";
import { normalisePersonId, peerTopic } from "./peer";
import type { PeerAction, PeerFailure, PeerNotice } from "./refusal-message";
import { PEER_ERROR_CODES, closesConversation, endsSession } from "./refusal-message";

export type PeerConnection =
  /** No transport: nobody is signed in, or the socket has not been built. */
  | { readonly status: "no_socket" }
  /**
   * The session's own person id is not an id.
   *
   * It comes from `GET /api/me`, so this cannot happen against this API — it is
   * a state rather than a `throw` because the alternative to rendering a
   * sentence is a blank surface, and the topic must not be built from it either
   * way. See `normalisePersonId`.
   */
  | { readonly status: "no_person" }
  | { readonly status: "joining" }
  | { readonly status: "joined"; readonly personId: string }
  | { readonly status: "refused"; readonly failure: PeerFailure }
  | { readonly status: "timed_out" };

/**
 * What an action came back with.
 *
 * `value` is nullable on the success path on purpose: the server accepted the
 * event, and a reply this client cannot decode does not un-accept it. The lists
 * are re-asked either way, so the surface renders the server's answer rather
 * than the reply this client failed to read.
 */
export type PeerOutcome<Value> =
  | { readonly status: "ok"; readonly value: Value | null }
  | { readonly status: "refused"; readonly failure: PeerFailure }
  /** The subscription was gone before the push went out. Nothing was sent. */
  | { readonly status: "unsent" };

export type PeerSurface = {
  readonly connection: PeerConnection;
  readonly peers: readonly Peer[];
  readonly incoming: readonly PeerRequest[];
  readonly outgoing: readonly PeerRequest[];
  readonly conversations: readonly Conversation[];
  /**
   * How many times this surface has been admitted to its topic.
   *
   * Starts at 0 and is incremented by every `onJoined`, including the rejoin
   * `phoenix` makes after a dropped link. A consumer that caches something the
   * three lists do not cover names it in an effect's dependencies; see the
   * header and `ConversationView`.
   */
  readonly joinGeneration: number;
  /** One at a time, and always the most recent. Rendered in one place. */
  readonly notice: PeerNotice | null;
  readonly clearNotice: () => void;
  readonly messagesOf: (connectionId: string) => readonly PeerMessage[];
  /**
   * Loads a conversation's history.
   *
   * `open` is the conversation's own `open` flag and it decides whether the
   * answer is merged into what is cached or **replaces** it. See `loadHistory`.
   */
  readonly loadHistory: (
    connectionId: string,
    open: boolean,
  ) => Promise<PeerOutcome<readonly PeerMessage[]>>;
  readonly requestConnection: (personId: string) => Promise<PeerOutcome<PeerRequest>>;
  readonly acceptRequest: (requestId: string) => Promise<PeerOutcome<Conversation>>;
  readonly declineRequest: (requestId: string) => Promise<PeerOutcome<PeerRequest>>;
  readonly sendMessage: (
    connectionId: string,
    body: string,
  ) => Promise<PeerOutcome<PeerMessage>>;
  readonly disconnect: (connectionId: string) => Promise<PeerOutcome<Conversation>>;
};

const NO_SOCKET: PeerConnection = { status: "no_socket" };
const NO_PERSON: PeerConnection = { status: "no_person" };
const JOINING: PeerConnection = { status: "joining" };

type Messages = Readonly<Record<string, readonly PeerMessage[]>>;

/**
 * Two messages in the order the server stamped them.
 *
 * **Parsed rather than compared as strings, and the reason is a live hazard in
 * this codebase rather than a hypothetical.** Every peer instant is currently
 * `:utc_datetime`, truncated to the second, and for values in that shape
 * lexicographic order *is* chronological order — which is what the first
 * version of this relied on. But `"…:00.5Z" < "…:00Z"`, because `.` sorts
 * before `Z`, so the moment any peer column becomes `:utc_datetime_usec` the
 * comparison silently inverts within each second. U6's review moved
 * `roster_entries`' timestamps from second to microsecond precision for a
 * correctness reason, so the same change to `peer_messages.sent_at` is a thing
 * that happens here, not a thing that might.
 *
 * `Date.parse` of an ISO 8601 UTC instant is spec-defined and gives
 * milliseconds. Two messages closer together than a millisecond therefore
 * compare equal and fall back to the stable-sort behaviour below, which is the
 * same answer they get today at second precision.
 *
 * The string comparison survives as the fallback for a value `Date.parse`
 * cannot read at all: `NaN` compares false against everything, so an unparsable
 * instant would otherwise scramble the whole list rather than misplace itself.
 *
 * This is not the time arithmetic `peer.ts` bans. That ban is about deriving
 * product state — whether a request has expired — against this client's own
 * clock, which is `HospitalityComs.Clock`'s job and is why `lapsed` arrives
 * from the server. Ordering two instants the server stamped decides nothing.
 */
function byInstant(one: PeerMessage, other: PeerMessage): number {
  const first = Date.parse(one.sentAt);
  const second = Date.parse(other.sentAt);

  if (Number.isNaN(first) || Number.isNaN(second)) {
    return one.sentAt < other.sentAt ? -1 : one.sentAt > other.sentAt ? 1 : 0;
  }

  return first - second;
}

/**
 * Two message lists as one, deduplicated by id and ordered by the instant.
 *
 * Deduplication is load-bearing twice over: the sender receives its own message
 * as a reply **and** as an announcement, because `announce/2` publishes to both
 * parties and a channel is subscribed to its own topic; and a history loaded
 * after some live messages have arrived overlaps them.
 *
 * `Array.prototype.sort` is stable, so messages the server stamped at the same
 * instant — which happens, since these are truncated to the second and the demo
 * pins the clock — keep the order they were merged in: `earlier` first. That is
 * what makes a loaded history keep the server's own ordering within a second.
 */
function merged(
  earlier: readonly PeerMessage[],
  later: readonly PeerMessage[],
): readonly PeerMessage[] {
  const byId = new Map<string, PeerMessage>();

  for (const message of [...earlier, ...later]) {
    if (!byId.has(message.messageId)) byId.set(message.messageId, message);
  }

  return [...byId.values()].sort(byInstant);
}

const NO_MESSAGES: readonly PeerMessage[] = [];
const NO_PEERS: readonly Peer[] = [];
const NO_REQUESTS: readonly PeerRequest[] = [];
const NO_CONVERSATIONS: readonly Conversation[] = [];
const NO_CACHE: Messages = {};

export function usePeerSurface(personId: string): PeerSurface {
  const socket = useSessionSocket();
  // Normalised here rather than at the caller, because this is the only place
  // that turns it into a topic and a topic in the wrong case joins fine and
  // then hears nothing at all. See `normalisePersonId`.
  const ownId = normalisePersonId(personId);
  const topic = ownId === null ? null : peerTopic(ownId);

  const [joinState, setJoinState] = useState<PeerConnection>(JOINING);
  const [joinGeneration, setJoinGeneration] = useState(0);
  const [peers, setPeers] = useState<readonly Peer[]>(NO_PEERS);
  const [incoming, setIncoming] = useState<readonly PeerRequest[]>(NO_REQUESTS);
  const [outgoing, setOutgoing] = useState<readonly PeerRequest[]>(NO_REQUESTS);
  const [conversations, setConversations] =
    useState<readonly Conversation[]>(NO_CONVERSATIONS);
  const [messages, setMessages] = useState<Messages>(NO_CACHE);
  const [notice, setNotice] = useState<PeerNotice | null>(null);

  // Derived rather than stored, exactly as `useRoom` derives `no_socket`:
  // storing it would need a write from the effect body to get in and another to
  // get out.
  const connection: PeerConnection =
    ownId === null ? NO_PERSON : socket === null ? NO_SOCKET : joinState;

  const subscription = useRef<TopicSubscription | null>(null);

  // Which conversations the server has told this client about, readable from
  // the channel callbacks — which close over the render that registered them
  // and would otherwise see whatever `conversations` was at join time, for ever.
  const known = useRef<ReadonlySet<string>>(new Set());

  useEffect(() => {
    known.current = new Set(conversations.map((one) => one.connectionId));
  }, [conversations]);

  // Each loader takes the subscription rather than reading the ref, because the
  // ones the join fires run while the ref is still being assigned — `join`
  // returns the subscription and the effect stores it on the next line.
  const loadPeers = useCallback(async (open: TopicSubscription): Promise<void> => {
    const outcome = await open.push("list_peers", {});

    if (outcome.status !== "ok") {
      report("list", outcome, setNotice);

      return;
    }

    const decoded = decodePeers(outcome.payload);

    // A named absence rather than a silent no-op. Keeping the previous list
    // would leave a surface asserting something the server has stopped saying.
    if (decoded === null) {
      setNotice({ kind: "malformed_reply", action: "list" });

      return;
    }

    setPeers(decoded);
  }, []);

  const loadRequests = useCallback(async (open: TopicSubscription): Promise<void> => {
    const outcome = await open.push("list_requests", {});

    if (outcome.status !== "ok") {
      report("list", outcome, setNotice);

      return;
    }

    const decoded = decodePeerRequests(outcome.payload);

    if (decoded === null) {
      setNotice({ kind: "malformed_reply", action: "list" });

      return;
    }

    setIncoming(decoded.incoming);
    setOutgoing(decoded.outgoing);
  }, []);

  const loadConversations = useCallback(
    async (open: TopicSubscription): Promise<void> => {
      const outcome = await open.push("list_conversations", {});

      if (outcome.status !== "ok") {
        report("list", outcome, setNotice);

        return;
      }

      const decoded = decodeConversations(outcome.payload);

      if (decoded === null) {
        setNotice({ kind: "malformed_reply", action: "list" });

        return;
      }

      setConversations(decoded);
    },
    [],
  );

  useEffect(() => {
    if (socket === null || topic === null) return;

    let open: TopicSubscription | null = null;

    open = socket.join(topic, {
      events: {
        // The four that are nudges. Every one of them re-asks rather than
        // patching: see this file's header.
        peer_request: () => {
          if (open !== null) void loadRequests(open);
        },
        peer_request_declined: () => {
          if (open !== null) void loadRequests(open);
        },
        peer_connected: () => {
          if (open === null) return;

          void loadRequests(open);
          void loadConversations(open);
        },
        peer_disconnected: () => {
          if (open !== null) void loadConversations(open);
        },
        // The one that is the answer, and it decodes with the same function the
        // reply and the history do. The push used to stamp its instant `at`
        // while they stamped it `sent_at`; issue #31 made the push say
        // `sent_at` too, and the two decoders became one.
        peer_message: (payload) => {
          const message = decodePeerMessage(payload);
          if (message === null) return;

          setMessages((current) => appended(current, message));

          // A message for a conversation no list has mentioned means the
          // conversation list is stale — every `peer_message` is for a
          // connection this person is a party to, and `list_conversations`
          // returns all of them. The usual cause is a `peer_connected`
          // announcement that was not delivered, which `announce/2` permits:
          // it is best effort and logged. Without this the conversation is
          // unreachable until a reload, with its messages piling up in a cache
          // nothing can open.
          //
          // It cannot loop: the refresh puts the id in `known`, so the next
          // message for it asks nothing.
          if (open !== null && !known.current.has(message.connectionId)) {
            void loadConversations(open);
          }
        },
      },
      onJoined: (payload) => {
        setJoinState({ status: "joined", personId: joinedPersonId(payload, ownId) });
        setJoinGeneration((previous) => previous + 1);

        if (open === null) return;

        void loadPeers(open);
        void loadRequests(open);
        void loadConversations(open);
      },
      onRefused: (payload) => {
        // `createSessionSocket` has already left the topic: a refusal is a
        // decision, and there is nothing here that asks again.
        const failure = decodeChannelRefusal(payload, PEER_ERROR_CODES);
        setJoinState({ status: "refused", failure });

        // `unauthorized` is the server saying it re-derived this session and
        // does not have it — the token was deleted by a log-out somewhere else,
        // or by U7's revocation. The graph must not stay on screen.
        //
        // Hospitality is a shared-terminal industry, and this is the third time
        // that has decided something in this client: the room list is cleared
        // on log-out, a closed conversation's history is replaced rather than
        // merged, and this. A peer graph names who somebody knows, which is
        // worse to leave in front of the next person than a room bookmark.
        //
        // It clears what is rendered and does not touch the session. Whether
        // this person is still signed in is `GET /api/me`'s answer and
        // `RequireSession`'s to act on; a channel refusal is not this client's
        // licence to throw a credential away, which is the same line
        // `SessionProvider` draws between a 401 and an unreachable server.
        if (!endsSession(failure)) return;

        setPeers(NO_PEERS);
        setIncoming(NO_REQUESTS);
        setOutgoing(NO_REQUESTS);
        setConversations(NO_CONVERSATIONS);
        setMessages(NO_CACHE);
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
  }, [socket, topic, ownId, loadPeers, loadRequests, loadConversations]);

  const run = useCallback(
    async <Value>(
      action: PeerAction,
      event: string,
      payload: object,
      decode: (reply: unknown) => Value | null,
    ): Promise<PeerOutcome<Value>> => {
      const open = subscription.current;
      if (open === null) return { status: "unsent" };

      setNotice(null);

      const outcome = await open.push(event, payload);

      switch (outcome.status) {
        case "ok":
          return { status: "ok", value: decode(outcome.payload) };
        case "error": {
          const failure = decodeChannelRefusal(outcome.payload, PEER_ERROR_CODES);
          setNotice({ kind: "refused", action, failure });

          // The server has just said this conversation is closed. It is not
          // remembered — `list_conversations` carries `open`, so the honest
          // answer is to ask and render what comes back.
          if (closesConversation(failure, action)) void loadConversations(open);

          return { status: "refused", failure };
        }
        case "timeout": {
          const failure: PeerFailure = { kind: "channel_timeout" };
          setNotice({ kind: "refused", action, failure });

          return { status: "refused", failure };
        }
        case "unsent":
          return { status: "unsent" };
      }
    },
    [loadConversations],
  );

  const refresh = useCallback(
    (which: { requests?: boolean; conversations?: boolean }) => {
      const open = subscription.current;
      if (open === null) return;

      if (which.requests === true) void loadRequests(open);
      if (which.conversations === true) void loadConversations(open);
    },
    [loadRequests, loadConversations],
  );

  const requestConnection = useCallback(
    async (id: string): Promise<PeerOutcome<PeerRequest>> => {
      const outcome = await run(
        "request",
        "request",
        { person_id: id },
        decodePeerRequest,
      );
      if (outcome.status === "ok") refresh({ requests: true });

      return outcome;
    },
    [run, refresh],
  );

  const acceptRequest = useCallback(
    async (requestId: string): Promise<PeerOutcome<Conversation>> => {
      const outcome = await run(
        "accept",
        "accept",
        { request_id: requestId },
        decodeConversation,
      );
      if (outcome.status === "ok") refresh({ requests: true, conversations: true });

      return outcome;
    },
    [run, refresh],
  );

  const declineRequest = useCallback(
    async (requestId: string): Promise<PeerOutcome<PeerRequest>> => {
      const outcome = await run(
        "decline",
        "decline",
        { request_id: requestId },
        decodePeerRequest,
      );
      if (outcome.status === "ok") refresh({ requests: true });

      return outcome;
    },
    [run, refresh],
  );

  /**
   * Loads a conversation's history, and decides what to do with what is cached.
   *
   * **A closed conversation replaces; an open one merges.** That asymmetry is
   * the point rather than an optimisation.
   *
   * `Peers.list_messages/2` reads the whole conversation while it is open and,
   * once it has been disconnected, **each party's own messages and only their
   * own** — R15's remedy, which `peers_test.exs` asserts with a row count as the
   * control for nothing having been deleted. Merging would render the
   * counterpart's messages out of a cache the server has just declined to send,
   * so the enforcement would hold on the wire and not on the screen. This is a
   * cache the client owns and a rule the client was undoing.
   *
   * Merging survives for the open case because the reply can genuinely race a
   * push: a message that arrived while the history was in flight is here and is
   * not in the answer. That race cannot happen on a closed conversation —
   * nothing can be sent to one, so there is no push to lose.
   */
  const loadHistory = useCallback(
    async (
      connectionId: string,
      open: boolean,
    ): Promise<PeerOutcome<readonly PeerMessage[]>> => {
      const outcome = await run(
        "history",
        "history",
        { connection_id: connectionId },
        decodePeerMessages,
      );

      if (outcome.status === "ok" && outcome.value !== null) {
        const history = outcome.value;

        setMessages((current) => ({
          ...current,
          [connectionId]: open
            ? merged(history, current[connectionId] ?? NO_MESSAGES)
            : history,
        }));
      }

      return outcome;
    },
    [run],
  );

  const sendMessage = useCallback(
    async (connectionId: string, body: string): Promise<PeerOutcome<PeerMessage>> => {
      const outcome = await run(
        "send",
        "send",
        { connection_id: connectionId, body },
        decodePeerMessage,
      );

      // The message also arrives on the announcement, which this session
      // receives because it is subscribed to its own topic. Applying the reply
      // as well is one fewer thing to depend on, and `merged` collapses them.
      if (outcome.status === "ok" && outcome.value !== null) {
        const message = outcome.value;
        setMessages((current) => appended(current, message));
      }

      return outcome;
    },
    [run],
  );

  const disconnect = useCallback(
    async (connectionId: string): Promise<PeerOutcome<Conversation>> => {
      const outcome = await run(
        "disconnect",
        "disconnect",
        { connection_id: connectionId },
        decodeConversation,
      );
      if (outcome.status === "ok") refresh({ conversations: true });

      return outcome;
    },
    [run, refresh],
  );

  const messagesOf = useCallback(
    (connectionId: string): readonly PeerMessage[] =>
      messages[connectionId] ?? NO_MESSAGES,
    [messages],
  );

  const clearNotice = useCallback(() => {
    setNotice(null);
  }, []);

  return {
    connection,
    peers,
    incoming,
    outgoing,
    conversations,
    joinGeneration,
    notice,
    clearNotice,
    messagesOf,
    loadHistory,
    requestConnection,
    acceptRequest,
    declineRequest,
    sendMessage,
    disconnect,
  };
}

function appended(current: Messages, message: PeerMessage): Messages {
  const existing = current[message.connectionId] ?? NO_MESSAGES;

  return { ...current, [message.connectionId]: merged(existing, [message]) };
}

/**
 * The person the server says this channel is multiplexing for.
 *
 * `join/3` replies with `%{person_id: …}` and it is always the session's own —
 * `admitted/3` matches the topic's suffix against the scope's person with a
 * repeated variable, so there is no admitted join where the two differ. It is
 * read from the reply anyway, and falls back to the id this client asked with,
 * so that "whose surface is this" comes from the server wherever the server
 * says it.
 */
function joinedPersonId(payload: unknown, asked: string | null): string {
  return decodeJoinedPersonId(payload) ?? asked ?? "";
}

/**
 * What a list push came back with, when it was not an answer.
 *
 * A list event has no refusing clause in `PeerChannel` — `list_peers`,
 * `list_requests` and `list_conversations` all answer `{:ok, …}` — so anything
 * but `ok` here is a timeout, a subscription that had already been left, or
 * drift. The previous list is left on screen rather than blanked: it was true a
 * moment ago, and the next notice asks again. What is *not* silent is the
 * absence of an answer, which is what the notice is for.
 */
function report(
  action: PeerAction,
  outcome: PushOutcome,
  setNotice: (notice: PeerNotice) => void,
): void {
  switch (outcome.status) {
    case "ok":
    case "unsent":
      return;
    case "error":
      setNotice({
        kind: "refused",
        action,
        failure: decodeChannelRefusal(outcome.payload, PEER_ERROR_CODES),
      });

      return;
    case "timeout":
      setNotice({ kind: "refused", action, failure: { kind: "channel_timeout" } });

      return;
  }
}
