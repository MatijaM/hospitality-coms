/**
 * Flow F1's employer half, driven through the real components against a fake
 * `read` and a fake `write`.
 *
 * Every body below is the shape `HospitalityComsWeb.EmployerController` renders,
 * read out of that module rather than assumed, and it goes through the real
 * decoders on its way in — so a fixture that is not the server's shape fails
 * here as `malformed_response` exactly as it would in a browser.
 *
 * ## Two properties here are not "does it render"
 *
 * **The picker asks `/api/employer/venues`.** `GET /api/venue-rooms` returns the
 * same two keys, needs no new route, and subtracts suspensions — so a manager
 * who opted out of their own venue room would keep every authority and vanish
 * from this page. The assertion is on the path, because nothing about the
 * rendered list distinguishes the two reads.
 *
 * **A refusal renders the server's sentence, and there are two tests for it.**
 * One shows a sentence arriving; the second sends a *different* sentence under
 * the same code and watches that one arrive. Without the second, a component
 * hard-coding a string that happened to match would pass — and on this surface
 * the code genuinely cannot carry the distinction, because `ClaimController`
 * answers `409` twice with two opposite instructions.
 */

import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../../api/client";
import type { RequestFailure } from "../../api/errors";
import { App } from "../../app/app";
import { instantLabel, termLabel } from "../../app/instant";
import { SessionProvider } from "../../session/session-context";
import { createMemoryTokenStore } from "../../session/token-store";
import {
  createFakeApi,
  ok,
  readsFrom,
  somePerson,
  writesTo,
} from "../../test-support/fake-api";
import { createMemoryRoomStore } from "../rooms/room-store";

const HARBOUR = "11111111-1111-4111-8111-111111111111";
const KOLEKTIV = "22222222-2222-4222-8222-222222222222";

const VENUES = "/api/employer/venues";
const PEOPLE = `/api/employer/venues/${HARBOUR}/engagements`;
const OFFER = `POST /api/employer/venues/${HARBOUR}/invitations`;

const twoVenues = {
  venues: [
    { venue_id: HARBOUR, name: "Harbour Tavern" },
    { venue_id: KOLEKTIV, name: "Kolektiv" },
  ],
};

function engagement(id: string, roleLabel: string) {
  return {
    engagement_id: id,
    role_label: roleLabel,
    starts_at: "2026-03-09T13:00:00Z",
    ends_at: "2026-06-07T13:00:00Z",
  };
}

const issuedOffer = {
  invitation: {
    invitation_id: "44444444-4444-4444-8444-444444444444",
    role_label: "Runner",
    starts_at: "2026-03-09T13:00:00Z",
    ends_at: "2026-06-07T13:00:00Z",
    code_expires_at: "2026-03-16T13:00:00Z",
  },
  claim_code: "Y29kZS1oYW5kZWQtb3Zlcg",
};

function refusal(status: number, code: string, message: string): RequestFailure {
  return { kind: "api_error", status, code: "unrecognised", rawCode: code, message };
}

