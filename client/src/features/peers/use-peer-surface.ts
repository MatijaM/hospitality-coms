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
 * mean inventing the one field the surface renders. Asking again is also what
 * makes the surface correct after a reconnect, where notices were missed
 * entirely.
 *
 * `peer_message` is the exception and is applied directly, because the notice
 * carries the whole message: `connection_id`, `message_id`, `author_id`, `body`
 * and the instant. There is nothing derived about it.
 *
 * ## Every action refreshes as well as listening
 *
 * `HospitalityComs.Peers.announce/2` publishes to **both** parties' topics, and
 * a channel is subscribed to its own — so the actor receives its own
 * announcement and a refresh driven by the push alone would usually be enough.
 * Usually is the problem: that broadcast is best effort and logged rather than
 * propagated (its own moduledoc says so), so a surface that depended on it for
 * the actor's own screen would silently fail to update the one person who is
 * definitely watching. Both paths run, and both are idempotent reads, which is
 * what makes running both harmless rather than a thing to be careful about.
 *
 * ## Nothing is remembered and there is nothing to clear
 *
 * No store, no `localStorage`, nothing handed to `SessionProvider`'s
 * `onSessionEnded`. `list_peers`, `list_requests` and `list_conversations`
 * exist, so unlike the room list there is nothing this client would have to
 * write down in order to render the surface — see `peer.ts`.
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
  decodePeerMessageNotice,
  decodePeerMessages,
  decodePeerRequest,
  decodePeerRequests,
  decodePeers,
} from "./decode";
import type { Conversation, Peer, PeerMessage, PeerRequest } from "./peer";
import { normalisePersonId, peerTopic } from "./peer";
import type { PeerAction, PeerFailure } from "./refusal-message";
import { PEER_ERROR_CODES, closesConversation } from "./refusal-message";

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

/** The most recent refusal, and which event met it. */
export type PeerNotice = {
  readonly action: PeerAction;
  readonly failure: PeerFailure;
};

export type PeerSurface = {
  readonly connection: PeerConnection;
  readonly peers: readonly Peer[];
  readonly incoming: readonly PeerRequest[];
  readonly outgoing: readonly PeerRequest[];
  readonly conversations: readonly Conversation[];
  /** One at a time, and always the most recent. Rendered in one place. */
  readonly notice: PeerNotice | null;
  readonly clearNotice: () => void;
  readonly messagesOf: (connectionId: string) => readonly PeerMessage[];
  readonly loadHistory: (
    connectionId: string,
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
 * Two message lists as one, deduplicated by id and ordered by the instant.
 *
 * Deduplication is load-bearing twice over: the sender receives its own message
 * as a reply **and** as an announcement, because `announce/2` publishes to both
 * parties and a channel is subscribed to its own topic; and a history loaded
 * after some live messages have arrived overlaps them.
 *
 * The ordering key is the server's `sent_at`, compared as a string. Every one
 * is `DateTime.to_iso8601/1` of a UTC instant in the same format, so
 * lexicographic order is chronological order — and no `Date` is constructed,
 * for `peer.ts`'s reason. `Array.prototype.sort` is stable, so messages sharing
 * an instant — which happens, since these are truncated to the second and the
 * demo pins the clock — keep the order they were merged in: `earlier` first.
 */
function merged(
  earlier: readonly PeerMessage[],
  later: readonly PeerMessage[],
): readonly PeerMessage[] {
  const byId = new Map<string, PeerMessage>();

  for (const message of [...earlier, ...later]) {
    if (!byId.has(message.messageId)) byId.set(message.messageId, message);
  }

  return [...byId.values()].sort((one, other) =>
    one.sentAt < other.sentAt ? -1 : one.sentAt > other.sentAt ? 1 : 0,
  );
}

const NO_MESSAGES: readonly PeerMessage[] = [];

export function usePeerSurface(personId: string): PeerSurface {
  const socket = useSessionSocket();
  // Normalised here rather than at the caller, because this is the only place
  // that turns it into a topic and a topic in the wrong case joins fine and
  // then hears nothing at all. See `normalisePersonId`.
  const ownId = normalisePersonId(personId);
  const topic = ownId === null ? null : peerTopic(ownId);

  const [joinState, setJoinState] = useState<PeerConnection>(JOINING);
  const [peers, setPeers] = useState<readonly Peer[]>([]);
  const [incoming, setIncoming] = useState<readonly PeerRequest[]>([]);
  const [outgoing, setOutgoing] = useState<readonly PeerRequest[]>([]);
  const [conversations, setConversations] = useState<readonly Conversation[]>([]);
  const [messages, setMessages] = useState<Messages>({});
  const [notice, setNotice] = useState<PeerNotice | null>(null);

  // Derived rather than stored, exactly as `useRoom` derives `no_socket`:
  // storing it would need a write from the effect body to get in and another to
  // get out.
  const connection: PeerConnection =
    ownId === null ? NO_PERSON : socket === null ? NO_SOCKET : joinState;

  const subscription = useRef<TopicSubscription | null>(null);

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
    if (decoded !== null) setPeers(decoded);
  }, []);

  const loadRequests = useCallback(async (open: TopicSubscription): Promise<void> => {
    const outcome = await open.push("list_requests", {});

    if (outcome.status !== "ok") {
      report("list", outcome, setNotice);

      return;
    }

    const decoded = decodePeerRequests(outcome.payload);
    if (decoded === null) return;

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
      if (decoded !== null) setConversations(decoded);
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
        // The one that is the answer. `decodePeerMessageNotice` is not
        // `decodePeerMessage`: the push stamps its instant `at` and the reply
        // stamps it `sent_at`.
        peer_message: (payload) => {
          const message = decodePeerMessageNotice(payload);
          if (message === null) return;

          setMessages((current) => appended(current, message));
        },
      },
      onJoined: (payload) => {
        setJoinState({ status: "joined", personId: joinedPersonId(payload, ownId) });

        if (open === null) return;

        void loadPeers(open);
        void loadRequests(open);
        void loadConversations(open);
      },
      onRefused: (payload) => {
        // `createSessionSocket` has already left the topic: a refusal is a
        // decision, and there is nothing here that asks again.
        setJoinState({
          status: "refused",
          failure: decodeChannelRefusal(payload, PEER_ERROR_CODES),
        });
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
          setNotice({ action, failure });

          // The server has just said this conversation is closed. It is not
          // remembered — `list_conversations` carries `open`, so the honest
          // answer is to ask and render what comes back.
          if (closesConversation(failure, action)) void loadConversations(open);

          return { status: "refused", failure };
        }
        case "timeout": {
          const failure: PeerFailure = { kind: "channel_timeout" };
          setNotice({ action, failure });

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

  const loadHistory = useCallback(
    async (connectionId: string): Promise<PeerOutcome<readonly PeerMessage[]>> => {
      const outcome = await run(
        "history",
        "history",
        { connection_id: connectionId },
        decodePeerMessages,
      );

      if (outcome.status === "ok" && outcome.value !== null) {
        const history = outcome.value;
        // Merged rather than assigned: a message that arrived on the push while
        // this was in flight is already here and is not in the history.
        setMessages((current) => ({
          ...current,
          [connectionId]: merged(history, current[connectionId] ?? NO_MESSAGES),
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
 * moment ago, and the next notice asks again.
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
        action,
        failure: decodeChannelRefusal(outcome.payload, PEER_ERROR_CODES),
      });

      return;
    case "timeout":
      setNotice({ action, failure: { kind: "channel_timeout" } });

      return;
  }
}
