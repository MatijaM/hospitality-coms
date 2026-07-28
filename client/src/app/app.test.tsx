import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient, ApiResult } from "../api/client";
import type { Session } from "../api/types";
import { createMemoryRoomStore } from "../features/rooms/room-store";
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
  // Built once, not inline in the tree: a store rebuilt on every render is a
  // new store, and `RoomsRoute` reads its initial list in a `useState`
  // initialiser. Nothing here asserts on it, which is exactly why it would
  // have sat unnoticed until something did.
  const roomStore = createMemoryRoomStore();
  const tree = (
    <MemoryRouter initialEntries={[options.path ?? "/"]}>
      <SessionProvider api={api} tokenStore={tokenStore}>
        <App roomStore={roomStore} />
      </SessionProvider>
    </MemoryRouter>
  );

  render(options.strict === true ? <StrictMode>{tree}</StrictMode> : tree);

  return { api, tokenStore, roomStore };
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

  it("shows a 422 that names a field this form does not render", async () => {
    // The form has one input, and the copy for a per-field failure is attached
    // to it. A 422 naming anything else therefore had nowhere to go and the
    // page said nothing at all — the worker sees a submit that did nothing.
    renderApp({
      path: "/log-in",
      api: createFakeApi({
        requestMagicLink: () =>
          Promise.resolve(
            fails({
              kind: "api_field_error",
              status: 422,
              code: "unprocessable_entity",
              rawCode: "unprocessable_entity",
              message: "the address was not accepted",
              fields: { address: ["is not a field this form knows about"] },
            }),
          ),
      }),
    });

    await userEvent.type(
      await screen.findByLabelText(/email address/i),
      "worker@example",
    );
    await userEvent.click(screen.getByRole("button", { name: /send me a link/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /is not a field this form knows about/i,
    );
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

  it("redeems a pasted link once however fast the button is clicked", async () => {
    // The link is single use. A second redemption meets the 401 a spent link
    // gets, and its message — "That is no longer valid" — would be written
    // over a redemption that actually succeeded.
    const redeemMagicLink = vi.fn(() => new Promise<ApiResult<Session>>(() => undefined));
    renderApp({
      path: "/log-in",
      api: createFakeApi({
        requestMagicLink: () => Promise.resolve(ok(null)),
        redeemMagicLink,
      }),
    });

    await userEvent.type(
      await screen.findByLabelText(/email address/i),
      "worker@example.com",
    );
    await userEvent.click(screen.getByRole("button", { name: /send me a link/i }));
    await userEvent.type(await screen.findByLabelText(/paste/i), "bWFnaWM");

    const submit = await screen.findByRole("button", { name: /log in with this link/i });
    await userEvent.click(submit);
    await userEvent.click(submit);

    expect(redeemMagicLink).toHaveBeenCalledOnce();
    expect(submit).toBeDisabled();
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

  it("offers the rooms surface, which is no longer one of the absences", async () => {
    renderApp({
      path: "/",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    await userEvent.click(await screen.findByRole("link", { name: /rooms/i }));

    expect(await screen.findByRole("heading", { name: /^rooms$/i })).toBeVisible();
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
    // Was `/rooms`, then `/peers`; both are surfaces now. Picking the next
    // unbuilt route each time is how this test keeps getting invalidated, so
    // this one names a path no unit is going to claim.
    renderApp({ path: "/not-a-surface" });

    expect(await screen.findByRole("heading", { name: /nothing here/i })).toBeVisible();
  });
});