function renderEmployer(
  bodies: Readonly<Record<string, unknown>> = {},
  write: ApiClient["write"] = writesTo({}),
) {
  // `readsFrom` behind a recorder, because `ApiClient["read"]` is a generic
  // function type and `vi.mocked(...).mock.calls` does not survive it. `paths`
  // is what "asked twice" is counted on; `toHaveBeenCalledWith` still works,
  // since this is a `vi.fn` at runtime.
  const paths: string[] = [];
  const answered = readsFrom(bodies);
  const read = vi.fn(
    (path: string, token: string, decode: (body: unknown) => unknown) => {
      paths.push(path);

      return answered(path, token, decode);
    },
  ) as ApiClient["read"];

  const api = createFakeApi({
    currentPerson: () => Promise.resolve(ok(somePerson)),
    logOut: () => Promise.resolve(ok(null)),
    read,
    write,
  });

  render(
    <MemoryRouter initialEntries={["/employer"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <App roomStore={createMemoryRoomStore()} />
      </SessionProvider>
    </MemoryRouter>,
  );

  return { read, write, paths };
}

/** Picks Harbour Tavern out of the venue list and waits for its desk. */
async function chooseHarbour() {
  await userEvent.click(await screen.findByRole("button", { name: "Harbour Tavern" }));

  return screen.findByRole("region", { name: "Harbour Tavern" });
}

async function offer(role: string) {
  await userEvent.type(await screen.findByLabelText(/^role$/i), role);
  await userEvent.click(screen.getByRole("button", { name: /offer this job/i }));
}

describe("the venue picker", () => {
  it("reads the grant-based list, not the venue-room one", async () => {
    // The one decision in U4 that changes what the demo shows.
    // `Rooms.list_venue_rooms/1` answers the same `{venue_id, name}` shape and
    // applies `unsuspended/2`; `fetch_grant_holding_engagement/2` never
    // consults a suspension. A manager who used the venue-room opt-out keeps
    // full authority and disappears from their own picker, with nothing
    // failing anywhere to say so — which is why this is asserted on the path
    // rather than on what came back.
    const { read } = renderEmployer({ [VENUES]: twoVenues });

    await screen.findByRole("list", { name: /venues you can act for/i });

    expect(read).toHaveBeenCalledWith(VENUES, expect.any(String), expect.any(Function));
    expect(read).not.toHaveBeenCalledWith(
      "/api/venue-rooms",
      expect.any(String),
      expect.any(Function),
    );
  });

  it("names each venue rather than showing its id", async () => {
    renderEmployer({ [VENUES]: twoVenues });

    const list = await screen.findByRole("list", { name: /venues you can act for/i });

    expect(within(list).getByRole("button", { name: "Harbour Tavern" })).toBeVisible();
    expect(within(list).getByRole("button", { name: "Kolektiv" })).toBeVisible();
    expect(list.textContent).not.toContain(HARBOUR);
  });

  // AE10, and the sentence is the requirement rather than the absence: "not an
  // error, and not an empty page".
  it("says why the page is empty when this person manages nothing", async () => {
    renderEmployer({ [VENUES]: { venues: [] } });

    expect(await screen.findByText(/you cannot act for any venue/i)).toBeVisible();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("list", { name: /venues you can act for/i }),
    ).not.toBeInTheDocument();
  });

  it("asks for nobody's people until a venue is chosen", async () => {
    // The control for the test below it: a page that fetched every venue's
    // people on arrival would still pass "choosing loads that venue's people".
    const { read } = renderEmployer({
      [VENUES]: twoVenues,
      [PEOPLE]: { engagements: [] },
    });

    await screen.findByRole("list", { name: /venues you can act for/i });

    expect(read).toHaveBeenCalledTimes(1);
    expect(read).not.toHaveBeenCalledWith(
      PEOPLE,
      expect.any(String),
      expect.any(Function),
    );
  });

  it("loads the chosen venue's people", async () => {
    const { read } = renderEmployer({
      [VENUES]: twoVenues,
      [PEOPLE]: {
        engagements: [engagement("33333333-3333-4333-8333-333333333333", "Runner")],
      },
    });

    await chooseHarbour();

    expect(
      await screen.findByRole("list", { name: /people here now/i }),
    ).toHaveTextContent(/runner/i);
    expect(read).toHaveBeenCalledWith(PEOPLE, expect.any(String), expect.any(Function));
  });
});

describe("the venue's people", () => {
  it("shows the role and the term, and no person id however the server answers", async () => {
    // R7 and AE6 from this side. The decoder names its fields one at a time,
    // so a `person_id` the server should never send reaches nothing past it —
    // and this fixture sends one, because a payload without one would make the
    // assertion pass for the wrong reason.
    renderEmployer({
      [VENUES]: twoVenues,
      [PEOPLE]: {
        engagements: [
          {
            ...engagement("33333333-3333-4333-8333-333333333333", "Runner"),
            person_id: "99999999-9999-4999-8999-999999999999",
            email: "runner@example.com",
          },
        ],
      },
    });

    await chooseHarbour();

    const list = await screen.findByRole("list", { name: /people here now/i });

    // The term is read back out of `termLabel` rather than spelled here, for
    // `room.test.ts`'s reason: every rendering of an instant resolves the
    // runner's timezone, and a fixture spelling "9 Mar" is green on one machine
    // and red on another. What is asserted is that the term is *formatted* —
    // the raw ISO strings are what a worker was shown before the rooms surface
    // fixed the same thing.
    expect(list).toHaveTextContent(/runner/i);
    expect(list.textContent).toContain(
      termLabel("2026-03-09T13:00:00Z", "2026-06-07T13:00:00Z"),
    );
    expect(list.textContent).not.toContain("2026-03-09T13:00:00Z");
    expect(list.textContent).not.toContain("99999999-9999-4999-8999-999999999999");
    expect(list.textContent).not.toContain("runner@example.com");
    expect(document.body.textContent).not.toContain("runner@example.com");
  });

  it("re-asks the server rather than deriving the list from anything held here", async () => {
    // `list_engagements/1` is active-at-instant and membership is stored
    // nowhere, so the answer changes with no job having run — and the claim
    // made in the other window is F1's last step. Nothing is cached, so the
    // refresh is a second request rather than a re-render.
    const { paths } = renderEmployer({
      [VENUES]: twoVenues,
      [PEOPLE]: { engagements: [] },
    });

    await chooseHarbour();
    await screen.findByText(/nobody is engaged here at the moment/i);

    await userEvent.click(screen.getByRole("button", { name: /refresh this list/i }));

    await waitFor(() => {
      expect(paths.filter((path) => path === PEOPLE)).toHaveLength(2);
    });
  });

  it("says so when the list cannot be read, and offers to ask again", async () => {
    // A failure has to read as a failure rather than as an empty venue.
    // "Nobody is engaged here" in front of a manager whose venue has six
    // people is the worst answer available.
    //
    // The sentence asserted is `readsFrom`'s own 404 fixture, verbatim. It is
    // worded for a room because the fake is shared — and reading it back on
    // this page is the point: what is on screen is what the envelope carried,
    // not a sentence this file could have written.
    renderEmployer({ [VENUES]: twoVenues });

    await chooseHarbour();

    expect(
      await screen.findByText("no such room, or it is not one you can reach"),
    ).toBeVisible();
    expect(screen.getAllByRole("button", { name: /try again/i })).not.toHaveLength(0);
    expect(screen.queryByText(/nobody is engaged here/i)).not.toBeInTheDocument();
  });
});

describe("issuing an offer", () => {
  it("sends the role label and nothing else, and shows the code with its warning", async () => {
    // The three instants are optional on the route and defaulted from the
    // request's instant. A client that computed them would be a second clock —
    // `Clock.Offset` moves the server's and not this browser's — so the body
    // is asserted exactly rather than loosely.
    const write = writesTo({ [OFFER]: { body: issuedOffer } });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    const panel = await screen.findByRole("status");

    expect(panel).toHaveTextContent("Y29kZS1oYW5kZWQtb3Zlcg");
    expect(panel).toHaveTextContent(/shown once and nothing can show it again/i);
    // When it stops working, formatted, and never compared against this
    // browser's clock: `Clock.Offset` moves the server's instant and not this
    // one, so a "expires in 7 days" computed here would be wrong during
    // exactly the demo the offset exists for.
    expect(panel.textContent).toContain(instantLabel("2026-03-16T13:00:00Z"));
    expect(panel.textContent).not.toContain("2026-03-16T13:00:00Z");

    expect(write).toHaveBeenCalledWith(
      {
        method: "POST",
        path: `/api/employer/venues/${HARBOUR}/invitations`,
        body: { role_label: "Runner" },
        status: 201,
      },
      expect.any(String),
      expect.any(Function),
    );
  });

  it("issues once however fast the button is clicked", async () => {
    // Two clicks are two invitations — nothing deduplicates an offer (AE2) — so
    // the second mints a live claim code, shows the manager that one, and
    // loses the first for ever.
    const write = vi.fn(() => new Promise<never>(() => undefined)) as ApiClient["write"];
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await userEvent.type(await screen.findByLabelText(/^role$/i), "Runner");

    const submit = screen.getByRole("button", { name: /offer this job/i });
    await userEvent.click(submit);
    await userEvent.click(submit);

    expect(write).toHaveBeenCalledOnce();
    expect(submit).toBeDisabled();
  });

  it("does not offer a blank role", async () => {
    const write = writesTo({ [OFFER]: { body: issuedOffer } });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await userEvent.click(screen.getByRole("button", { name: /offer this job/i }));

    expect(write).not.toHaveBeenCalled();
  });

  it("hides the code when it is dismissed, and re-rendering does not bring it back", async () => {
    // **The positive state is reached first, on purpose.** The plaintext code
    // lives in component state and nowhere else, so "hidden" and "never
    // rendered" are the same DOM — a test that only asserted the absence would
    // pass against a page that never showed a code at all.
    //
    // The re-render is the assertion. Dismissing is destructive: nothing on any
    // route can produce that string again, so a state update that brought it
    // back would mean it was being held somewhere it should not be.
    const write = writesTo({ [OFFER]: { body: issuedOffer } });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    expect(await screen.findByText("Y29kZS1oYW5kZWQtb3Zlcg")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: /i have copied it/i }));

    expect(screen.queryByText("Y29kZS1oYW5kZWQtb3Zlcg")).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: /refresh this list/i }));
    await waitFor(() => {
      expect(screen.queryByText("Y29kZS1oYW5kZWQtb3Zlcg")).not.toBeInTheDocument();
    });

    expect(document.body.textContent).not.toContain("Y29kZS1oYW5kZWQtb3Zlcg");
  });

  it("drops the code when the session ends", async () => {
    // Hospitality is a shared-terminal industry and this is a live credential
    // for a job at somebody's venue. It is held in component state, so log-out
    // unmounting the surface is what loses it — asserted rather than assumed,
    // and after showing it, so "gone" is not "never there".
    const write = writesTo({ [OFFER]: { body: issuedOffer } });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    expect(await screen.findByText("Y29kZS1oYW5kZWQtb3Zlcg")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: /log out/i }));

    expect(await screen.findByLabelText(/email address/i)).toBeInTheDocument();
    expect(document.body.textContent).not.toContain("Y29kZS1oYW5kZWQtb3Zlcg");
  });

  it("loses the code when another venue is chosen", async () => {
    // A code belongs to one offer at one venue, and carrying it across would
    // put it beside the wrong venue's name. The desk is keyed on the venue, so
    // switching remounts rather than re-renders.
    const write = writesTo({ [OFFER]: { body: issuedOffer } });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    expect(await screen.findByText("Y29kZS1oYW5kZWQtb3Zlcg")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: "Kolektiv" }));

    expect(await screen.findByRole("region", { name: "Kolektiv" })).toBeVisible();
    expect(document.body.textContent).not.toContain("Y29kZS1oYW5kZWQtb3Zlcg");
  });
});

