/**
 * The routing shell.
 *
 * Five routes. `/rooms` is U7's, and it is the only surface here that needs a
 * socket. The rest of what the plan describes — peers, the profile,
 * disclosure, archived engagements, the demo controls — still needs an
 * endpoint or a channel that does not exist, and a placeholder route for one
 * would be a guess at a URL somebody else is about to choose.
 *
 * The room store is a prop rather than something this file reaches for, for
 * the reason `main.tsx` gives about the API client and the token store: it is
 * built once at module scope in production and handed in by the tests, so no
 * surface here touches a browser global.
 *
 * `/log-in/:linkToken` matches the shape of a real magic link:
 * `MAGIC_LINK_BASE_URL` defaults to `http://localhost:4000/log-in/` and the
 * token is appended to it, so a link that points at this client lands here.
 */

import { Route, Routes } from "react-router";

import { RoomsRoute } from "../features/rooms/rooms-route";
import type { RoomStore } from "../features/rooms/room-store";
import { HomeRoute } from "./routes/home-route";
import { LogInRoute } from "./routes/log-in-route";
import { NotFoundRoute } from "./routes/not-found-route";
import { RedeemRoute } from "./routes/redeem-route";
import { RequireSession } from "./require-session";

export function App({ roomStore }: { readonly roomStore: RoomStore }) {
  return (
    <main className="page">
      <Routes>
        <Route
          path="/"
          element={
            <RequireSession>
              <HomeRoute />
            </RequireSession>
          }
        />
        <Route
          path="/rooms"
          element={
            <RequireSession>
              <RoomsRoute store={roomStore} />
            </RequireSession>
          }
        />
        <Route path="/log-in" element={<LogInRoute />} />
        <Route path="/log-in/:linkToken" element={<RedeemRoute />} />
        <Route path="*" element={<NotFoundRoute />} />
      </Routes>
    </main>
  );
}
