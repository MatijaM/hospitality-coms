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

export class FakeSocket implements SocketLike {
  endpoint: string;
  options: SocketOptions;
  connects = 0;
  disconnects = 0;
  channels: FakeChannel[] = [];

  constructor(endpoint: string, options: SocketOptions) {
    this.endpoint = endpoint;
    this.options = options;
  }

  connect(): void {
    this.connects += 1;
  }

  disconnect(callback?: () => void): void {
    this.disconnects += 1;
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
