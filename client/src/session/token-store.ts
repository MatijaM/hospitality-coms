/**
 * Where the session token lives between page loads.
 *
 * The token is the credential — a row in `people_tokens`, base64url on the
 * wire, SHA-256 in the column — so anything that can read it can act as the
 * worker until the row is deleted. In a browser that means script running on
 * this origin, and `localStorage` is chosen with that understood: there is no
 * cookie session to use instead, an `HttpOnly` cookie is not readable by the
 * `fetch` calls that need to send it as a bearer header, and holding it in
 * memory alone would log the worker out on every refresh.
 *
 * It is an interface rather than a direct `localStorage` call so that tests get
 * a store without touching a global, and so that a later unit can move it
 * without hunting for the string key.
 */

/**
 * None of these three may throw.
 *
 * That is part of the contract rather than an implementation detail: the
 * callers are `redeem` and `logOut`, both of which are invoked as
 * `void redeem(…).then(…)` from an event handler, so a throw becomes a rejected
 * promise nobody catches and the surface waiting on it — "Logging you in…" —
 * stays there for ever.
 */
export type TokenStore = {
  read(): string | null;
  write(token: string): void;
  clear(): void;
};

export const SESSION_TOKEN_KEY = "hospitality-coms.session-token";

/**
 * The browser's storage, with every call tolerant of a browser that refuses.
 *
 * Private-mode Safari throws `QuotaExceededError` on write and a browser with
 * site data switched off throws `SecurityError` on everything. Neither is worth
 * a blank page: a swallowed write degrades to a session that does not survive a
 * refresh, which is a bad afternoon rather than an unusable application.
 */
export function createLocalStorageTokenStore(
  storage: Storage,
  key: string = SESSION_TOKEN_KEY,
): TokenStore {
  return {
    read: () => {
      try {
        return storage.getItem(key);
      } catch {
        return null;
      }
    },
    write: (token) => {
      try {
        storage.setItem(key, token);
      } catch {
        // Documented above: the session lives for this page load only.
      }
    },
    clear: () => {
      try {
        storage.removeItem(key);
      } catch {
        // Nothing was persisted, so there is nothing to remove.
      }
    },
  };
}

/**
 * What the application actually runs on: storage if the browser has it, memory
 * if it does not.
 *
 * `window.localStorage` is typed as always present and is not. Reading the
 * property throws `SecurityError` where storage is blocked, and it is plainly
 * `undefined` under this project's own test environment, where jsdom defers to
 * Node's experimental implementation. Both of those are a TypeError at module
 * scope in `main.tsx`, which is a blank page and no error the worker can act on.
 */
export function createBrowserTokenStore(): TokenStore {
  try {
    const storage = globalThis.localStorage;
    // Use it rather than test for it. Absent, it is `undefined` and this is a
    // TypeError; blocked, it throws `SecurityError`; present, this is a read
    // of a key that is usually not there. One probe, every failure caught.
    storage.getItem(SESSION_TOKEN_KEY);

    return createLocalStorageTokenStore(storage);
  } catch {
    return createMemoryTokenStore();
  }
}

/** For tests, and for anywhere a session deliberately should not survive. */
export function createMemoryTokenStore(initial: string | null = null): TokenStore {
  let token = initial;

  return {
    read: () => token,
    write: (value) => {
      token = value;
    },
    clear: () => {
      token = null;
    },
  };
}
