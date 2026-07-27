/**
 * The connection half of the Phoenix socket, and nothing above it.
 *
 * U7 is defining the sockets, their topics, their event names and their
 * payloads while this is being written. So this module knows how to open a
 * connection carrying a session token, how to join a topic somebody else names,
 * and — the part that is worth having early — what to do when a join is
 * refused. It knows no topic and no event name of its own, and there is nothing
 * here for rooms, peers or presence.
 *
 * ## Why a refused join leaves rather than retries
 *
 * KTD8 makes `join/3` the enforcement point and calls the teardown broadcast
 * best effort: "the JS client auto-rejoins on `phx_error`, so stopping a
 * channel is a nudge and the rejoin refusal is the actual revocation."
 *
 * That is a description of the client's own behaviour, and it cuts both ways.
 * In `phoenix.js`, `joinPush.receive("error", …)` sets the channel to `errored`
 * and schedules `rejoinTimer`; the rejoin resends the same join push, and
 * `Push.reset()` clears the response while keeping `recHooks`, so every
 * refusal fires the caller's error callback again. A client that treats
 * refusal as something to wait out therefore asks a server that has already
 * decided, for ever, on a backoff timer, and shows the worker a room that
 * keeps almost-loading.
 *
 * A refusal is a decision. This wrapper leaves the topic on the first one,
 * which cancels the rejoin timer through `onClose`, and hands the payload to
 * the caller exactly once. A *timeout* is not a refusal — nobody decided
 * anything — so it is reported and left to Phoenix's own retry.
 *
 * ## Why the token is `authToken` and never a param
 *
 * `Socket.endPointURL()` is
 * `appendParams(appendParams(this.endPoint, this.params()), {vsn})`, so
 * **socket params are the URL's query string**. Putting a session token there
 * writes a live, fourteen-day bearer credential into every access log, proxy
 * log and referrer that sees the connection — the exact disclosure the token
 * being a database row rather than a signed claim is supposed to make
 * revocable, not routine.
 *
 * `authToken` is the option that does not do that. On the websocket transport
 * `transportConnect()` sends it as a `Sec-WebSocket-Protocol` value
 * (`base64url.bearer.phx.<base64>`), and on the longpoll fallback as an
 * `X-Phoenix-AuthToken` header. Phoenix surfaces it server-side as
 * `connect_info[:auth_token]`. So there is no params key left for anyone to
 * name, and this module sends no params at all.
 *
 * ## What U7 owns
 *
 * The endpoint path is configuration with a conventional default, because
 * `HospitalityComsWeb.Endpoint` mounts no socket yet. Nothing here is wired
 * into the running app for the same reason: there is no topic to join.
 *
 * **The token is captured when the socket is built, not when it connects.**
 * `phoenix` wraps `authToken` in a closure at construction, so a socket built
 * for one session carries that session's token for its whole life — including
 * across reconnects. A re-login therefore needs a *new* socket, not a
 * reconnect of this one. If U7 wants a socket that survives a token change,
 * `authToken` also accepts a function, which `phoenix` calls on every connect;
 * widening `token` to `string | (() => string)` is the change, and it is left
 * for whoever has a reason to make it.
 */

import { Socket } from "phoenix";

/** The part of `phoenix`'s `Push` this wrapper uses. */
export type PushLike = {
  receive(status: string, callback: (payload?: unknown) => void): PushLike;
};

/** The part of `phoenix`'s `Channel` this wrapper uses. */
export type ChannelLike = {
  join(): PushLike;
  leave(): PushLike;
  on(event: string, callback: (payload: unknown) => void): number;
  push(event: string, payload: object): PushLike;
};

/** The part of `phoenix`'s `Socket` this wrapper uses. */
export type SocketLike = {
  connect(): void;
  disconnect(callback?: () => void): void;
  channel(topic: string, params?: object): ChannelLike;
};

