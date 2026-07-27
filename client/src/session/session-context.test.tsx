import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../api/client";
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
