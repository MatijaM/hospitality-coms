/**
 * One room's channel: joining it, reading it, writing to it, and leaving it for
 * good when the server says the access is over.
 *
 * ## The terminal event leaves the topic. That is KTD8's client half.
 *
 * The plan's note is explicit: "handle the terminal revocation event by leaving
 * the topic rather than letting the client retry into a refusal loop." The
 * reason is worth restating because the failure it prevents looks like success.
 *
 * `VenueRoomChannel` and `ShiftRoomChannel` both answer a revocation by pushing
 * `"access_revoked"` and then `{:stop, {:shutdown, :revoked}, socket}`. Neither
 * of those is the revocation — `join/3` re-deriving membership against a term
 * that has closed is (KTD8), and every arrow before it is best effort. So the
 * client must not treat the stop as the end of the matter:
 *
 *   * If the channel stops cleanly, `Phoenix.Channel.Server` sends
 *     `{:socket_close, …}`, the transport pushes `phx_close`, and `phoenix`'s
 *     `Channel.onClose` resets the rejoin timer. **Measured against a real
 *     server:** after `end_engagement/2` the client received `access_revoked`
 *     and made no further join for fifteen seconds. So this path does not loop
 *     on its own, and the two below are what the leave is actually for.
 *   * If the channel process **dies** instead — a crash, a node going away, a
 *     `:DOWN` from anything at all — `Phoenix.Socket.__info__/2` sends
 *     `phx_error` for *every* exit reason (`encode_on_exit/4` ignores the
 *     reason), and `phoenix`'s `Channel.onError` schedules the rejoin timer.
 *     That rejoin is refused, `Push.reset()` keeps `recHooks`, and the refusal
 *     fires again on every backoff tick, for ever. **Measured against a real
 *     server:** a refused join left alone produced three refusals in six
 *     seconds; through `createSessionSocket` it produced one in four.
 *   * And a room left in the list is a room this surface re-joins the next time
 *     it is opened or the socket reconnects, which is the same loop with a
 *     longer period.
 *
 * Leaving on the terminal event closes all three: `Channel.leave()` resets the
 * rejoin timer and takes the channel out of `Socket.channels`, and `onEnded`
 * lets the list drop the room so nothing joins it again. `rooms.test.tsx`
 * measures that as a join count rather than as an absent room, with a control
 * that proves the measurement can see a loop, and
 * `session-socket.integration.test.ts` does the same against `phoenix`'s own
 * timers rather than against a model of them.
 *
 * ## What is deliberately not here
 *
 * **No history.** A joined room shows what arrives after the join and nothing
 * before it. `join/3`'s reply carries the room and the engagement; `:after_join`
 * pushes presence and no messages; and `Rooms.list_venue_room_messages/2` and
 * `list_shift_room_messages/2` have no HTTP surface. Inventing a `"history"`
 * event would be inventing a backend.
 *
 * **No presence.** `RoomChannel.joined/1` pushes `"presence_state"` and the
 * tracker pushes `"presence_diff"`, and this hook registers a handler for
 * neither, so `phoenix` drops them. Presence is worth rendering and it is not
 * one of the three things this surface exists to get right.
 *
 * **No retry.** A refused join is a decision (`session-socket.ts`), and this
 * hook offers nothing that would ask again on its own. Re-opening the room is
 * the worker asking, once.
 */

import { useCallback, useEffect, useRef, useState } from "react";

import type { ChannelFailure } from "../../socket/channel-failure";
import { decodeChannelRefusal } from "../../socket/channel-failure";
import type { TopicSubscription } from "../../socket/session-socket";
import { useSessionSocket } from "../../socket/socket-context";
import { decodeJoinedEngagementId, decodeRoomClosure, decodeRoomMessage } from "./decode";
import type { RoomClosure, RoomMessage, RoomRef } from "./room";
import { roomTopic } from "./room";

export type RoomConnection =
  /** No transport yet: nobody is signed in, or the socket has not been built. */
  | { readonly status: "no_socket" }
  | { readonly status: "joining" }
  /**
   * `engagementId` is `null` only if the join reply did not decode. The server
   * admitted this session either way, so the room opens; what is lost is the
   * ability to mark this session's own messages, which is not worth refusing a
   * join the server granted.
   */
  | { readonly status: "joined"; readonly engagementId: string | null }
  | { readonly status: "refused"; readonly failure: ChannelFailure }
  | { readonly status: "timed_out" }
  | { readonly status: "ended"; readonly closure: RoomClosure };

export type SendState =
  | { readonly status: "idle" }
  | { readonly status: "sending" }
  | { readonly status: "sent" }
  | { readonly status: "refused"; readonly failure: ChannelFailure }
  /** The room was left before the push went out. Nothing reached the server. */
  | { readonly status: "unsent" };

export type Room = {
  readonly connection: RoomConnection;
  readonly messages: readonly RoomMessage[];
  readonly send: SendState;
  readonly sendMessage: (body: string) => void;
};

export type UseRoomOptions = {
  /** The access ended. The topic has already been left when this is called. */
  readonly onEnded?: (closure: RoomClosure) => void;
  readonly onSendRefused?: (failure: ChannelFailure) => void;
};

