/**
 * The gate in front of everything that needs a person.
 *
 * It renders each of the session's four states as a different thing, which is
 * the point of there being four. In particular `unavailable` is not treated as
 * `anonymous`: sending somebody back to the log-in surface because a request
 * failed would make them fetch a new link for a session that is still perfectly
 * good.
 */

import type { ReactNode } from "react";
import { Navigate } from "react-router";

import type { RequestFailure } from "../api/errors";
import { useSession } from "../session/session-context";
import { failureMessage } from "./failure-message";

export function RequireSession({ children }: { readonly children: ReactNode }) {
  const { state, retry } = useSession();

  switch (state.status) {
    case "resolving":
      return <p role="status">Checking your session…</p>;
    case "anonymous":
      return <Navigate to="/log-in" replace />;
    case "unavailable":
      return <Unavailable failure={state.failure} onRetry={retry} />;
    case "authenticated":
      return children;
  }
}

function Unavailable({
  failure,
  onRetry,
}: {
  readonly failure: RequestFailure;
  readonly onRetry: () => void;
}) {
  return (
    <section>
      <h1>Not right now</h1>
      <p role="alert">{failureMessage(failure)}</p>
      <p>You are still signed in. Nothing has been logged out.</p>
      <button type="button" onClick={onRetry}>
        Try again
      </button>
    </section>
  );
}
