/**
 * The display-name control (#66), on the bar that carries it.
 *
 * `/profile` cannot connect — no channel on the server answers a profile event
 * — so this is the surface the change control had to go on, and it is the only
 * place in the client that renders your own identity. It is on every screen a
 * session rests on.
 *
 * Everything here goes through the whole `App` rather than rendering
 * `SessionBar` alone, because the claim is about a session: the name on the bar
 * has to change because the *session's person* changed, not because a component
 * kept its own copy of what was typed.
 */

import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../api/client";
import { createMemoryRoomStore } from "../features/rooms/room-store";
import { SessionProvider } from "../session/session-context";
import { createMemoryTokenStore } from "../session/token-store";
import {
  createFakeApi,
  fails,
  offline,
  ok,
  rejectedName,
  somePerson,
} from "../test-support/fake-api";
import { App } from "./app";

function renderSignedIn(overrides: Partial<ApiClient> = {}) {
  const api = createFakeApi({
    currentPerson: () => Promise.resolve(ok(somePerson)),
    ...overrides,
  });

  render(
    <MemoryRouter initialEntries={["/"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <App roomStore={createMemoryRoomStore()} />
      </SessionProvider>
    </MemoryRouter>,
  );

  return api;
}

async function openTheForm() {
  await userEvent.click(await screen.findByRole("button", { name: /change your name/i }));
}

function nameInput() {
  return screen.getByLabelText(/your name/i);
}

describe("the display name on the session bar", () => {
  it("shows the name the session's person is called", async () => {
    renderSignedIn();

    expect(await screen.findByText("Captain Nemo")).toBeInTheDocument();
  });

  it("keeps showing the address beside it", async () => {
    // The control for the test above, and the regression guard for the sentence
    // it lives in: a bar that rendered the name *instead of* the address would
    // pass the first test and take away the only thing that identifies which
    // account a shared terminal is signed into.
    renderSignedIn();

    expect(await screen.findByText("worker@example.com")).toBeInTheDocument();
  });

  it("offers no form until the control is used", async () => {
    renderSignedIn();

    await screen.findByRole("button", { name: /change your name/i });
    expect(screen.queryByLabelText(/your name/i)).toBeNull();
  });

  it("sends exactly {display_name} and shows what the server answered", async () => {
    // The request shape is asserted against a literal, because it is the
    // contract with `PATCH /api/me` and nothing else pins it on this side. The
    // *rendered* name is the server's answer rather than what was typed —
    // `rename` puts the returned person on the session — which is why the fake
    // answers a different string from the one entered.
    const changeDisplayName = vi.fn(() =>
      Promise.resolve(ok({ ...somePerson, displayName: "Wendy Darling" })),
    );
    renderSignedIn({ changeDisplayName });

    await openTheForm();
    await userEvent.clear(nameInput());
    await userEvent.type(nameInput(), "  Wendy Darling  ");
    await userEvent.click(screen.getByRole("button", { name: /save name/i }));

    expect(await screen.findByText("Wendy Darling")).toBeInTheDocument();
    // Sent **verbatim**, whitespace included: the trim is
    // `Person.display_name_changeset/3`'s, and a client that trimmed first
    // would be a second copy of a validation whose authority is the server's.
    expect(changeDisplayName).toHaveBeenCalledWith("  Wendy Darling  ", "c2Vzc2lvbg");
    expect(screen.queryByText("Captain Nemo")).toBeNull();
  });

  it("closes the form once the name has been saved", async () => {
    renderSignedIn({
      changeDisplayName: () =>
        Promise.resolve(ok({ ...somePerson, displayName: "Wendy Darling" })),
    });

    await openTheForm();
    await userEvent.click(screen.getByRole("button", { name: /save name/i }));

    await screen.findByText("Wendy Darling");
    expect(screen.queryByLabelText(/your name/i)).toBeNull();
  });

  it("keeps the old name and says why when the server refuses", async () => {
    // **The control for the whole surface.** A bar that rendered what was typed
    // the moment it was submitted passes every test above and lies about a
    // refusal — and the refusal is reachable: the server answers 422 for a
    // blank name and for one past its bound.
    renderSignedIn({
      changeDisplayName: () => Promise.resolve(fails(rejectedName("can't be blank"))),
    });

    await openTheForm();
    await userEvent.clear(nameInput());
    await userEvent.type(nameInput(), "x");
    await userEvent.click(screen.getByRole("button", { name: /save name/i }));

    // The server's own per-field sentence, not this client's generic
    // "That was not accepted" — which is the one place `failure-message.ts`
    // says the server's words win, because they name the thing that was typed.
    expect(await screen.findByText(/can't be blank/i)).toBeInTheDocument();
    expect(screen.getByText("Captain Nemo")).toBeInTheDocument();
    expect(nameInput()).toHaveValue("x");
  });

  it("says so in this client's words when the server cannot be reached", async () => {
    renderSignedIn({ changeDisplayName: () => Promise.resolve(fails(offline())) });

    await openTheForm();
    await userEvent.click(screen.getByRole("button", { name: /save name/i }));

    expect(await screen.findByText(/could not be reached/i)).toBeInTheDocument();
    expect(screen.getByText("Captain Nemo")).toBeInTheDocument();
  });

  it("leaves the name alone when the form is cancelled", async () => {
    const changeDisplayName = vi.fn(() => Promise.resolve(fails<never>(offline())));
    renderSignedIn({ changeDisplayName });

    await openTheForm();
    await userEvent.clear(nameInput());
    await userEvent.type(nameInput(), "Somebody Else");
    await userEvent.click(screen.getByRole("button", { name: /cancel/i }));

    expect(await screen.findByText("Captain Nemo")).toBeInTheDocument();
    expect(changeDisplayName).not.toHaveBeenCalled();
  });

  it("starts the form from the name in force, not from an empty box", async () => {
    renderSignedIn();

    await openTheForm();

    expect(nameInput()).toHaveValue("Captain Nemo");
  });
});