const NO_SOCKET: RoomConnection = { status: "no_socket" };
const JOINING: RoomConnection = { status: "joining" };

/**
 * The sender gets its own message twice.
 *
 * `broadcast!/3` reaches every subscriber of the topic and a channel is
 * subscribed to its own, so the reply to `"send"` and the `"message"` broadcast
 * are the same row arriving down two paths. Keying on the id is what makes that
 * one bubble instead of two; it also makes a replayed broadcast harmless.
 */
function appended(
  messages: readonly RoomMessage[],
  message: RoomMessage,
): readonly RoomMessage[] {
  if (messages.some((existing) => existing.id === message.id)) return messages;

  return [...messages, message];
}

export function useRoom(ref: RoomRef, options: UseRoomOptions = {}): Room {
  const socket = useSessionSocket();
  // A string, so the effect below does not rejoin every time the parent
  // rebuilds the reference object it was handed.
  const topic = roomTopic(ref);

  // The channel's own state starts at `joining` and is written **only** from
  // the callbacks `phoenix` invokes — never synchronously from the effect
  // body. That is what keeps the effect a subscription rather than a render
  // that happens twice, and it is why there is no reset here: the room's
  // identity is a `key` on the component that calls this hook, so a different
  // room is a different mount and a different initial state.
  const [joinState, setJoinState] = useState<RoomConnection>(JOINING);
  const [messages, setMessages] = useState<readonly RoomMessage[]>([]);
  const [send, setSend] = useState<SendState>({ status: "idle" });

  // No socket is not a state the channel is in; it is the absence of one, so
  // it is derived rather than stored. Storing it would need a write from the
  // effect body to get in and another to get out.
  const connection: RoomConnection = socket === null ? NO_SOCKET : joinState;

  const subscription = useRef<TopicSubscription | null>(null);

  // The callbacks are held in a ref rather than in the effect's dependencies.
  // A parent that rebuilds them on every render would otherwise leave and
  // rejoin the topic on every render, which is the retry loop this hook exists
  // to prevent, arriving from the other direction.
  const callbacks = useRef(options);

  useEffect(() => {
    callbacks.current = options;
  });

  useEffect(() => {
    if (socket === null) return;

    // Assigned the moment `join` returns, and read only from callbacks that
    // `phoenix` invokes later. A terminal event cannot arrive before the join
    // call it is a consequence of has returned.
    let open: TopicSubscription | null = null;

    function ended(reason: RoomClosure["reason"], payload: unknown): void {
      // A terminal notice this client cannot decode is still a terminal
      // notice. Refusing to leave because a field was renamed would be the
      // retry loop, entered through a decoder.
      const closure = decodeRoomClosure(reason, payload) ?? {
        reason,
        engagementId: "",
        at: "",
      };

      // Leave first. Everything after this is rendering; this is the part that
      // stops `phoenix` asking a server that has already decided.
      open?.leave();
      setJoinState({ status: "ended", closure });
      callbacks.current.onEnded?.(closure);
    }

    open = socket.join(topic, {
      events: {
        message: (payload) => {
          const message = decodeRoomMessage(payload);
          if (message === null) return;

          setMessages((current) => appended(current, message));
        },
        access_revoked: (payload) => {
          ended("revoked", payload);
        },
        access_suspended: (payload) => {
          ended("suspended", payload);
        },
      },
      onJoined: (payload) => {
        setJoinState({
          status: "joined",
          engagementId: decodeJoinedEngagementId(payload),
        });
      },
      onRefused: (payload) => {
        // Already left by `createSessionSocket`, which treats a refusal as a
        // decision. There is nothing to retry and nothing offering to.
        setJoinState({ status: "refused", failure: decodeChannelRefusal(payload) });
      },
      onTimeout: () => {
        // Not a refusal: nobody decided anything, and `phoenix`'s own retry is
        // left alone deliberately.
        setJoinState({ status: "timed_out" });
      },
    });

    subscription.current = open;
    const opened = open;

    return () => {
      opened.leave();
      subscription.current = null;
    };
  }, [socket, topic]);

  const sendMessage = useCallback((body: string) => {
    const open = subscription.current;

    if (open === null) {
      setSend({ status: "unsent" });

      return;
    }

    setSend({ status: "sending" });

    void open.push("send", { body }).then((outcome) => {
      switch (outcome.status) {
        case "ok":
          // The message itself arrives on the `"message"` broadcast, which the
          // sender receives too. Rendering the reply as well would put it on
          // screen twice; `appended` would collapse them, and not depending on
          // that is one fewer thing to be right about.
          setSend({ status: "sent" });

          return;
        case "error": {
          const failure = decodeChannelRefusal(outcome.payload);
          setSend({ status: "refused", failure });
          callbacks.current.onSendRefused?.(failure);

          return;
        }
        case "timeout":
          setSend({ status: "refused", failure: { kind: "channel_timeout" } });

          return;
        case "unsent":
          setSend({ status: "unsent" });

          return;
      }
    });
  }, []);

  return { connection, messages, send, sendMessage };
}
