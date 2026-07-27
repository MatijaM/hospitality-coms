import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../api/client";
import { SessionProvider } from "../session/session-context";
import type { TokenStore } from "../session/token-store";
import { createMemoryTokenStore } from "../session/token-store";
import {
  createFakeApi,
  fails,
  invalidAddress,
  ok,
  offline,
  somePerson,
  unauthorized,
} from "../test-support/fake-api";
import { App } from "./app";

function renderApp(
  options: {
    path?: string;
    api?: ApiClient;
    tokenStore?: TokenStore;
    strict?: boolean;
  } = {},
) {
  const api = options.api ?? createFakeApi();
  const tokenStore = options.tokenStore ?? createMemoryTokenStore();
  const tree = (
    <MemoryRouter initialEntries={[options.path ?? "/"]}>
      <SessionProvider api={api} tokenStore={tokenStore}>
        <App />
      </SessionProvider>
    </MemoryRouter>
  );

  render(options.strict === true ? <StrictMode>{tree}</StrictMode> : tree);

  return { api, tokenStore };
}

const signedIn = { currentPerson: () => Promise.resolve(ok(somePerson)) };

describe("asking for a magic link", () => {
  it("sends an anonymous visitor to the log-in surface", async () => {
    renderApp({ path: "/" });

    expect(await screen.findByRole("heading", { name: /log in/i })).toBeInTheDocument();
  });

  it("posts the address and confirms without saying whether it was known", async () => {
    const requestMagicLink = vi.fn(() => Promise.resolve(ok(null)));
    renderApp({ path: "/log-in", api: createFakeApi({ requestMagicLink }) });

    await userEvent.type(
      await screen.findByLabelText(/email address/i),
      "worker@example.com",
    );
    await userEvent.click(screen.getByRole("button", { name: /send me a link/i }));

    expect(requestMagicLink).toHaveBeenCalledWith("worker@example.com");
    const confirmation = await screen.findByRole("status");
    expect(confirmation).toHaveTextContent(/if that address/i);
    expect(confirmation).not.toHaveTextContent(/account|registered|exists/i);
  });

  it("shows the server's per-field message against the input it names", async () => {
    renderApp({
      path: "/log-in",
      api: createFakeApi({
        requestMagicLink: () => Promise.resolve(fails(invalidAddress())),
      }),
    });

    // Something the browser's own `type="email"` check lets through, so that
    // what is being tested is the server's answer and not jsdom's constraint
    // validation quietly swallowing the submit.
    await userEvent.type(
      await screen.findByLabelText(/email address/i),
      "worker@example",
    );
    await userEvent.click(screen.getByRole("button", { name: /send me a link/i }));

    expect(
      await screen.findByText(/must have the @ sign and no spaces/i),
    ).toBeInTheDocument();
  });

  it("says the server could not be reached and leaves the form usable", async () => {
    renderApp({
      path: "/log-in",
      api: createFakeApi({ requestMagicLink: () => Promise.resolve(fails(offline())) }),
    });

    await userEvent.type(
      await screen.findByLabelText(/email address/i),
      "worker@example.com",
    );
    await userEvent.click(screen.getByRole("button", { name: /send me a link/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(/could not be reached/i);
    expect(screen.getByRole("button", { name: /send me a link/i })).toBeEnabled();
  });
});

describe("redeeming a link", () => {
  it("accepts a link pasted out of the dev mailbox", async () => {
    const redeemMagicLink = vi.fn(() =>
      Promise.resolve(ok({ token: "aXNzdWVk", person: somePerson })),
    );
    const { tokenStore } = renderApp({
      path: "/log-in",
      api: createFakeApi({
        ...signedIn,
        requestMagicLink: () => Promise.resolve(ok(null)),
        redeemMagicLink,
      }),
    });

    await userEvent.type(
      await screen.findByLabelText(/email address/i),
      "worker@example.com",
    );
    await userEvent.click(screen.getByRole("button", { name: /send me a link/i }));
    await userEvent.type(
      await screen.findByLabelText(/paste/i),
      "http://localhost:4000/log-in/bWFnaWM",
    );
    await userEvent.click(screen.getByRole("button", { name: /log in with this link/i }));

    expect(await screen.findByText("worker@example.com")).toBeInTheDocument();
    expect(redeemMagicLink).toHaveBeenCalledWith("bWFnaWM");
    expect(tokenStore.read()).toBe("aXNzdWVk");
  });

  it("redeems a link followed straight into the client", async () => {
    const redeemMagicLink = vi.fn(() =>
      Promise.resolve(ok({ token: "aXNzdWVk", person: somePerson })),
    );
    renderApp({ path: "/log-in/bWFnaWM", api: createFakeApi({ redeemMagicLink }) });

    expect(await screen.findByText("worker@example.com")).toBeInTheDocument();
    expect(redeemMagicLink).toHaveBeenCalledWith("bWFnaWM");
  });

  it("redeems a followed link exactly once, through StrictMode's double mount", async () => {
    // A magic link is single use, so a second attempt meets a 401 and tells the
    // worker their working link was invalid. StrictMode mounting every
    // component twice in development is exactly that second attempt.
    const redeemMagicLink = vi.fn(() =>
      Promise.resolve(ok({ token: "aXNzdWVk", person: somePerson })),
    );
    renderApp({
      path: "/log-in/bWFnaWM",
      api: createFakeApi({ redeemMagicLink }),
      strict: true,
    });

    await screen.findByText("worker@example.com");

    expect(redeemMagicLink).toHaveBeenCalledOnce();
  });

  it("says a spent link is spent and offers the way back", async () => {
    renderApp({
      path: "/log-in/c3BlbnQ",
      api: createFakeApi({
        redeemMagicLink: () => Promise.resolve(fails(unauthorized())),
      }),
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /invalid, or it has expired/i,
    );
    await userEvent.click(screen.getByRole("link", { name: /ask for a new link/i }));

    expect(await screen.findByLabelText(/email address/i)).toBeInTheDocument();
  });
});

describe("an authenticated session", () => {
  it("shows the person the session belongs to", async () => {
    renderApp({
      path: "/",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    expect(await screen.findByText("worker@example.com")).toBeInTheDocument();
  });

  it("takes a signed-in visitor off the log-in surface", async () => {
    renderApp({
      path: "/log-in",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    expect(await screen.findByText("worker@example.com")).toBeInTheDocument();
    expect(screen.queryByLabelText(/email address/i)).not.toBeInTheDocument();
  });

  it("returns to the log-in surface on log out", async () => {
    const logOut = vi.fn(() => Promise.resolve(ok(null)));
    const { tokenStore } = renderApp({
      path: "/",
      api: createFakeApi({ ...signedIn, logOut }),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    await screen.findByText("worker@example.com");
    await userEvent.click(screen.getByRole("button", { name: /log out/i }));

    expect(await screen.findByLabelText(/email address/i)).toBeInTheDocument();
    expect(logOut).toHaveBeenCalledWith("c2Vzc2lvbg");
    expect(tokenStore.read()).toBeNull();
  });

  it("names what is deliberately not here yet, rather than pretending it is coming", async () => {
    renderApp({
      path: "/",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    expect(await screen.findByRole("heading", { name: /not built yet/i })).toBeVisible();
  });
});

describe("a session that cannot be checked", () => {
  it("says so and offers a retry rather than logging the worker out", async () => {
    const currentPerson = vi
      .fn(() => Promise.resolve(ok(somePerson)))
      .mockResolvedValueOnce(fails(offline()));
    const { tokenStore } = renderApp({
      path: "/",
      api: createFakeApi({ currentPerson }),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    expect(await screen.findByRole("alert")).toHaveTextContent(/could not be reached/i);
    expect(tokenStore.read()).toBe("c2Vzc2lvbg");

    await userEvent.click(screen.getByRole("button", { name: /try again/i }));

    expect(await screen.findByText("worker@example.com")).toBeInTheDocument();
  });
});

describe("a path that is not a surface", () => {
  it("says so instead of rendering an empty page", async () => {
    renderApp({ path: "/rooms" });

    expect(await screen.findByRole("heading", { name: /nothing here/i })).toBeVisible();
  });
});
