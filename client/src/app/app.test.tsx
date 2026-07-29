import { render, screen, within } from "@testing-library/react";
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

  const { unmount } = render(
    options.strict === true ? <StrictMode>{tree}</StrictMode> : tree,
  );

  return { api, tokenStore, roomStore, unmount };
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

    expect(
      await screen.findByRole("heading", { name: /not reachable from here yet/i }),
    ).toBeVisible();
    // The heading is not the claim; the two entries under it are. Both went
    // false when U10 and U11 shipped, and a version of this test that asserted
    // the heading alone stayed green through it. Asserted on the sentence each
    // entry makes rather than on its label, because a bullet reduced back to
    // "erasure" or "the demo controls" is exactly the regression — it names a
    // unit's leftovers instead of what a worker cannot do.
    expect(screen.getByText(/no endpoint and no channel/i)).toBeVisible();
    expect(screen.getByText(/x-demo-control/i)).toBeVisible();
  });

  // The previous version of this asserted only that a heading existed, so the
  // list under it — which said "waiting on U9", "waiting on U10", "waiting on
  // U11" long after all three shipped — was covered by nothing.
  //
  // A heading is not the claim. The claim is which surfaces a signed-in person
  // cannot use, and the one most likely to come true without anyone editing
  // this file is the profile: it needs a `profile:*` channel that
  // `PersonSocket` does not route. `sockets_test.exs` pins that routing table
  // exactly, with a control, so adding the channel fails there — and this is
  // the assertion that should then be replaced by an "offers the profile
  // surface" test, the way rooms got one when its channel landed and the tab
  // tests below inherited.
  //
  // The record is behind a tab now rather than a link, so the door has to be
  // opened before "Your record" is in the document. That is deliberately not
  // the weaker test it looks like: the link version proved a door existed,
  // and this proves the surface behind it mounts — which is what makes "the
  // screen cannot connect" a claim about something rather than about nothing.
  it("warns that the profile screen cannot connect, because no channel serves it", async () => {
    renderApp({
      path: "/",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    await userEvent.click(await screen.findByRole("tab", { name: "Profile" }));

    expect(await screen.findByRole("heading", { name: /^your record$/i })).toBeVisible();
    expect(screen.getByText(/cannot connect yet/i)).toBeVisible();
  });
});

/**
 * The landing page's tabs.
 *
 * Two shapes are avoided throughout, both of which this project has shipped
 * before: a tab test that passes because the panel was never rendered either
 * way, and an assertion on a heading standing in for one on the panel's
 * content. So every claim about a panel is made against a sentence only that
 * surface renders, and every "it is gone" assertion is made in a test that
 * saw it there first.
 */
