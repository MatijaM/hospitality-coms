import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient, ApiResult } from "../api/client";
import type { Person } from "../api/types";
import {
  createFakeApi,
  fails,
  ok,
  offline,
  somePerson,
  unauthorized,
} from "../test-support/fake-api";
import { SessionProvider, useSession } from "./session-context";
import type { TokenStore } from "./token-store";
import { createMemoryTokenStore } from "./token-store";

function Probe() {
  const { state, redeem, logOut, retry } = useSession();
  const [redemption, setRedemption] = useState("none");

  return (
    <div>
      <p>status: {state.status}</p>
      {state.status === "authenticated" && <p>person: {state.person.email}</p>}
      {state.status === "authenticated" && <p>token: {state.token}</p>}
      <p>redemption: {redemption}</p>
      <button
        onClick={() => {
          void redeem("pasted-token").then((outcome) => {
            setRedemption(outcome.ok ? "accepted" : outcome.failure.kind);
          });
        }}
      >
        redeem
      </button>
      <button onClick={() => void logOut()}>log out</button>
      <button onClick={retry}>retry</button>
    </div>
  );
}

/** A promise this test settles by hand, to hold an answer in flight. */
function deferred<T>() {
  let settle: (value: T) => void = () => undefined;
  const promise = new Promise<T>((resolve) => {
    settle = resolve;
  });

  return { promise, settle };
}

function renderSession(api: ApiClient, tokenStore: TokenStore) {
  return render(
    <SessionProvider api={api} tokenStore={tokenStore}>
      <Probe />
    </SessionProvider>,
  );
}

describe("resolving a stored token on load", () => {
  it("settles anonymous without asking the API when nothing is stored", async () => {
    const currentPerson = vi.fn(() => Promise.resolve(ok(somePerson)));

    renderSession(createFakeApi({ currentPerson }), createMemoryTokenStore());

    expect(await screen.findByText("status: anonymous")).toBeInTheDocument();
    expect(currentPerson).not.toHaveBeenCalled();
  });

  it("resolves a stored token into the person it belongs to", async () => {
    const currentPerson = vi.fn(() => Promise.resolve(ok(somePerson)));

    renderSession(createFakeApi({ currentPerson }), createMemoryTokenStore("c2Vzc2lvbg"));

    expect(await screen.findByText("person: worker@example.com")).toBeInTheDocument();
    expect(currentPerson).toHaveBeenCalledWith("c2Vzc2lvbg");
  });

  it("forgets a token the server no longer knows", async () => {
    const store = createMemoryTokenStore("revoked");

    renderSession(
      createFakeApi({ currentPerson: () => Promise.resolve(fails(unauthorized())) }),
      store,
    );

    expect(await screen.findByText("status: anonymous")).toBeInTheDocument();
    expect(store.read()).toBeNull();
  });

  it("keeps the token when the network failed, because that is not a revocation", async () => {
    const store = createMemoryTokenStore("c2Vzc2lvbg");

    renderSession(
      createFakeApi({ currentPerson: () => Promise.resolve(fails(offline())) }),
      store,
    );

    expect(await screen.findByText("status: unavailable")).toBeInTheDocument();
    expect(store.read()).toBe("c2Vzc2lvbg");
  });

  it("ignores an answer about a token the store no longer holds", async () => {
    // The provider is still resolving the stored token when a redemption
    // lands. The old token's answer arrives afterwards and is about a session
    // nobody is in any more: applying it — a 401 in particular — wipes a
    // session that has just succeeded, and there is no way back except the
    // inbox.
    const store = createMemoryTokenStore("stale-token");
    const stale = deferred<ApiResult<Person>>();

    renderSession(
      createFakeApi({
        currentPerson: () => stale.promise,
        redeemMagicLink: () =>
          Promise.resolve(ok({ token: "fresh-token", person: somePerson })),
      }),
      store,
    );

    await screen.findByText("status: resolving");
    await userEvent.click(screen.getByRole("button", { name: "redeem" }));
    await screen.findByText("token: fresh-token");

    await act(async () => {
      stale.settle(fails(unauthorized()));
      await stale.promise;
    });

    expect(screen.getByText("status: authenticated")).toBeInTheDocument();
    expect(screen.getByText("token: fresh-token")).toBeInTheDocument();
    expect(store.read()).toBe("fresh-token");
  });

  it("ignores a stale success about a token the store no longer holds", async () => {
    const store = createMemoryTokenStore("stale-token");
    const stale = deferred<ApiResult<Person>>();
    const otherPerson = { id: "8b1b0a3c-0000-4000-8000-000000000002", email: null };

    renderSession(
      createFakeApi({
        currentPerson: () => stale.promise,
        redeemMagicLink: () =>
          Promise.resolve(ok({ token: "fresh-token", person: somePerson })),
      }),
      store,
    );

    await screen.findByText("status: resolving");
    await userEvent.click(screen.getByRole("button", { name: "redeem" }));
    await screen.findByText("token: fresh-token");

    await act(async () => {
      stale.settle(ok(otherPerson));
      await stale.promise;
    });

    expect(screen.getByText("person: worker@example.com")).toBeInTheDocument();
    expect(screen.getByText("token: fresh-token")).toBeInTheDocument();
  });

  it("settles anonymous when a retry finds the token gone", async () => {
    const store = createMemoryTokenStore("c2Vzc2lvbg");

    renderSession(
      createFakeApi({ currentPerson: () => Promise.resolve(fails(offline())) }),
      store,
    );
    await screen.findByText("status: unavailable");
    store.clear();
    await userEvent.click(screen.getByRole("button", { name: "retry" }));

    expect(await screen.findByText("status: anonymous")).toBeInTheDocument();
  });

  it("resolves on a retry after the network comes back", async () => {
    const currentPerson = vi
      .fn(() => Promise.resolve(ok(somePerson)))
      .mockResolvedValueOnce(fails(offline()));

    renderSession(createFakeApi({ currentPerson }), createMemoryTokenStore("c2Vzc2lvbg"));
    await screen.findByText("status: unavailable");
    await userEvent.click(screen.getByRole("button", { name: "retry" }));

    expect(await screen.findByText("person: worker@example.com")).toBeInTheDocument();
  });
});

