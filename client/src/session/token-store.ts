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

export type TokenStore = {
  read(): string | null;
  write(token: string): void;
  clear(): void;
};

export const SESSION_TOKEN_KEY = "hospitality-coms.session-token";

export function createLocalStorageTokenStore(
  storage: Storage,
  key: string = SESSION_TOKEN_KEY,
): TokenStore {
  return {
    read: () => storage.getItem(key),
    write: (token) => {
      storage.setItem(key, token);
    },
    clear: () => {
      storage.removeItem(key);
    },
  };
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
