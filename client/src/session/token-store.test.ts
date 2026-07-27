import { describe, expect, it } from "vitest";

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

describe("choosing a store for the browser", () => {
  it("falls back to memory when there is no localStorage to reach", () => {
    // Not hypothetical, and not only a privacy setting: `window.localStorage`
    // is `undefined` in this very test environment, because jsdom now defers
    // to Node's experimental implementation and Node wants a
    // `--localstorage-file`. Reading `.getItem` off that is a TypeError at
    // module scope, which renders the whole application as a blank page.
    expect(globalThis.localStorage).toBeUndefined();

    const store = createBrowserTokenStore();

    store.write("c2Vzc2lvbg");

    expect(store.read()).toBe("c2Vzc2lvbg");
  });
});
