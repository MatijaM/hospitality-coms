/**
 * The routing shell.
 *
 * Four routes, because there are four things this client can do. Every other
 * surface the plan describes — rooms, peers, the profile, disclosure, archived
 * engagements — needs an endpoint or a channel that does not exist yet, and a
 * placeholder route for one would be a guess at a URL somebody else is about to
 * choose.
 *
 * `/log-in/:linkToken` matches the shape of a real magic link:
 * `MAGIC_LINK_BASE_URL` defaults to `http://localhost:4000/log-in/` and the
 * token is appended to it, so a link that points at this client lands here.
 */

import { Route, Routes } from "react-router";

import { HomeRoute } from "./routes/home-route";
import { LogInRoute } from "./routes/log-in-route";
import { NotFoundRoute } from "./routes/not-found-route";
import { RedeemRoute } from "./routes/redeem-route";
import { RequireSession } from "./require-session";

export function App() {
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
        <Route path="/log-in" element={<LogInRoute />} />
        <Route path="/log-in/:linkToken" element={<RedeemRoute />} />
        <Route path="*" element={<NotFoundRoute />} />
      </Routes>
    </main>
  );
}
