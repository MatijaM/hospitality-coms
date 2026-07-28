/**
 * The routing shell.
 *
 * Seven routes. `/rooms` is U7's, `/peers` is U8's and `/profile` is U9's, and
 * they are the three surfaces here that need a socket. What is left of the plan
 * — archived engagements, erasure, the demo controls — still needs an endpoint
 * or a channel that does not exist, and a placeholder route for one would be a
 * guess at a URL somebody else is about to choose.
 *
 * **`/profile` is the one route here whose channel does not exist either**, and
 * that is a deliberate exception rather than the rule quietly bending: U9
 * settled the shapes and added no transport, so the surface is built against
 * the shapes with the envelope written down in one place. Read
 * `features/profile/contract.ts` before assuming anything behind this route
 * answers.
 *
 * `/peers` and `/profile` take no prop, and that is the difference between them
 * and `/rooms` worth noticing here: both channels enumerate their own lists, so
 * neither surface holds anything this file would have to build once and hand
 * in.
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

import { PeersRoute } from "../features/peers/peers-route";
import { ProfileRoute } from "../features/profile/profile-route";
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
        <Route
          path="/peers"
          element={
            <RequireSession>
              <PeersRoute />
            </RequireSession>
          }
        />
        <Route
          path="/profile"
          element={
            <RequireSession>
              <ProfileRoute />
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
