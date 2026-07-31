import { act, render, screen, waitFor, within } from "@testing-library/react";
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
// The venue list's path and body come from the harness the employer tests
// already share, so there is one spelling of each: a path written inline here
// would go on passing when the production one changed, because `readsFrom`
// answers an unstubbed path with a `404` and this panel shows the link on a
// failure by design.
import { VENUES as VENUES_PATH, twoVenues } from "../test-support/employer-harness";
import {
  createFakeApi,
  fails,
  invalidAddress,
  ok,
  offline,
  readsFrom,
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

  /**
   * This is two former tests inverted rather than deleted.
   *
   * One found the "Not reachable from here yet" list by two of its own
   * sentences; the other found "That tab cannot connect yet" in the paragraph
   * about the profile. Both blocks were written for whoever was building the
   * next unit — they cited units, a file path, "no endpoint and no channel"
   * and an HTTP header — and both are gone from the screen. Turning the
   * assertions round is what keeps them gone: a presence test simply deleted
   * leaves the prose one careless paste from coming back with nothing to say
   * so.
   *
   * **The controls come first and they are mandatory.** An absence assertion
   * passes against a page that rendered nothing at all, which is the one shape
   * this suite's own header warns about — so the signed-in address and the
   * four tabs are asserted before anything is asserted to be missing.
   *
   * The tab count is a second claim carried in the same line: it is the arity
   * `neighbour` wraps over, and the keyboard tests below are written against
   * it.
   */
  it("carries no notes about how the product is built", async () => {
    renderApp({
      path: "/",
      api: createFakeApi(signedIn),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });

    expect(await screen.findByText("worker@example.com")).toBeVisible();
    expect(screen.getAllByRole("tab")).toHaveLength(4);

    for (const developerNote of [
      /not reachable from here yet/i,
      /no endpoint and no channel/i,
      /x-demo-control/i,
      /nothing is stubbed/i,
      /cannot connect yet/i,
      /contract\.ts/i,
    ]) {
      expect(screen.queryByText(developerNote)).not.toBeInTheDocument();
    }
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
  // The rooms surface, named by a sentence only it renders. It has moved twice
  // and both times because the way into a room changed: the browse list landed,
  // so the empty local list started pointing at the server's list above it
  // rather than at the paste box, and #80 took the box away, so the second half
  // of the sentence went with it.
  const ROOMS = /no rooms yet\. open one from the list above\./i;
  const PEERS = /anybody you worked with at the same place at the same time/i;
  const PROFILE = /no employer has confirmed a job for you yet/i;
  // The fourth panel mounts no surface, so it has no sentence of its own to be
  // named by. Its `/claim` link does the same job: it is the one thing in that
  // panel that is there whatever the venue read answers, which is what makes it
  // usable as "the venues panel is open" in tests about the *other* link.
  const VENUES = /claim a job/i;

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

  /**
   * #73, asserted where the whole product is on screen rather than only the
   * slice.
   *
   * The profile panel carried a third section — a box for a person's uuid and
   * a "Read their record" button. `profile-route.test.tsx` inverts the six
   * tests that drove it; this is the one that would notice it coming back
   * through the tab a worker actually opens, with no socket answering anything,
   * which is the state this file renders every surface in.
   *
   * Controls first, and here that means two different query shapes: the
   * panel's own sentinel and a button that *is* in it. An absence assertion
   * over a panel that failed to mount passes, and so does one whose matcher
   * never matched anything.
   */
  it("offers no way to look up somebody else's record", async () => {
    landOnHome();

    expect(within(await panel()).getByText(ROOMS)).toBeVisible();
    await userEvent.click(screen.getByRole("tab", { name: "Profile" }));

    const open = await panel();

    expect(within(open).getByText(PROFILE)).toBeVisible();
    expect(within(open).getByRole("button", { name: /write this down/i })).toBeVisible();

    const text = open.textContent;
    expect(text).toContain("Jobs an employer confirmed");

    // Written out with the apostrophe the heading rendered. A regex with a
    // straight one never matched it and would have passed while it was there.
    for (const copy of ["Somebody else’s record", "Read their record"]) {
      expect(text).not.toContain(copy);
    }
    expect(
      within(open).queryByRole("button", { name: /read their record/i }),
    ).not.toBeInTheDocument();
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

    // Venues too, because it is the one tab whose panel is not a surface — the
    // wiring is `TABS`-driven and has no reason to treat it differently, and
    // this is what says so rather than leaving it assumed.
    await userEvent.click(screen.getByRole("tab", { name: "Venues" }));

    const venues = await screen.findByRole("tab", { name: "Venues", selected: true });
    expect(venues.getAttribute("aria-controls")).toBe((await panel()).id);
    expect((await panel()).getAttribute("aria-labelledby")).toBe(venues.id);
    expect(screen.getByRole("tab", { name: "Peers", selected: false })).toBeVisible();
  });

  it("walks the strip with the arrow keys, wrapping at the end", async () => {
    landOnHome();

    (await screen.findByRole("tab", { name: "Rooms" })).focus();

    await userEvent.keyboard("{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Peers" })).toHaveFocus();
    expect(within(await panel()).getByText(PEERS)).toBeVisible();

    // Through Profile and onto the last tab, so the walk reaches the entry
    // added last rather than turning round in front of it.
    await userEvent.keyboard("{ArrowRight}{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Venues" })).toHaveFocus();
    expect(within(await panel()).getByText(VENUES)).toBeVisible();

    // Wrapping is the half a handler written as `min`/`max` gets wrong, and
    // with four tabs it is the fourth press that reaches it.
    await userEvent.keyboard("{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Rooms" })).toHaveFocus();
    expect(within(await panel()).getByText(ROOMS)).toBeVisible();

    // The other end of the same wrap, which a `max` gets wrong independently.
    await userEvent.keyboard("{ArrowLeft}");
    expect(screen.getByRole("tab", { name: "Venues" })).toHaveFocus();
    expect(within(await panel()).getByText(VENUES)).toBeVisible();
  });

  it("jumps to either end with Home and End", async () => {
    landOnHome();

    (await screen.findByRole("tab", { name: "Rooms" })).focus();

    await userEvent.keyboard("{End}");
    expect(screen.getByRole("tab", { name: "Venues" })).toHaveFocus();
    expect(within(await panel()).getByText(VENUES)).toBeVisible();

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

/**
 * The Venues tab, which is the one panel that fetches to decide what it holds.
 *
 * `/claim` is offered unconditionally — a code is a code and anybody may hold
 * one. `/employer` is offered unless the server has said there are no venues to
 * manage, which is **not** the same rule as "offered once we know there are
 * some", and the difference is invisible until the network fails. So every one
 * of the four states `useFetched` can be in is driven here, and the two that
 * cannot be told apart from the DOM alone — in flight and refused — are reached
 * by holding the read open and letting it go by hand.
 *
 * `flush()` is what makes the refusal test a claim about the refusal rather
 * than about a request still in flight, and the empty-answer test is its
 * control: both settle the same way through the same helper, and that one has
 * something visible to lose. If the flush were not reaching a settled read, the
 * link would still be on screen there and that test would fail.
 */
describe("the venues tab", () => {
  /**
   * A `read` this test releases, answering through the real decoders.
   *
   * It wraps `readsFrom` rather than resolving a hand-made value, so a fixture
   * that is not the shape `EmployerController` renders fails here as
   * `malformed_response` exactly as it would in a browser.
   */
  function heldRead(bodies: Readonly<Record<string, unknown>>) {
    const answer = readsFrom(bodies);
    let release = (): void => undefined;
    const held = new Promise<void>((resolve) => {
      release = () => {
        resolve();
      };
    });

    const read = vi.fn(
      (path: string, token: string, decode: (body: unknown) => unknown) =>
        held.then(() => answer(path, token, decode)),
    ) as ApiClient["read"];

    return {
      read,
      release: () => {
        release();
      },
    };
  }

  /** Every microtask the released read is waiting behind, and the render after. */
  async function flush(): Promise<void> {
    await act(async () => {
      await Promise.resolve();
    });
  }

  function landOn(read: ApiClient["read"]) {
    return renderApp({
      path: "/",
      api: createFakeApi({ ...signedIn, read }),
      tokenStore: createMemoryTokenStore("c2Vzc2lvbg"),
    });
  }

  async function openVenues(): Promise<HTMLElement> {
    await userEvent.click(await screen.findByRole("tab", { name: "Venues" }));

    return screen.findByRole("tabpanel");
  }

  const MANAGE = { name: /venues you manage/i };
  const CLAIM = { name: /claim a job/i };

  it("offers the way into the venues you manage when the server names some", async () => {
    landOn(readsFrom({ [VENUES_PATH]: twoVenues }));

    const panel = await openVenues();

    expect(await within(panel).findByRole("link", MANAGE)).toBeVisible();
    expect(within(panel).getByRole("link", CLAIM)).toBeVisible();
  });

  it("takes that link away once the server answers that there are none", async () => {
    const { read, release } = heldRead({ [VENUES_PATH]: { venues: [] } });
    landOn(read);

    const panel = await openVenues();

    // In flight, and the link is there — which is the state the assertion
    // after the release has to be distinguished from.
    expect(within(panel).getByRole("link", MANAGE)).toBeVisible();

    release();
    await flush();

    expect(within(panel).queryByRole("link", MANAGE)).not.toBeInTheDocument();
    // The control. Without it this passes against a panel that stopped
    // rendering anything at all.
    expect(within(panel).getByRole("link", CLAIM)).toBeVisible();
  });

  it("keeps that link when the read is refused, rather than closing the only door", async () => {
    // `readsFrom` answers an unstubbed path with a `404`, so this is a refusal
    // rather than a timeout — and the point is that the panel cannot tell the
    // difference and must not guess. Hiding here would take a manager's one
    // route to their venues away over a request that failed; `/employer` has
    // its own copy for the failure and for the genuinely empty case alike.
    const { read, release } = heldRead({});
    landOn(read);

    const panel = await openVenues();

    expect(within(panel).getByRole("link", MANAGE)).toBeVisible();

    release();
    await flush();

    expect(within(panel).getByRole("link", MANAGE)).toBeVisible();
    expect(within(panel).getByRole("link", CLAIM)).toBeVisible();
  });

  it("asks for the list when the tab is opened and not before", async () => {
    // What "only the open tab is mounted" buys, asserted rather than assumed:
    // a worker who never manages anywhere never makes this call. It is also
    // what fails if the hook is ever hoisted into `HomeRoute` to keep the
    // answer between tab switches.
    const read = readsFrom({ [VENUES_PATH]: twoVenues });
    landOn(read);

    await screen.findByRole("tab", { name: "Venues" });
    expect(read).not.toHaveBeenCalledWith(
      VENUES_PATH,
      expect.anything(),
      expect.anything(),
    );

    await openVenues();

    // The control for the assertion above: the call is one a tab press makes,
    // so "never made" has to be the press not having happened yet.
    await waitFor(() => {
      expect(read).toHaveBeenCalledWith(
        VENUES_PATH,
        expect.anything(),
        expect.anything(),
      );
    });
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
