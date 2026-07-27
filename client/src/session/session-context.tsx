/**
 * Who is logged in, as a state machine rather than a nullable person.
 *
 * There are four answers and they are genuinely different, so they are four
 * states and not a person that might be `null`:
 *
 * - `resolving` — a token was stored and `GET /api/me` has not answered yet.
 *   Rendering the log-in surface here would flash it at somebody who is signed
 *   in, and rendering the app would flash it at somebody who is not.
 * - `anonymous` — no token, or a token the server no longer knows.
 * - `unavailable` — a token that could not be checked. The API was
 *   unreachable, or answered in a shape this client does not recognise.
 * - `authenticated` — the token resolved to a person.
 *
 * The distinction between `anonymous` and `unavailable` is the one that
 * matters. Only `401` means the session is gone; the token row was deleted, by
 * a log-out elsewhere or by U7's revocation. Treating a failed request as a
 * log-out would throw away a live credential because a phone went through a
 * tunnel, and the worker would have to go back to their email for a new link.
 * So `unavailable` keeps the token and offers a retry.
 */

import type { ReactNode } from "react";
import { createContext, use, useCallback, useEffect, useMemo, useState } from "react";

import type { ApiClient } from "../api/client";
import type { RequestFailure } from "../api/errors";
import { isSessionExpired } from "../api/errors";
import type { Person } from "../api/types";
import type { TokenStore } from "./token-store";

export type SessionState =
  | { readonly status: "resolving" }
  | { readonly status: "anonymous" }
  | { readonly status: "unavailable"; readonly failure: RequestFailure }
  | {
      readonly status: "authenticated";
      readonly token: string;
      readonly person: Person;
    };

export type RedeemOutcome =
  { readonly ok: true } | { readonly ok: false; readonly failure: RequestFailure };

// Function-valued *properties* rather than methods, because every consumer
// destructures them off the context and a method torn off its object is what
// `unbound-method` exists to complain about.
export type SessionContextValue = {
  readonly state: SessionState;
  /** The API client, so a surface does not have to be handed one separately. */
  readonly api: ApiClient;
  readonly redeem: (linkToken: string) => Promise<RedeemOutcome>;
  readonly logOut: () => Promise<void>;
  /** Asks again after `unavailable`. */
  readonly retry: () => void;
};

const SessionContext = createContext<SessionContextValue | null>(null);

export function useSession(): SessionContextValue {
  const value = use(SessionContext);

  if (value === null) {
    throw new Error("useSession was called outside a SessionProvider");
  }

  return value;
}

export type SessionProviderProps = {
  readonly api: ApiClient;
  readonly tokenStore: TokenStore;
  readonly children: ReactNode;
};

export function SessionProvider({ api, tokenStore, children }: SessionProviderProps) {
  // The first state is computed rather than assigned in an effect: a stored
  // token means `resolving` from the very first render, and no token means
  // `anonymous` without a render in between. Setting it from an effect instead
  // renders once with a state that was never true.
  const [state, setState] = useState<SessionState>(() =>
    tokenStore.read() === null ? { status: "anonymous" } : { status: "resolving" },
  );
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    const token = tokenStore.read();

    if (token === null) return;

    let abandoned = false;

    void api.currentPerson(token).then((result) => {
      // The effect runs twice under StrictMode and again on every retry, so a
      // late answer from an abandoned run must not overwrite a newer state.
      if (abandoned) return;

      if (result.ok) {
        setState({ status: "authenticated", token, person: result.value });

        return;
      }

      if (isSessionExpired(result.failure)) {
        tokenStore.clear();
        setState({ status: "anonymous" });

        return;
      }

      setState({ status: "unavailable", failure: result.failure });
    });

    return () => {
      abandoned = true;
    };
  }, [api, tokenStore, attempt]);

  const redeem = useCallback(
    async (linkToken: string): Promise<RedeemOutcome> => {
      const result = await api.redeemMagicLink(linkToken);

      if (!result.ok) return { ok: false, failure: result.failure };

      tokenStore.write(result.value.token);
      setState({
        status: "authenticated",
        token: result.value.token,
        person: result.value.person,
      });

      return { ok: true };
    },
    [api, tokenStore],
  );

  const logOut = useCallback(async () => {
    // The API's answer is not acted on. A 401 means the row is already gone,
    // and an unreachable server means it is not — but the token is in this
    // browser and the person asked to leave, so forgetting it locally is the
    // one thing that is certainly right. The row it leaves behind expires.
    if (state.status === "authenticated") await api.logOut(state.token);

    tokenStore.clear();
    setState({ status: "anonymous" });
  }, [api, tokenStore, state]);

  const retry = useCallback(() => {
    setState({ status: "resolving" });
    setAttempt((previous) => previous + 1);
  }, []);

  const value = useMemo(
    () => ({ state, api, redeem, logOut, retry }),
    [state, api, redeem, logOut, retry],
  );

  return <SessionContext value={value}>{children}</SessionContext>;
}
