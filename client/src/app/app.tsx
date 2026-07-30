/**
 * The routing shell.
 *
 * Nine routes. `/rooms` is U7's, `/peers` is U8's and `/profile` is U9's, and
 * they are the three surfaces here that need a socket. `/` renders all three
 * in tabs and keeps its own; the three paths are what every test above those
 * surfaces enters through, so they stay whatever the landing page does. What is left of the plan
 * — archived engagements, erasure, the demo controls — still needs an endpoint
 * or a channel that does not exist, and a placeholder route for one would be a
 * guess at a URL somebody else is about to choose.
 *
 * **`/employer` and `/claim` are the two halves of one gesture and are two
 * routes rather than one screen with a mode.** They are used by two different
 * people in two different windows at the same time — that is the whole of the
 * demo — and a mode switch would put a manager one wrong click away from a
 * claim box and a new starter one wrong click away from issuing offers at a
 * venue they do not manage. `/claim` is deliberately not under `/employer`
 * either, mirroring `POST /api/claims` not being under `/api/employer`: a
 * claimant needs no authority anywhere.
 *
 * Both sit behind `RequireSession` like every other surface. The claimant needs
 * their **own** session — the code confers a job, not a log-in — and that is
 * the property the second demo window exists to show.
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
 * surface here touches a browser global. **`/` takes it too**, because the
 * landing page renders the rooms surface in a tab; it is the same store the
 * `/rooms` route gets, so a room added through one door is listed at the other.
 *
 * `/log-in/:linkToken` matches the shape of a real magic link:
 * `MAGIC_LINK_BASE_URL` defaults to `http://localhost:5173/log-in/` — this
 * client — and the token is appended to it, so a mailed link lands here and
 * redeems on arrival. It pointed at Phoenix until #46, which is why the paste
 * box under the log-in form exists and why it is kept.
 */

import { Route, Routes } from "react-router";

import { ClaimPanel } from "../features/claim/claim-panel";
import { EmployerRoute } from "../features/employer/employer-route";
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
              <HomeRoute roomStore={roomStore} />
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
        <Route
          path="/employer"
          element={
            <RequireSession>
              <EmployerRoute />
            </RequireSession>
          }
        />
        <Route
          path="/claim"
          element={
            <RequireSession>
              <ClaimPanel />
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
