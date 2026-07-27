/**
 * The surface a magic link lands on.
 *
 * The redemption is attempted once per token and the guard is a ref rather
 * than an effect dependency: a link is single use, so a second attempt would
 * meet a 401 and tell the worker their working link was invalid. React's
 * StrictMode mounts every component twice in development, which is exactly
 * that second attempt.
 *
 * Invalid, expired and already-used are one answer from the server on purpose,
 * so they are one message here.
 */

import { useEffect, useRef, useState } from "react";
import { Link, Navigate, useParams } from "react-router";

import type { RequestFailure } from "../../api/errors";
import { useSession } from "../../session/session-context";
import { failureMessage } from "../failure-message";

export function RedeemRoute() {
  const { state, redeem } = useSession();
  const { linkToken } = useParams();
  const [failure, setFailure] = useState<RequestFailure | null>(null);
  const attempted = useRef<string | null>(null);

  useEffect(() => {
    if (linkToken === undefined) return;
    if (attempted.current === linkToken) return;

    attempted.current = linkToken;

    void redeem(linkToken).then((outcome) => {
      if (outcome.ok) return;

      setFailure(outcome.failure);
    });
  }, [linkToken, redeem]);

  if (state.status === "authenticated") return <Navigate to="/" replace />;
  if (failure === null) return <p role="status">Logging you in…</p>;

  return (
    <section>
      <h1>That link did not work</h1>
      <p role="alert">
        {failure.kind === "api_error" && failure.code === "unauthorized"
          ? "That link is invalid, or it has expired, or it has already been used."
          : failureMessage(failure)}
      </p>
      <Link to="/log-in">Ask for a new link</Link>
    </section>
  );
}
