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

// `TokenStore` says its three operations do not throw. These two hold the
// application to that even when a store handed in from outside does not: a
// storage failure must never become a rejected promise, because every caller
// of `redeem` and `logOut` is an event handler that voids the result.
function persist(tokenStore: TokenStore, token: string): void {
  try {
    tokenStore.write(token);
  } catch {
    // The session is real; it just will not survive a refresh.
  }
}

function forget(tokenStore: TokenStore): void {
  try {
    tokenStore.clear();
  } catch {
    // Nothing to remove, or nothing that can be. The state says anonymous
    // either way, which is what the person asked for.
  }
}

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
      // Two ways this answer can be about a session nobody is in any more.
      //
      // `abandoned` covers the effect being torn down — StrictMode's double
      // mount, and every retry.
      //
      // The store check covers the one that is not a teardown at all: a
      // redemption landing while this request is in flight replaces the token
      // without unmounting anything, and `redeem` writes the new token to the
      // store before it touches state. So an answer about a token the store no
      // longer holds is stale by definition. Applying it either way is wrong,
      // and applying a stale 401 is worse than wrong — it clears a credential
      // that was just issued and sends the worker back to their inbox.
      if (abandoned || tokenStore.read() !== token) return;

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

      // `TokenStore` promises not to throw and the implementations here keep
      // that promise, but this call site is the one where breaking it costs
      // most: the token has been issued, the session is real, and rejecting
      // out of here would strand a caller that `void`s the promise on
      // "Logging you in…" while throwing away a working credential. So the
      // session is established whether or not it was persisted.
      persist(tokenStore, result.value.token);
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

    forget(tokenStore);
    setState({ status: "anonymous" });
  }, [api, tokenStore, state]);

  const retry = useCallback(() => {
    // Asked here rather than in the effect, where a synchronous `setState`
    // would be a cascading render. If the token went while the retry button
    // was on screen — a log-out in another tab — the effect would find nothing
    // to ask about and return, leaving `resolving` on screen for ever.
    if (tokenStore.read() === null) {
      setState({ status: "anonymous" });

      return;
    }

    setState({ status: "resolving" });
    setAttempt((previous) => previous + 1);
  }, [tokenStore]);

  const value = useMemo(
    () => ({ state, api, redeem, logOut, retry }),
    [state, api, redeem, logOut, retry],
  );

  return <SessionContext value={value}>{children}</SessionContext>;
}
