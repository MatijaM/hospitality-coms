/**
 * The one place a socket is opened, and the first thing in this client to open
 * one at all.
 *
 * The foundation built `createSessionSocket` and deliberately left it
 * unconnected, because there was no topic to join. There is now.
 *
 * ## The socket is the session's, and is rebuilt when the session changes
 *
 * `phoenix` closes over `authToken` when the socket is constructed, so a socket
 * carries the token it was built with for its whole life — across every
 * reconnect. A re-login therefore needs a *new* socket rather than a reconnect
 * of this one, which is why the effect below keys on the token and tears the
 * old socket down in its cleanup. Widening `token` to a function is the
 * alternative `session-socket.ts` documents, and it buys nothing here: the
 * cases where the token changes are log-in and log-out, and both want the
 * channels torn down anyway.
 *
 * ## `null` is a state, not an absence
 *
 * Consumers get `SessionSocket | null` and `null` means "there is no transport
 * for this session", which is a real thing to render: nobody is signed in.
 * Every room surface has a sentence for it rather than an empty panel.
 */

import type { ReactNode } from "react";
import { createContext, use, useEffect, useMemo } from "react";

import { useSession } from "../session/session-context";
import type { SessionSocket, SocketFactory } from "./session-socket";
import { createSessionSocket } from "./session-socket";

/**
 * Where `HospitalityComsWeb.Endpoint` mounts `PersonSocket`.
 *
 * **Not `/socket`.** The foundation recorded that path as a guess — "the
 * Phoenix default and what the Vite proxy assumes" — and it was wrong: U7
 * mounts two sockets, `socket "/socket/person", PersonSocket` and
 * `socket "/socket/employer", EmployerSocket`, because KTD9 splits them so an
 * employer session cannot be routed to a peer conversation. There is nothing at
 * `/socket`, and asking for it gets a 404 on the upgrade, which `phoenix` then
 * retries on its backoff for ever with nothing in the client to say why.
 *
 * Found by `session-socket.integration.test.ts` against a real server. It is
 * the reason that file exists.
 *
 * `phoenix` appends `/websocket` itself, and the Vite dev server proxies
 * everything under `/socket` with `ws: true`, so this is same-origin in
 * development exactly as `/api` is.
 */
export const PERSON_SOCKET_ENDPOINT = "/socket/person";

const SocketContext = createContext<SessionSocket | null>(null);

/**
 * The socket for the current session, or `null` while there is not one.
 *
 * Not a throwing hook like `useSession`: a surface rendered outside a provider
 * and a surface rendered before the effect has run want the same fallback, and
 * a throw would turn "the transport is not up yet" into a blank page.
 */
export function useSessionSocket(): SessionSocket | null {
  return use(SocketContext);
}

export type SocketProviderProps = {
  readonly children: ReactNode;
  /** Injected by the tests. Production passes nothing and gets `phoenix`. */
  readonly createSocket?: SocketFactory;
  readonly endpoint?: string;
};

export function SocketProvider({
  children,
  createSocket,
  endpoint = PERSON_SOCKET_ENDPOINT,
}: SocketProviderProps) {
  const { state } = useSession();
  const token = state.status === "authenticated" ? state.token : null;

  // Building is separated from connecting on purpose, and it is what keeps
  // this component free of state. `new Socket(...)` opens nothing — `phoenix`
  // does not touch the network until `connect()` — so construction is cheap
  // enough to be a memo, and connecting is the effect. Under StrictMode the
  // memo may run twice; the discarded socket never connected.
  const socket = useMemo<SessionSocket | null>(() => {
    if (token === null) return null;

    // `exactOptionalPropertyTypes` is on, so an absent factory is an absent
    // key rather than an explicit `undefined`.
    return createSessionSocket({
      endpoint,
      token,
      ...(createSocket === undefined ? {} : { createSocket }),
    });
  }, [token, endpoint, createSocket]);

  useEffect(() => {
    if (socket === null) return;

    socket.connect();

    return () => {
      // Leaves every topic first, so the server sees a `phx_leave` rather than
      // a connection that stopped answering.
      socket.disconnect();
    };
  }, [socket]);

  return <SocketContext value={socket}>{children}</SocketContext>;
}
