/**
 * Flow F1's other half: the second window, a fresh address, and a code that
 * changes hands.
 *
 * The panel is driven through the real component against a fake `write`, and
 * every body is `HospitalityComsWeb.ClaimController`'s shape read out of that
 * module.
 *
 * ## R6 is the reason two of these tests exist rather than one
 *
 * An unknown code, a claimed code and an expired one are refused
 * *distinguishably* — the only place in this API that is not flat — and
 * `ErrorEnvelope`'s `code` **is** the status atom, so `409` covers both
 * `:already_claimed` and `:grant_not_live` with two opposite instructions to
 * the person reading them. A panel keyed on the code could carry one. So the
 * sentence is asserted as *carried*: one test watches a sentence arrive, and a
 * second sends a different sentence under the same code and watches that one
 * arrive instead.
 */

import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { ApiClient } from "../../api/client";
import type { RequestFailure } from "../../api/errors";
import { App } from "../../app/app";
import { instantLabel, termLabel } from "../../app/instant";
import { SessionProvider } from "../../session/session-context";
import { createMemoryTokenStore } from "../../session/token-store";
import { createFakeApi, ok, somePerson, writesTo } from "../../test-support/fake-api";
import { createMemoryRoomStore } from "../rooms/room-store";

const CLAIM = "POST /api/claims";
const VENUE_ID = "11111111-1111-4111-8111-111111111111";
const ENGAGEMENT_ID = "33333333-3333-4333-8333-333333333333";

const claimed = {
  engagement: {
    engagement_id: ENGAGEMENT_ID,
    venue_id: VENUE_ID,
    role_label: "Runner",
    starts_at: "2026-03-09T13:00:00Z",
    ends_at: "2026-06-07T13:00:00Z",
    accepted_at: "2026-03-09T13:05:00Z",
  },
};

function refusal(status: number, rawCode: string, message: string): RequestFailure {
  return { kind: "api_error", status, code: "unrecognised", rawCode, message };
}

