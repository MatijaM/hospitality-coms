import { describe, expect, it, vi } from "vitest";

import { createSessionSocket } from "./session-socket";
import type { ChannelLike, PushLike, SocketLike } from "./session-socket";

/**
 * A `Push` whose `receive` hooks can be fired by hand, which is what the real
 * one does on every rejoin attempt: `Push.reset()` clears the response but
 * keeps `recHooks`, so a caller's `receive("error")` callback runs again each
 * time the rejoin timer resends the join.
 */
class FakePush implements PushLike {
  hooks = new Map<string, ((payload: unknown) => void)[]>();

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

class FakeChannel implements ChannelLike {
  topic: string;
  params: object | undefined;
  joinPush = new FakePush();
  leavePush = new FakePush();
  joins = 0;
  leaves = 0;
  handlers = new Map<string, (payload: unknown) => void>();
  pushed: { event: string; payload: object }[] = [];

  constructor(topic: string, params?: object) {
    this.topic = topic;
    this.params = params;
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
    this.pushed.push({ event, payload });

    return new FakePush();
  }
}

class FakeSocket implements SocketLike {
  endpoint: string;
  options: { params?: object };
  connects = 0;
  disconnects = 0;
  channels: FakeChannel[] = [];

  constructor(endpoint: string, options: { params?: object }) {
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
}

function build(token = "c2Vzc2lvbg") {
  const socket = new FakeSocket("", {});

  const sessionSocket = createSessionSocket({
    endpoint: "/socket",
    token,
    createSocket: (endpoint, options) => {
      socket.endpoint = endpoint;
      socket.options = options;

      return socket;
    },
  });

  sessionSocket.connect();

  return { sessionSocket, socket };
}

describe("connecting", () => {
  it("carries the session token in the socket params rather than the URL", () => {
    const { socket } = build("c2Vzc2lvbi10b2tlbg");

    expect(socket.endpoint).toBe("/socket");
    expect(socket.options.params).toEqual({ token: "c2Vzc2lvbi10b2tlbg" });
    expect(socket.connects).toBe(1);
  });

  it("connects once however many times connect is called", () => {
    const { sessionSocket, socket } = build();

    sessionSocket.connect();
    sessionSocket.connect();

    expect(socket.connects).toBe(1);
  });

  it("disconnects the underlying socket", () => {
    const { sessionSocket, socket } = build();

    sessionSocket.disconnect();

    expect(socket.disconnects).toBe(1);
  });

  it("lets the caller name the token parameter, because U7 owns the socket's contract", () => {
    let seen: { params?: object } | null = null;

    createSessionSocket({
      endpoint: "/socket",
      token: "c2Vzc2lvbg",
      tokenParam: "api_token",
      createSocket: (_endpoint, options) => {
        seen = options;

        return new FakeSocket("/socket", options);
      },
    }).connect();

    expect(seen).toEqual({ params: { api_token: "c2Vzc2lvbg" } });
  });
});

describe("joining a topic", () => {
  it("passes the topic and its params through untouched", () => {
    const { sessionSocket, socket } = build();

    sessionSocket.join("some:topic", { params: { since: 7 } });

    expect(socket.channels[0]?.topic).toBe("some:topic");
    expect(socket.channels[0]?.params).toEqual({ since: 7 });
    expect(socket.channels[0]?.joins).toBe(1);
  });

  it("registers the caller's event handlers under the caller's own names", () => {
    const { sessionSocket, socket } = build();
    const onMessage = vi.fn();

    sessionSocket.join("some:topic", { events: { some_event: onMessage } });
    socket.channels[0]?.handlers.get("some_event")?.({ body: "hello" });

    expect(onMessage).toHaveBeenCalledWith({ body: "hello" });
  });

  it("reports a successful join with the server's payload", () => {
    const { sessionSocket, socket } = build();
    const onJoined = vi.fn();

    sessionSocket.join("some:topic", { onJoined });
    socket.channels[0]?.joinPush.trigger("ok", { state: "open" });

    expect(onJoined).toHaveBeenCalledWith({ state: "open" });
    expect(socket.channels[0]?.leaves).toBe(0);
  });
});

describe("a refused join", () => {
  it("leaves the topic instead of retrying into the same refusal", () => {
    const { sessionSocket, socket } = build();
    const onRefused = vi.fn();

    sessionSocket.join("some:topic", { onRefused });
    socket.channels[0]?.joinPush.trigger("error", { reason: "whatever U7 sends" });

    expect(onRefused).toHaveBeenCalledWith({ reason: "whatever U7 sends" });
    expect(socket.channels[0]?.leaves).toBe(1);
  });

  it("reports once and leaves once however many times the rejoin is refused", () => {
    const { sessionSocket, socket } = build();
    const onRefused = vi.fn();

    sessionSocket.join("some:topic", { onRefused });
    const channel = socket.channels[0];
    channel?.joinPush.trigger("error", { reason: "revoked" });
    channel?.joinPush.trigger("error", { reason: "revoked" });
    channel?.joinPush.trigger("error", { reason: "revoked" });

    expect(onRefused).toHaveBeenCalledTimes(1);
    expect(channel?.leaves).toBe(1);
  });

  it("does not treat a join timeout as a refusal, so the rejoin timer is left alone", () => {
    const { sessionSocket, socket } = build();
    const onRefused = vi.fn();
    const onTimeout = vi.fn();

    sessionSocket.join("some:topic", { onRefused, onTimeout });
    socket.channels[0]?.joinPush.trigger("timeout");

    expect(onTimeout).toHaveBeenCalledOnce();
    expect(onRefused).not.toHaveBeenCalled();
    expect(socket.channels[0]?.leaves).toBe(0);
  });
});

describe("a subscription", () => {
  it("leaves once however many times the caller leaves it", () => {
    const { sessionSocket, socket } = build();

    const subscription = sessionSocket.join("some:topic", {});
    subscription.leave();
    subscription.leave();

    expect(socket.channels[0]?.leaves).toBe(1);
  });

  it("forwards a push to the channel", () => {
    const { sessionSocket, socket } = build();

    sessionSocket.join("some:topic", {}).push("some_event", { body: "hello" });

    expect(socket.channels[0]?.pushed).toEqual([
      { event: "some_event", payload: { body: "hello" } },
    ]);
  });

  it("does not push after it has been left", () => {
    const { sessionSocket, socket } = build();

    const subscription = sessionSocket.join("some:topic", {});
    subscription.leave();
    subscription.push("some_event", { body: "too late" });

    expect(socket.channels[0]?.pushed).toEqual([]);
  });

  it("is left when the socket is disconnected", () => {
    const { sessionSocket, socket } = build();

    sessionSocket.join("one:topic", {});
    sessionSocket.join("two:topic", {});
    sessionSocket.disconnect();

    expect(socket.channels.map((channel) => channel.leaves)).toEqual([1, 1]);
  });
});
