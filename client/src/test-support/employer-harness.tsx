/**
 * The employer page, rendered through the real router against a fake API.
 *
 * U4 wrote this inside `employer-route.test.tsx`; U5 added two more files
 * driving the same page and it moved here rather than being copied twice — the
 * manoeuvre `src/app/use-fetched.ts` and `src/app/instant.ts` already made for
 * production code, applied to the one piece of scaffolding three test files
 * share.
 *
 * It renders the **whole app** at `/employer` rather than the route component
 * alone, because the surface depends on the session provider, the router and
 * the session bar, and a harness that mounted the component bare would test a
 * composition nothing performs.
 *
 * Every path a panel reads is exported below, because a test that spelled one
 * inline would still pass when the production path changed — `readsFrom`
 * answers an unstubbed path with a `404` and the panel renders a failure, which
 * looks like a refusal test doing its job.
 */

import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { vi } from "vitest";

import type { ApiClient } from "../api/client";
import { App } from "../app/app";
import { SessionProvider } from "../session/session-context";
import { createMemoryTokenStore } from "../session/token-store";
import { createMemoryRoomStore } from "../features/rooms/room-store";
import { createFakeApi, ok, readsFrom, somePerson, writesTo } from "./fake-api";

export const HARBOUR = "11111111-1111-4111-8111-111111111111";
export const KOLEKTIV = "22222222-2222-4222-8222-222222222222";

export const VENUES = "/api/employer/venues";
export const PEOPLE = `/api/employer/venues/${HARBOUR}/engagements`;
export const SHIFT_TYPES = `/api/employer/venues/${HARBOUR}/shift-types`;
export const SHIFT_ROOMS = `/api/employer/venues/${HARBOUR}/shift-rooms`;

export const OFFER = `POST /api/employer/venues/${HARBOUR}/invitations`;
export const CREATE_SHIFT = `POST ${SHIFT_ROOMS}`;

/** `GET …/shift-rooms/:id/roster`, which is also the `POST` target. */
export function rosterPath(shiftRoomId: string): string {
  return `${SHIFT_ROOMS}/${shiftRoomId}/roster`;
}

/** `DELETE …/roster/:engagement_id` — the one call that answers `204`. */
export function removalPath(shiftRoomId: string, engagementId: string): string {
  return `${rosterPath(shiftRoomId)}/${engagementId}`;
}

export const twoVenues = {
  venues: [
    { venue_id: HARBOUR, name: "Harbour Tavern" },
    { venue_id: KOLEKTIV, name: "Kolektiv" },
  ],
};

export function engagementBody(id: string, roleLabel: string) {
  return {
    engagement_id: id,
    role_label: roleLabel,
    starts_at: "2026-03-09T13:00:00Z",
    ends_at: "2026-06-07T13:00:00Z",
  };
}

export function renderEmployer(
  bodies: Readonly<Record<string, unknown>> = {},
  write: ApiClient["write"] = writesTo({}),
) {
  // `readsFrom` behind a recorder, because `ApiClient["read"]` is a generic
  // function type and `vi.mocked(...).mock.calls` does not survive it. `paths`
  // is what "asked twice" and "asked with `?extent=all`" are counted on;
  // `toHaveBeenCalledWith` still works, since this is a `vi.fn` at runtime.
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
export async function chooseHarbour() {
  await userEvent.click(await screen.findByRole("button", { name: "Harbour Tavern" }));

  return screen.findByRole("region", { name: "Harbour Tavern" });
}
