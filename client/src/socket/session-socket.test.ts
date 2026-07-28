import { describe, expect, it, vi } from "vitest";

import { fakeSocketFactory } from "../test-support/fake-socket";
import { createSessionSocket } from "./session-socket";

function build(token = "c2Vzc2lvbg") {
  const { socket, createSocket } = fakeSocketFactory();

  const sessionSocket = createSessionSocket({ endpoint: "/socket", token, createSocket });

  sessionSocket.connect();

  return { sessionSocket, socket };
}

describe("connecting", () => {
  it("hands the token to phoenix as `authToken`, which travels as a header", () => {
    const { socket } = build("c2Vzc2lvbi10b2tlbg");

    expect(socket.endpoint).toBe("/socket");
    expect(socket.options.authToken).toBe("c2Vzc2lvbi10b2tlbg");
    expect(socket.connects).toBe(1);
  });

  it("puts the token nowhere `endPointURL` would append to the query string", () => {
    // The real invariant, and the one the first version of this file got
    // wrong. `Socket.endPointURL()` is
    // `appendParams(appendParams(endPoint, params()), {vsn})`, so anything in
    // `params` — and anything in the endpoint itself — ends up in the URL, and
    // a URL ends up in access and proxy logs. `authToken` is the only option
    // that does not: it becomes a `Sec-WebSocket-Protocol` value on the
    // websocket transport and an `X-Phoenix-AuthToken` header on the longpoll
    // fallback.
    const token = "c2Vzc2lvbi10b2tlbg";
    const { socket } = build(token);
    const { authToken, ...everythingElse } = socket.options;

    expect(authToken).toBe(token);
    expect(JSON.stringify(everythingElse)).not.toContain(token);
    expect(socket.endpoint).not.toContain(token);
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

  it("sends no socket params at all, so there is no key for U7 to name", () => {
    const { socket } = build();

    expect(socket.options).toEqual({ authToken: "c2Vzc2lvbg" });
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

  it("does not report a join that arrives after the caller left", () => {
    // A component that unmounts between the join push and its reply has
    // already torn its state down; calling back into it is how a leave becomes
    // a subscription that is still delivering.
    const { sessionSocket, socket } = build();
    const onJoined = vi.fn();

    const subscription = sessionSocket.join("some:topic", { onJoined });
    subscription.leave();
    socket.channels[0]?.joinPush.trigger("ok", { state: "open" });

    expect(onJoined).not.toHaveBeenCalled();
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

  it("stops the rejoin timer, measured as a join count rather than as a leave", () => {
    // The leave assertion above says the call was made. This says what the
    // call is *for*: `Channel.onClose` resets `rejoinTimer`, so no later tick
    // resends the join push. Counting joins is the only way to see that.
    const { sessionSocket, socket } = build();
    const onRefused = vi.fn();

    sessionSocket.join("some:topic", { onRefused });
    const channel = socket.channels[0];
    channel?.joinPush.trigger("error", { reason: "revoked" });

    socket.fireRejoinTimers(5);

    expect(channel?.joins).toBe(1);
    expect(onRefused).toHaveBeenCalledOnce();
  });

  it("control: the fake does count rejoins, so a join count of 1 means something", () => {
    // Without this, the assertion above would pass just as well against a fake
    // that cannot rejoin at all — a restatement rather than a measurement.
    const { socket } = build();

    socket.channel("untouched:topic");
    const channel = socket.channelFor("untouched:topic");
    channel?.join();
    socket.fireRejoinTimers(3);

    expect(channel?.joins).toBe(4);
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

    void sessionSocket.join("some:topic", {}).push("some_event", { body: "hello" });

    expect(socket.channels[0]?.pushed).toEqual([
      { event: "some_event", payload: { body: "hello" } },
    ]);
  });

  it("does not push after it has been left, and says so rather than hanging", async () => {
    // A composer awaits this promise. Leaving the push unanswered would leave
    // the composer disabled with nothing on screen to say why.
    const { sessionSocket, socket } = build();

    const subscription = sessionSocket.join("some:topic", {});
    subscription.leave();
    const outcome = await subscription.push("some_event", { body: "too late" });

    expect(outcome).toEqual({ status: "unsent" });
    expect(socket.channels[0]?.pushed).toEqual([]);
  });

  it("resolves a push with whatever the server replied", async () => {
    const { sessionSocket, socket } = build();

    const outcome = sessionSocket.join("some:topic", {}).push("send", { body: "hi" });
    socket.channels[0]?.replyToLast("ok", { id: "written" });

    expect(await outcome).toEqual({ status: "ok", payload: { id: "written" } });
  });

  it("resolves a refused push rather than throwing at the caller", async () => {
    const { sessionSocket, socket } = build();

    const outcome = sessionSocket.join("some:topic", {}).push("send", { body: "hi" });
    socket.channels[0]?.replyToLast("error", { error: { code: "gone", message: "…" } });

    expect(await outcome).toEqual({
      status: "error",
      payload: { error: { code: "gone", message: "…" } },
    });
  });

  it("resolves a push that timed out as a timeout, not as a refusal", async () => {
    const { sessionSocket, socket } = build();

    const outcome = sessionSocket.join("some:topic", {}).push("send", { body: "hi" });
    socket.channels[0]?.replyToLast("timeout");

    expect(await outcome).toEqual({ status: "timeout" });
  });

  it("is left when the socket is disconnected", () => {
    const { sessionSocket, socket } = build();

    sessionSocket.join("one:topic", {});
    sessionSocket.join("two:topic", {});
    sessionSocket.disconnect();

    expect(socket.channels.map((channel) => channel.leaves)).toEqual([1, 1]);
  });
});
