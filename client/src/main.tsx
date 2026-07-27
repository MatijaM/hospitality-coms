import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";

import { createApiClient } from "./api/client";
import { App } from "./app/app";
import { SessionProvider } from "./session/session-context";
import { createLocalStorageTokenStore } from "./session/token-store";
import "./index.css";

// Built once, at module scope, so that their identities are stable: the
// session provider's effect depends on both, and a client rebuilt on every
// render would re-ask `GET /api/me` for ever.
const api = createApiClient({ baseUrl: import.meta.env.VITE_API_BASE_URL ?? "" });
const tokenStore = createLocalStorageTokenStore(window.localStorage);

const container = document.getElementById("root");

if (container === null) throw new Error("index.html has no #root element");

createRoot(container).render(
  <StrictMode>
    <BrowserRouter>
      <SessionProvider api={api} tokenStore={tokenStore}>
        <App />
      </SessionProvider>
    </BrowserRouter>
  </StrictMode>,
);