describe("the landing page's tabs", () => {
  /** A sentence each surface renders and neither of the other two does. */
  // The rooms surface, named by a sentence only it renders. It moved when the
  // browse list landed: the empty local list now points at the server's list
  // above it rather than only at the paste box.
  const ROOMS = /no rooms yet\. open one from the list above, or add one by its id/i;
  const PEERS = /anybody you worked with at the same place at the same time/i;
  const PROFILE = /no employer has confirmed a job for you yet/i;

  function landOnHome() {
    return renderApp({
      path: "/",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });
  }

  async function panel(): Promise<HTMLElement> {
    return screen.findByRole("tabpanel");
  }

  it("opens on the rooms surface with nothing to click", async () => {
    landOnHome();

    expect(within(await panel()).getByText(ROOMS)).toBeVisible();
  });

  it("puts the peer surface on screen and takes the rooms one off", async () => {
    landOnHome();

    // Reached first, so that the absence below is "unmounted" rather than
    // "never rendered" — the distinction a 2026-07 review found this suite
    // could not make anywhere it asserted one.
    expect(within(await panel()).getByText(ROOMS)).toBeVisible();

    await userEvent.click(screen.getByRole("tab", { name: "Peers" }));

    expect(within(await panel()).getByText(PEERS)).toBeVisible();
    expect(screen.queryByText(ROOMS)).not.toBeInTheDocument();
  });

  it("puts the record on screen and takes the rooms surface off", async () => {
    landOnHome();

    expect(within(await panel()).getByText(ROOMS)).toBeVisible();

    await userEvent.click(screen.getByRole("tab", { name: "Profile" }));

    expect(within(await panel()).getByText(PROFILE)).toBeVisible();
    expect(screen.queryByText(ROOMS)).not.toBeInTheDocument();
  });

  it("never has two surfaces mounted at once", async () => {
    // The rule `usePeerSurface`'s moduledoc states — one instance, because one
    // topic — read off the DOM rather than off the hook. Hiding a panel with
    // CSS instead of unmounting it passes every assertion above this one and
    // fails these.
    landOnHome();
    await panel();

    await userEvent.click(screen.getByRole("tab", { name: "Peers" }));

    expect(screen.getAllByRole("tabpanel")).toHaveLength(1);
    expect(screen.queryByText(ROOMS)).not.toBeInTheDocument();
    expect(screen.queryByText(PROFILE)).not.toBeInTheDocument();
  });

  it("moves aria-selected and the panel wiring together", async () => {
    landOnHome();

    const rooms = await screen.findByRole("tab", { name: "Rooms", selected: true });
    expect(rooms.getAttribute("aria-controls")).toBe((await panel()).id);
    expect((await panel()).getAttribute("aria-labelledby")).toBe(rooms.id);
    expect(screen.getByRole("tab", { name: "Peers", selected: false })).toBeVisible();

    await userEvent.click(screen.getByRole("tab", { name: "Peers" }));

    const peers = await screen.findByRole("tab", { name: "Peers", selected: true });
    // Both halves, and the ids differ per tab, so a wiring hard-coded to the
    // first panel passes the assertions above and fails these.
    expect(peers.getAttribute("aria-controls")).toBe((await panel()).id);
    expect((await panel()).getAttribute("aria-labelledby")).toBe(peers.id);
    expect(screen.getByRole("tab", { name: "Rooms", selected: false })).toBeVisible();
  });

  it("walks the strip with the arrow keys, wrapping at the end", async () => {
    landOnHome();

    (await screen.findByRole("tab", { name: "Rooms" })).focus();

    await userEvent.keyboard("{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Peers" })).toHaveFocus();
    expect(within(await panel()).getByText(PEERS)).toBeVisible();

    // Wrapping is the half a handler written as `min`/`max` gets wrong, and
    // the third press is what reaches it.
    await userEvent.keyboard("{ArrowRight}{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Rooms" })).toHaveFocus();
    expect(within(await panel()).getByText(ROOMS)).toBeVisible();

    await userEvent.keyboard("{ArrowLeft}");
    expect(screen.getByRole("tab", { name: "Profile" })).toHaveFocus();
    expect(within(await panel()).getByText(PROFILE)).toBeVisible();
  });

  it("jumps to either end with Home and End", async () => {
    landOnHome();

    (await screen.findByRole("tab", { name: "Rooms" })).focus();

    await userEvent.keyboard("{End}");
    expect(screen.getByRole("tab", { name: "Profile" })).toHaveFocus();
    expect(within(await panel()).getByText(PROFILE)).toBeVisible();

    // From the far end rather than from the middle, so a `Home` that returns
    // the tab it was already on cannot pass.
    await userEvent.keyboard("{Home}");
    expect(screen.getByRole("tab", { name: "Rooms" })).toHaveFocus();
    expect(within(await panel()).getByText(ROOMS)).toBeVisible();
  });

  it("keeps the identity block out of the tabs", async () => {
    landOnHome();

    // Not "it is on the page" — with three tabs and one log-out control, the
    // failure to guard against is somebody folding it into a panel, and a
    // presence assertion is satisfied by that.
    expect(await screen.findByText("worker@example.com")).toBeVisible();
    expect(
      within(await panel()).queryByRole("button", { name: /log out/i }),
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /log out/i })).toBeVisible();

    await userEvent.click(screen.getByRole("tab", { name: "Profile" }));

    expect(screen.getByText("worker@example.com")).toBeVisible();
    expect(
      within(await panel()).queryByRole("button", { name: /log out/i }),
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /log out/i })).toBeVisible();
  });

  it("still serves each surface at its own path", async () => {
    // The tabs are a second door. These three paths are what every test above
    // the three surfaces enters through, so a landing page that took them over
    // would invalidate about eighty-five assertions elsewhere in one commit.
    for (const [path, text] of [
      ["/rooms", ROOMS],
      ["/peers", PEERS],
      ["/profile", PROFILE],
    ] as const) {
      const { unmount } = renderApp({
        path,
        api: createFakeApi(signedIn),
        tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
      });

      expect(await screen.findByText(text)).toBeVisible();
      expect(screen.queryByRole("tablist")).not.toBeInTheDocument();

      unmount();
    }
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
