import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { describe, expect, it } from "vitest";

import type { ApiClient } from "../api/client";
import { SessionProvider, useSession } from "../session/session-context";
import type { TokenStore } from "../session/token-store";
import { createMemoryTokenStore } from "../session/token-store";
import { createFakeApi, ok, somePerson } from "../test-support/fake-api";
import type { FakeSocket } from "../test-support/fake-socket";
import { fakeSocketFactory } from "../test-support/fake-socket";
import {
  PERSON_SOCKET_ENDPOINT,
  SocketProvider,
  useSessionSocket,
} from "./socket-context";

function Probe() {
  const socket = useSessionSocket();
  const { logOut } = useSession();

  return (
    <div>
      <p data-testid="transport">{socket === null ? "none" : "up"}</p>
      <button
        type="button"
        onClick={() => {
          void logOut();
        }}
      >
        Log out
      </button>
    </div>
  );
}

function renderProbe(
  options: { api?: ApiClient; tokenStore?: TokenStore; strict?: boolean } = {},
): { socket: FakeSocket } {
  const { socket, createSocket } = fakeSocketFactory();
  const tree = (
    <SessionProvider
      api={
        options.api ??
        createFakeApi({ currentPerson: () => Promise.resolve(ok(somePerson)) })
      }
      tokenStore={options.tokenStore ?? createMemoryTokenStore("c2Vzc2lvbg")}
    >
      <SocketProvider createSocket={createSocket}>
        <Probe />
      </SocketProvider>
    </SessionProvider>
  );

  render(options.strict === true ? <StrictMode>{tree}</StrictMode> : tree);

  return { socket };
}

/**
 * Waits for something an effect did, rather than for a render that precedes it.
 *
 * **This file used to `waitFor` the rendered tree and then assert a counter an
 * effect writes, and it failed about one run in ten.** `SocketProvider`
 * publishes the socket from a `useMemo`, which runs during render, and calls
 * `connect()` from an effect. React commits the DOM and flushes passive effects
 * as two separate steps, so the probe reads "up" — and `waitFor`'s
 * MutationObserver fires — while `connects` is still 0. Nine times in ten the
 * scheduler got there first, which is the definition of a test that passes
 * because the machine was fast.
 *
 * `FakeSocket.opened` resolves when `connect()` is *called*, so awaiting it is
 * the fact itself: no polling, no interval, and no timeout to lengthen. If the
 * effect never runs the test times out, which is the honest failure.
 *
 * The await is deliberately **outside** `act`. `act(async () => await p)`
 * deadlocks: `act` awaits its callback before draining the queue, so the
 * effect that would resolve `p` never runs — measured here as all four tests
 * timing out at 5s. React drives the effect on its own scheduler instead, and
 * `settled()` afterwards drains whatever that left queued.
 */
async function until(reached: Promise<void>): Promise<void> {
  await reached;
  await settled();
}

/** Drains anything React still has queued, so a `0` means settled and zero. */
async function settled(): Promise<void> {
  await act(() => Promise.resolve());
}

describe("the session's socket", () => {
  it("opens once the session resolves, carrying the token as authToken", async () => {
    const { socket } = renderProbe();

    await until(socket.opened);

    // `/socket/person`, not `/socket`. Two sockets are mounted under the
    // prefix (KTD9) and there is nothing at the prefix itself; asking for it
    // 404s the upgrade and `phoenix` retries that on its backoff for ever.
    expect(socket.endpoint).toBe(PERSON_SOCKET_ENDPOINT);
    expect(socket.endpoint).toBe("/socket/person");
    expect(socket.options).toEqual({ authToken: "c2Vzc2lvbg" });
    expect(socket.connects).toBe(1);
    expect(screen.getByTestId("transport")).toHaveTextContent("up");
  });

  it("opens nothing at all for a session that has not resolved or does not exist", async () => {
    const { socket } = renderProbe({ tokenStore: createMemoryTokenStore(null) });

    // There is nothing to await here — the claim is that nothing happens — so
    // the flush is what stops this passing merely by being asserted early.
    await settled();

    expect(screen.getByTestId("transport")).toHaveTextContent("none");
    expect(socket.connects).toBe(0);
  });

  it("closes the socket when the session ends", async () => {
    const { socket } = renderProbe();

    await until(socket.opened);
    await userEvent.click(screen.getByRole("button", { name: /log out/i }));
    await until(socket.closed);

    expect(socket.disconnects).toBe(1);
    expect(screen.getByTestId("transport")).toHaveTextContent("none");
  });

  it("leaves exactly one connection open through StrictMode's double mount", async () => {
    // `phoenix` closes over `authToken` at construction, so a socket per mount
    // is a socket per session token — and two live transports for one session
    // means every broadcast arrives twice.
    const { socket } = renderProbe({ strict: true });

    await until(socket.opened);
    await settled();

    expect(socket.connects - socket.disconnects).toBe(1);
  });
});