/**
 * Everything this module hands `phoenix`.
 *
 * One key, deliberately. `params` is absent from the type rather than merely
 * unused, so that adding it back is a decision somebody has to type out.
 */
export type SocketOptions = {
  readonly authToken: string;
};

export type SocketFactory = (endpoint: string, options: SocketOptions) => SocketLike;

export type SessionSocketConfig = {
  /**
   * Where the socket is mounted. `/socket` is the Phoenix default and the value
   * U7 is most likely to use; it is configuration because U7 decides, not this
   * module.
   */
  readonly endpoint: string;

  /**
   * The bearer token from `POST /api/log-in/token`, verbatim.
   *
   * Captured when the socket is built. See the note on re-login above.
   */
  readonly token: string;

  /** Injected by the tests. Production passes nothing and gets `phoenix`. */
  readonly createSocket?: SocketFactory;
};

export type JoinOptions = {
  /** Join params, passed to the channel untouched. */
  readonly params?: object;

  /**
   * Handlers by event name. The names are the caller's — this module has none.
   */
  readonly events?: Readonly<Record<string, (payload: unknown) => void>>;

  readonly onJoined?: (payload: unknown) => void;

  /**
   * The server refused the join, and the topic has already been left.
   *
   * Called at most once per subscription. Whatever a refusal means — a
   * revoked engagement, a closed room, a topic that never existed — it is the
   * caller's to interpret, and the caller should drop the surface rather than
   * offer a retry that cannot succeed.
   */
  readonly onRefused?: (payload: unknown) => void;

  /** The join timed out. Phoenix will try again; nothing has been decided. */
  readonly onTimeout?: () => void;
};

export type TopicSubscription = {
  readonly topic: string;
  leave(): void;
  push(event: string, payload: object): void;
};

export type SessionSocket = {
  connect(): void;
  /** Leaves every topic this socket joined, then closes the connection. */
  disconnect(): void;
  join(topic: string, options: JoinOptions): TopicSubscription;
};

const defaultSocketFactory: SocketFactory = (endpoint, options) =>
  new Socket(endpoint, options);

export function createSessionSocket(config: SessionSocketConfig): SessionSocket {
  const createSocket = config.createSocket ?? defaultSocketFactory;
  const socket = createSocket(config.endpoint, { authToken: config.token });

  let connected = false;
  const subscriptions = new Set<TopicSubscription>();

  function join(topic: string, options: JoinOptions): TopicSubscription {
    const channel = socket.channel(topic, options.params);
    let left = false;

    for (const [event, handler] of Object.entries(options.events ?? {})) {
      channel.on(event, handler);
    }

    const subscription: TopicSubscription = {
      topic,
      leave() {
        if (left) return;
        left = true;
        subscriptions.delete(subscription);
        channel.leave();
      },
      push(event, payload) {
        // A push after leaving is a bug in the caller rather than something to
        // buffer: `phoenix` would queue it against a channel that is never
        // going to rejoin.
        if (left) return;
        channel.push(event, payload);
      },
    };

    subscriptions.add(subscription);

    channel
      .join()
      .receive("ok", (payload) => {
        // A caller that has already left has torn down whatever it would have
        // done with this; the reply is just in flight behind the leave.
        if (left) return;

        options.onJoined?.(payload);
      })
      .receive("error", (payload) => {
        // The first refusal is the whole answer. `subscription.leave()` is
        // idempotent, so the rejoin refusals that follow it in flight are
        // silent rather than a second callback and a second leave.
        if (left) return;
        subscription.leave();
        options.onRefused?.(payload);
      })
      .receive("timeout", () => {
        options.onTimeout?.();
      });

    return subscription;
  }

  return {
    connect() {
      if (connected) return;
      connected = true;
      socket.connect();
    },

    disconnect() {
      for (const subscription of [...subscriptions]) subscription.leave();
      connected = false;
      socket.disconnect();
    },

    join,
  };
}
