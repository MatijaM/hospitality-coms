/**
 * A stand-in for `phoenix`'s socket, modelled on what `phoenix` actually does.
 *
 * `fake-api.ts` fakes the API client for the surfaces above it; this is the
 * same seam for the transport. It is shared rather than written twice because
 * the one behaviour the room surfaces have to be tested against —
 * **`phoenix` retries a refused join for ever** — is only worth asserting if
 * the fake reproduces it, and a fake that reproduces it has to be the same fake
 * `session-socket.test.ts` uses to assert the wrapper's half.
 *
 * Three details are copied from `phoenix` rather than invented:
 *
 *   * `Push.reset()` clears the response and keeps `recHooks`, so a caller's
 *     `receive("error")` callback fires **again** on every rejoin attempt.
 *     `FakePush.trigger` therefore never removes a hook.
 *   * `Channel.rejoinTimer` resends the same join push, and `Channel.onClose`
 *     resets that timer. So `FakeChannel.rejoin()` counts another join unless
 *     the channel has been left, which is what makes `joins` a measurement of
 *     a retry loop rather than a count of calls.
 *   * `Channel.push` answers on `"ok"`, `"error"` or `"timeout"` and on
 *     nothing else, so a reply is delivered by naming one of the three.
 *
 * ## What it does **not** model, and why that is safe today
 *
 * Compared line by line against `channel.js` and `push.js`, two behaviours are
 * absent. Both are inert for the tests here, and both stop being inert the
 * moment somebody writes a test that needs them — so they are written down
 * rather than left to be discovered by a test that passes for the wrong reason.
 *
 *   * **`pushBuffer` and `canPush()`.** The real `Channel.push` buffers when
 *     the channel is not joined and flushes on join; this fake sends
 *     immediately whatever the state. Nothing here pushes before "joined" —
 *     `Composer` requires `connection.status === "joined"` — so no test can
 *     currently tell the difference. A test for a send issued while the link is
 *     down would need it.
 *   * **`Socket.remove(channel)` on close.** The real socket drops a left
 *     channel from `Socket.channels`, so its rejoin timer cannot be fired by a
 *     reconnect; here a left `FakeChannel` stays in `socket.channels` and
 *     `fireRejoinTimers` visits it, relying on `rejoin()`'s own `left` guard
 *     for the same answer. That guard is the property under test, so this is a
 *     *weaker* fake rather than a more forgiving one — but a test that counted
 *     entries in `socket.channels` expecting the real removal would be wrong.
 */

import type {
  ChannelLike,
  PushLike,
  SocketLike,
  SocketOptions,
} from "../socket/session-socket";

/** A `Push` whose `receive` hooks can be fired by hand, as often as needed. */
export class FakePush implements PushLike {
  hooks = new Map<string, ((payload?: unknown) => void)[]>();

  receive(status: string, callback: (payload?: unknown) => void): this {
    const existing = this.hooks.get(status) ?? [];
    existing.push(callback);
    this.hooks.set(status, existing);

    return this;
  }

  trigger(status: string, payload?: unknown): void {
    for (const callback of this.hooks.get(status) ?? []) callback(payload);
  }
}

/** One push the client sent, and the handle a test answers it on. */
export type SentPush = {
  readonly event: string;
  readonly payload: object;
  readonly push: FakePush;
};

export class FakeChannel implements ChannelLike {
  topic: string;
  params: object | undefined;
  joinPush = new FakePush();
  leavePush = new FakePush();
  joins = 0;
  leaves = 0;
  handlers = new Map<string, (payload: unknown) => void>();
  sent: SentPush[] = [];

  constructor(topic: string, params?: object) {
    this.topic = topic;
    this.params = params;
  }

  /** Everything sent on this channel, in order, as `{event, payload}`. */
  get pushed(): { event: string; payload: object }[] {
    return this.sent.map(({ event, payload }) => ({ event, payload }));
  }

  get left(): boolean {
    return this.leaves > 0;
  }

  join(): PushLike {
    this.joins += 1;

    return this.joinPush;
  }

  leave(): PushLike {
    this.leaves += 1;

    return this.leavePush;
  }

  on(event: string, callback: (payload: unknown) => void): number {
    this.handlers.set(event, callback);

    return this.handlers.size;
  }

