import { afterEach, describe, expect, it, vi } from "vitest";

import {
  SESSION_TOKEN_KEY,
  createBrowserTokenStore,
  createLocalStorageTokenStore,
  createMemoryTokenStore,
} from "./token-store";

/** A `Storage` backed by a map, standing in for a browser that allows it. */
function workingStorage(): Storage {
  const entries = new Map<string, string>();

  return {
    get length(): number {
      return entries.size;
    },
    clear: () => {
      entries.clear();
    },
    getItem: (key) => entries.get(key) ?? null,
    key: (index) => [...entries.keys()][index] ?? null,
    removeItem: (key) => {
      entries.delete(key);
    },
    setItem: (key, value) => {
      entries.set(key, value);
    },
  };
}

/** A `Storage` that refuses everything, the way a browser with storage off does. */
function blockedStorage(): Storage {
  const refuse = (): never => {
    throw new DOMException("The operation is insecure.", "SecurityError");
  };

  return {
    get length(): number {
      return refuse();
    },
    clear: refuse,
    getItem: refuse,
    key: refuse,
    removeItem: refuse,
    setItem: refuse,
  };
}

describe("the memory store", () => {
  it("reads back what it wrote, and nothing after a clear", () => {
    const store = createMemoryTokenStore();

    expect(store.read()).toBeNull();
    store.write("c2Vzc2lvbg");
    expect(store.read()).toBe("c2Vzc2lvbg");
    store.clear();
    expect(store.read()).toBeNull();
  });
});

describe("the localStorage store", () => {
  it("round-trips through the browser's storage under one key", () => {
    const storage = workingStorage();
    const store = createLocalStorageTokenStore(storage);

    store.write("c2Vzc2lvbg");

    expect(storage.getItem(SESSION_TOKEN_KEY)).toBe("c2Vzc2lvbg");
    expect(store.read()).toBe("c2Vzc2lvbg");

    store.clear();

    expect(store.read()).toBeNull();
  });

  it("degrades to a session that does not survive a refresh when storage is blocked", () => {
    // Private-mode Safari and a browser with site data switched off both throw
    // here. The whole application rendering nothing is a much worse answer
    // than a session that has to be re-established on the next page load.
    const store = createLocalStorageTokenStore(blockedStorage());

    expect(() => {
      store.write("c2Vzc2lvbg");
    }).not.toThrow();
    expect(store.read()).toBeNull();
    expect(() => {
      store.clear();
    }).not.toThrow();
  });
});

/**
 * Each of these says what `localStorage` is rather than inheriting whatever the
 * runner happens to provide, and that is the point of the block rather than
 * tidiness. Node exposes web storage only when started with
 * `--localstorage-file`, so a test that read the ambient global exercised the
 * fallback on a developer's machine and the storage path on CI — one branch
 * each, neither runner both, and a green suite on either that proved only where
 * it ran.
 */
describe("choosing a store for the browser", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps the session in the browser's storage, so it survives a page load", () => {
    const storage = workingStorage();
    vi.stubGlobal("localStorage", storage);

    createBrowserTokenStore().write("c2Vzc2lvbg");

    expect(storage.getItem(SESSION_TOKEN_KEY)).toBe("c2Vzc2lvbg");

    // Building it a second time against the same storage is what the next page
    // load does — `main.tsx` calls this at module scope — and the worker is
    // still signed in.
    expect(createBrowserTokenStore().read()).toBe("c2Vzc2lvbg");
  });

  it("falls back to memory when there is no localStorage to reach", () => {
    // `window.localStorage` is typed as always present and is not: a runtime
    // with no web storage leaves it `undefined`, and reading `.getItem` off
    // that is a TypeError. `main.tsx` builds the store at module scope, so
    // without this fallback that TypeError is the whole application rendering
    // as a blank page with nothing the worker can act on.
    vi.stubGlobal("localStorage", undefined);

    const store = createBrowserTokenStore();

    store.write("c2Vzc2lvbg");

    expect(store.read()).toBe("c2Vzc2lvbg");
  });

  it("falls back to memory when the browser refuses storage", () => {
    // A different answer from `createLocalStorageTokenStore(blockedStorage())`,
    // which has to report null to every read: the probe fails once, and what
    // comes back holds the token for this page load.
    vi.stubGlobal("localStorage", blockedStorage());

    const store = createBrowserTokenStore();

    store.write("c2Vzc2lvbg");

    expect(store.read()).toBe("c2Vzc2lvbg");
  });
});