describe("redeeming a link", () => {
  it("stores the issued token and authenticates", async () => {
    const store = createMemoryTokenStore();
    const redeemMagicLink = vi.fn(() =>
      Promise.resolve(ok({ token: "aXNzdWVk", person: somePerson })),
    );

    renderSession(createFakeApi({ redeemMagicLink }), store);
    await screen.findByText("status: anonymous");
    await userEvent.click(screen.getByRole("button", { name: "redeem" }));

    expect(await screen.findByText("person: worker@example.com")).toBeInTheDocument();
    expect(redeemMagicLink).toHaveBeenCalledWith("pasted-token");
    expect(store.read()).toBe("aXNzdWVk");
  });

  it("still signs the person in when the token could not be stored", async () => {
    // A browser blocking storage throws on write. The token is valid and was
    // just issued, so failing the redemption over it would throw away a
    // working credential — and rejecting out of `redeem` strands both call
    // sites, which `void` the promise, on "Logging you in…" for ever.
    const refusingStore: TokenStore = {
      read: () => null,
      write: () => {
        throw new DOMException("QuotaExceededError");
      },
      clear: () => undefined,
    };

    renderSession(
      createFakeApi({
        redeemMagicLink: () =>
          Promise.resolve(ok({ token: "aXNzdWVk", person: somePerson })),
      }),
      refusingStore,
    );
    await screen.findByText("status: anonymous");
    await userEvent.click(screen.getByRole("button", { name: "redeem" }));

    expect(await screen.findByText("person: worker@example.com")).toBeInTheDocument();
    expect(screen.getByText("redemption: accepted")).toBeInTheDocument();
  });

  it("hands a refusal back to the caller and stays anonymous", async () => {
    const store = createMemoryTokenStore();

    renderSession(
      createFakeApi({ redeemMagicLink: () => Promise.resolve(fails(unauthorized())) }),
      store,
    );
    await screen.findByText("status: anonymous");
    await userEvent.click(screen.getByRole("button", { name: "redeem" }));

    expect(await screen.findByText("redemption: api_error")).toBeInTheDocument();
    expect(screen.getByText("status: anonymous")).toBeInTheDocument();
    expect(store.read()).toBeNull();
  });
});

describe("logging out", () => {
  it("deletes the session server-side and forgets the token", async () => {
    const store = createMemoryTokenStore("c2Vzc2lvbg");
    const logOut = vi.fn(() => Promise.resolve(ok(null)));

    renderSession(
      createFakeApi({ currentPerson: () => Promise.resolve(ok(somePerson)), logOut }),
      store,
    );
    await screen.findByText("person: worker@example.com");
    await userEvent.click(screen.getByRole("button", { name: "log out" }));

    expect(await screen.findByText("status: anonymous")).toBeInTheDocument();
    expect(logOut).toHaveBeenCalledWith("c2Vzc2lvbg");
    expect(store.read()).toBeNull();
  });

  it("forgets the token even when the server could not be told", async () => {
    const store = createMemoryTokenStore("c2Vzc2lvbg");

    renderSession(
      createFakeApi({
        currentPerson: () => Promise.resolve(ok(somePerson)),
        logOut: () => Promise.resolve(fails(offline())),
      }),
      store,
    );
    await screen.findByText("person: worker@example.com");
    await userEvent.click(screen.getByRole("button", { name: "log out" }));

    expect(await screen.findByText("status: anonymous")).toBeInTheDocument();
    expect(store.read()).toBeNull();
  });
});

describe("useSession outside a provider", () => {
  it("says so rather than handing back an empty session", () => {
    expect(() => render(<Probe />)).toThrow(/SessionProvider/);
  });
});
