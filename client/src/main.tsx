import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";

import { createApiClient } from "./api/client";
import { App } from "./app/app";
import { createBrowserRoomStore } from "./features/rooms/room-store";
import { SessionProvider } from "./session/session-context";
import { SocketProvider } from "./socket/socket-context";
import { createBrowserTokenStore } from "./session/token-store";
import "./index.css";

// Built once, at module scope, so that their identities are stable: the
// session provider's effect depends on both, and a client rebuilt on every
// render would re-ask `GET /api/me` for ever.
//
// Nothing here may throw. This runs before React exists, so an exception is a
// blank page with the reason only in the console — which is why the token
// store is chosen by a function that copes with `localStorage` being absent or
// refusing rather than by reading `window.localStorage` directly.
const api = createApiClient({ baseUrl: import.meta.env.VITE_API_BASE_URL ?? "" });
const tokenStore = createBrowserTokenStore();
const roomStore = createBrowserRoomStore();

const container = document.getElementById("root");

if (container === null) throw new Error("index.html has no #root element");

createRoot(container).render(
  <StrictMode>
    <BrowserRouter>
      <SessionProvider
        api={api}
        tokenStore={tokenStore}
        onSessionEnded={() => {
          // Everything else this device remembers about whoever was signed in.
          // U8's peer surface adds to this list here, not inside the session.
          roomStore.clear();
        }}
      >
        <SocketProvider>
          <App roomStore={roomStore} />
        </SocketProvider>
      </SessionProvider>
    </BrowserRouter>
  </StrictMode>,
);