describe("a refused offer", () => {
  it("renders the sentence the server sent", async () => {
    const write = writesTo({
      [OFFER]: {
        failure: {
          kind: "api_field_error",
          status: 422,
          code: "unprocessable_entity",
          rawCode: "unprocessable_entity",
          message: "the offer was not accepted",
          fields: { role_label: ["should be at most 160 character(s)"] },
        },
      },
    });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("the offer was not accepted");
    // The per-field messages are Ecto's and name an input the manager filled
    // in, which is the one exception the standing "never render the server's
    // message" rule already makes.
    expect(alert).toHaveTextContent(/should be at most 160 character\(s\)/i);
  });

  // **The control.** Same code, different sentence. A component that hard-coded
  // a string which happened to match the first fixture passes that test and
  // fails this one; a component keyed on `code` passes both by rendering one
  // sentence twice, which is why the assertion is also that the *first*
  // sentence is absent.
  it("renders a different server sentence under the same code", async () => {
    const write = writesTo({
      [OFFER]: {
        failure: refusal(
          422,
          "unprocessable_entity",
          "that role is not one this venue hires",
        ),
      },
    });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("that role is not one this venue hires");
    expect(alert).not.toHaveTextContent("the offer was not accepted");
  });

  it("renders a sentence for a status this client has no code for", async () => {
    // `409 conflict` is outside `KNOWN_ERROR_CODES`, which is traced through
    // the four session endpoints alone, so it decodes as `unrecognised` with
    // the wire value kept. Reading the sentence is what makes that harmless
    // here; a switch on the code would have said "a status this client does
    // not know about" and nothing else.
    const write = writesTo({
      [OFFER]: {
        failure: refusal(
          409,
          "conflict",
          "the authority this offer would confer is no longer live",
        ),
      },
    });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "the authority this offer would confer is no longer live",
    );
  });

  it("words the session's own failure itself, because that one is not this route's", async () => {
    // `unauthorized` comes from `PersonAuth`, a pipeline above every employer
    // controller, and its sentence — "the request carries no live session
    // token" — is written for a log. It is the one refusal here whose copy
    // stays local.
    const write = writesTo({
      [OFFER]: {
        failure: {
          kind: "api_error",
          status: 401,
          code: "unauthorized",
          rawCode: "unauthorized",
          message: "the request carries no live session token",
        },
      },
    });
    renderEmployer({ [VENUES]: twoVenues, [PEOPLE]: { engagements: [] } }, write);

    await chooseHarbour();
    await offer("Runner");

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent(/your session has ended/i);
    expect(alert).not.toHaveTextContent("the request carries no live session token");
  });
});
