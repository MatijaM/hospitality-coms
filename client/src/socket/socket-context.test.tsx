import { render, screen, waitFor } from "@testing-library/react";
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

describe("the session's socket", () => {
  it("opens once the session resolves, carrying the token as authToken", async () => {
    const { socket } = renderProbe();

    await waitFor(() => {
      expect(screen.getByTestId("transport")).toHaveTextContent("up");
    });

    // `/socket/person`, not `/socket`. Two sockets are mounted under the
    // prefix (KTD9) and there is nothing at the prefix itself; asking for it
    // 404s the upgrade and `phoenix` retries that on its backoff for ever.
    expect(socket.endpoint).toBe(PERSON_SOCKET_ENDPOINT);
    expect(socket.endpoint).toBe("/socket/person");
    expect(socket.options).toEqual({ authToken: "c2Vzc2lvbg" });
    expect(socket.connects).toBe(1);
  });

  it("opens nothing at all for a session that has not resolved or does not exist", () => {
    const { socket } = renderProbe({ tokenStore: createMemoryTokenStore(null) });

    expect(screen.getByTestId("transport")).toHaveTextContent("none");
    expect(socket.connects).toBe(0);
  });

  it("closes the socket when the session ends", async () => {
    const { socket } = renderProbe();

    await waitFor(() => {
      expect(screen.getByTestId("transport")).toHaveTextContent("up");
    });
    await userEvent.click(screen.getByRole("button", { name: /log out/i }));

    await waitFor(() => {
      expect(screen.getByTestId("transport")).toHaveTextContent("none");
    });
    expect(socket.disconnects).toBe(1);
  });

  it("leaves exactly one connection open through StrictMode's double mount", async () => {
    // `phoenix` closes over `authToken` at construction, so a socket per mount
    // is a socket per session token — and two live transports for one session
    // means every broadcast arrives twice.
    const { socket } = renderProbe({ strict: true });

    await waitFor(() => {
      expect(screen.getByTestId("transport")).toHaveTextContent("up");
    });

    expect(socket.connects - socket.disconnects).toBe(1);
  });
});