function renderClaim(write: ApiClient["write"] = writesTo({})) {
  const api = createFakeApi({
    currentPerson: () => Promise.resolve(ok(somePerson)),
    logOut: () => Promise.resolve(ok(null)),
    write,
  });

  render(
    <MemoryRouter initialEntries={["/claim"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <App roomStore={createMemoryRoomStore()} />
      </SessionProvider>
    </MemoryRouter>,
  );

  return { write };
}

async function paste(code: string) {
  await userEvent.type(await screen.findByLabelText(/claim code/i), code);
  await userEvent.click(screen.getByRole("button", { name: /claim this job/i }));
}

describe("claiming a code", () => {
  it("sends the code and nothing else, and shows what it produced", async () => {
    // `claim_invitation/2` casts nothing from the caller: accepting an offer is
    // accepting *the* offer, so a body with anything else in it would be a
    // client asking for a term the invitation did not offer.
    const { write } = renderClaim(writesTo({ [CLAIM]: { body: claimed } }));

    await paste("Y29kZS1oYW5kZWQtb3Zlcg");

    const panel = await screen.findByRole("status");

    expect(panel).toHaveTextContent("Runner");
    expect(panel).toHaveTextContent(VENUE_ID);
    expect(panel).toHaveTextContent(ENGAGEMENT_ID);

    expect(write).toHaveBeenCalledWith(
      {
        method: "POST",
        path: "/api/claims",
        body: { claim_code: "Y29kZS1oYW5kZWQtb3Zlcg" },
        status: 201,
      },
      expect.any(String),
      expect.any(Function),
    );
  });

  it("writes both instants, because acceptance and the term's start are different questions", async () => {
    // KTD13: an engagement accepted before its term opens is confirmed and not
    // yet active. The panel renders both rather than collapsing them, and this
    // fixture pulls them apart so a component showing one twice fails.
    renderClaim(
      writesTo({
        [CLAIM]: {
          body: {
            engagement: { ...claimed.engagement, accepted_at: "2026-03-01T09:00:00Z" },
          },
        },
      }),
    );

    await paste("Y29kZQ");

    const panel = await screen.findByRole("status");

    // Both labels, each read back out of the renderer that produced it rather
    // than spelled here — `room.test.ts`'s rule, because every one of them
    // resolves the runner's timezone. The two are deliberately different
    // instants, so a panel writing one of them twice fails.
    expect(panel.textContent).toContain(instantLabel("2026-03-01T09:00:00Z"));
    expect(panel.textContent).toContain(
      termLabel("2026-03-09T13:00:00Z", "2026-06-07T13:00:00Z"),
    );
    expect(panel.textContent).not.toContain("2026-03-01T09:00:00Z");
    expect(panel.textContent).not.toContain("2026-03-09T13:00:00Z");
  });

  it("does not call the API for an empty submission", async () => {
    // The server's own answer to an empty body is `400 "claim_code is
    // required"`, which names a wire field rather than anything the worker did.
    // Asserted on the call count, because the sentence on screen is the same
    // whether or not the request went.
    const { write } = renderClaim(writesTo({ [CLAIM]: { body: claimed } }));

    await userEvent.click(await screen.findByRole("button", { name: /claim this job/i }));

    expect(write).not.toHaveBeenCalled();
    expect(await screen.findByRole("alert")).toHaveTextContent(
      /paste the code into the box/i,
    );
  });

  it("does not call the API for a submission that is only spaces", async () => {
    const { write } = renderClaim(writesTo({ [CLAIM]: { body: claimed } }));

    await paste("   ");

    expect(write).not.toHaveBeenCalled();
  });

  it("claims once however fast the button is clicked", async () => {
    // A code is single use, so the second attempt is refused `409 already
    // claimed` — and that sentence would be written over the engagement the
    // first attempt just produced, about a code that has now genuinely gone.
    const write = vi.fn(() => new Promise<never>(() => undefined)) as ApiClient["write"];
    renderClaim(write);

    await userEvent.type(await screen.findByLabelText(/claim code/i), "Y29kZQ");

    const submit = screen.getByRole("button", { name: /claim this job/i });
    await userEvent.click(submit);
    await userEvent.click(submit);

    expect(write).toHaveBeenCalledOnce();
    expect(submit).toBeDisabled();
  });
});

describe("a refused claim", () => {
  it("renders the sentence the server sent", async () => {
    renderClaim(
      writesTo({
        [CLAIM]: { failure: refusal(410, "gone", "that claim code has expired") },
      }),
    );

    await paste("bGFwc2Vk");

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "that claim code has expired",
    );
  });

  // **The control.** Same status, same code, a different sentence. A panel
  // hard-coding a string that happened to match the fixture above passes that
  // test and fails this one, and a panel keyed on `code` renders one sentence
  // for both — which is exactly the case `ClaimController` says it will not
  // give a status of its own.
  it("renders a different server sentence under the same code", async () => {
    renderClaim(
      writesTo({
        [CLAIM]: {
          failure: refusal(
            409,
            "conflict",
            "the authority this offer confers is no longer live",
          ),
        },
      }),
    );

    await paste("cmV2b2tlZA");

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("the authority this offer confers is no longer live");
    expect(alert).not.toHaveTextContent("already been redeemed");
  });

  it("renders the other 409, which shares a code with the one above and means the opposite", async () => {
    // `:already_claimed` — the offer is gone for good — against
    // `:grant_not_live` — the code is unspent and re-issuing the authority
    // makes it work again. Two `conflict`s, two opposite instructions.
    renderClaim(
      writesTo({
        [CLAIM]: {
          failure: refusal(409, "conflict", "that claim code has already been redeemed"),
        },
      }),
    );

    await paste("dGFrZW4");

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent("that claim code has already been redeemed");
    expect(alert).not.toHaveTextContent("no longer live");
  });

  it("words the session's own failure itself, because that one is not this route's", async () => {
    renderClaim(
      writesTo({
        [CLAIM]: {
          failure: {
            kind: "api_error",
            status: 401,
            code: "unauthorized",
            rawCode: "unauthorized",
            message: "the request carries no live session token",
          },
        },
      }),
    );

    await paste("Y29kZQ");

    const alert = await screen.findByRole("alert");

    expect(alert).toHaveTextContent(/your session has ended/i);
    expect(alert).not.toHaveTextContent("the request carries no live session token");
  });

  it("leaves the form usable and the code where it was typed", async () => {
    // A refusal is not a reason to make somebody find the code again. It is
    // cleared only on success, where keeping it would invite a second claim of
    // a code that is now spent.
    renderClaim(
      writesTo({
        [CLAIM]: {
          failure: refusal(404, "not_found", "no offer matches that claim code"),
        },
      }),
    );

    await paste("d3Jvbmc");

    await screen.findByRole("alert");

    expect(screen.getByLabelText(/claim code/i)).toHaveValue("d3Jvbmc");
    expect(screen.getByRole("button", { name: /claim this job/i })).toBeEnabled();
  });
});