  push(event: string, payload: object): PushLike {
    const push = new FakePush();
    this.sent.push({ event, payload, push });

    return push;
  }

  /** Delivers a server-pushed event, if the client registered a handler. */
  emit(event: string, payload: unknown): void {
    this.handlers.get(event)?.(payload);
  }

  /**
   * What `phoenix`'s rejoin timer does when it fires.
   *
   * A channel that has been left has had `rejoinTimer.reset()` called through
   * `onClose`, so nothing happens — which is the whole of why leaving a refused
   * topic stops the loop, and why `joins` staying at 1 is evidence rather than
   * a restatement.
   */
  rejoin(): void {
    if (this.left) return;

    this.joins += 1;
    this.joinPush.trigger("error", { reason: "the same refusal as last time" });
  }

  /** Answers the nth push this channel received. */
  reply(index: number, status: "ok" | "error" | "timeout", payload?: unknown): void {
    this.sent[index]?.push.trigger(status, payload);
  }

  /** Answers the most recent push this channel received. */
  replyToLast(status: "ok" | "error" | "timeout", payload?: unknown): void {
    this.reply(this.sent.length - 1, status, payload);
  }
}

type Deferred = { readonly promise: Promise<void>; resolve: () => void };

function deferred(): Deferred {
  let resolve: () => void = () => undefined;
  const promise = new Promise<void>((settle) => {
    resolve = settle;
  });

  return { promise, resolve };
}

export class FakeSocket implements SocketLike {
  endpoint: string;
  options: SocketOptions;
  connects = 0;
  disconnects = 0;
  channels: FakeChannel[] = [];

  private readonly firstConnect = deferred();
  private readonly firstDisconnect = deferred();

  constructor(endpoint: string, options: SocketOptions) {
    this.endpoint = endpoint;
    this.options = options;
  }

  /**
   * Resolves the first time `connect()` is called, and never on a timer.
   *
   * A React test needs a synchronisation point for a fact an **effect**
   * produces, and the rendered tree is not one: React commits the DOM and
   * flushes passive effects in two separate steps, so a `waitFor` watching the
   * DOM can resolve in the window between them. `SocketProvider` publishes the
   * socket from a `useMemo` — during render — and connects it from an effect,
   * which is exactly that window, and asserting `connects` after a DOM wait
   * failed about one run in ten.
   *
   * Awaiting this instead waits for the call itself. It cannot pass because
   * the machine was fast, and if the effect never runs the test times out
   * rather than reporting a wrong number.
   */
  get opened(): Promise<void> {
    return this.firstConnect.promise;
  }

  /** Resolves the first time `disconnect()` is called. See `opened`. */
  get closed(): Promise<void> {
    return this.firstDisconnect.promise;
  }

  connect(): void {
    this.connects += 1;
    this.firstConnect.resolve();
  }

  disconnect(callback?: () => void): void {
    this.disconnects += 1;
    this.firstDisconnect.resolve();
    callback?.();
  }

  channel(topic: string, params?: object): ChannelLike {
    const channel = new FakeChannel(topic, params);
    this.channels.push(channel);

    return channel;
  }

  /** Every channel ever opened for a topic, left ones included. */
  channelsFor(topic: string): FakeChannel[] {
    return this.channels.filter((channel) => channel.topic === topic);
  }

  /** The channel most recently opened for a topic. */
  channelFor(topic: string): FakeChannel | undefined {
    return this.channelsFor(topic).at(-1);
  }

  /** Fires every channel's rejoin timer, as a reconnect or a backoff would. */
  fireRejoinTimers(times = 1): void {
    for (let attempt = 0; attempt < times; attempt += 1) {
      for (const channel of this.channels) channel.rejoin();
    }
  }
}

/**
 * A `SocketFactory` that hands back one `FakeSocket` and records what it was
 * built with, so a test can assert on the endpoint and the token.
 */
export function fakeSocketFactory(): {
  socket: FakeSocket;
  createSocket: (endpoint: string, options: SocketOptions) => SocketLike;
} {
  const socket = new FakeSocket("", { authToken: "" });

  return {
    socket,
    createSocket: (endpoint, options) => {
      socket.endpoint = endpoint;
      socket.options = options;

      return socket;
    },
  };
}
