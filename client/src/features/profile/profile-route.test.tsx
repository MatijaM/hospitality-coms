/**
 * The profile surface, driven through the real components against the fake
 * socket.
 *
 * **Every payload here is `contract.ts`'s shape and no server emits one.** The
 * other three slices could say "read out of the channel module"; this one is
 * derived from `HospitalityComs.Profiles`' `@spec`s and its four render/schema
 * modules, with the wire casing chosen in `contract.ts`. That is the whole of
 * the difference and it is stated rather than glossed.
 *
 * ## What these tests are actually for
 *
 * Two of the properties below are U9's rules holding at the render layer,
 * which is the one place the database and the context cannot reach:
 *
 *   * the standing notice is one string per session, off the join, and neither
 *     a profile reply nor the record it sits beside can influence it;
 *   * an audience the worker has not decided about renders as undecided and
 *     never as visible.
 *
 * A third was here and is not: *a viewer of somebody else's record cannot tell
 * a worker concealing three jobs from one who has only ever had the one*. #73
 * took the surface that rendered somebody else's record off the screen, so
 * that rule has no render layer to hold and asserting it would be an empty
 * region measured against an empty rule. The block below records the
 * obligation to bring it back with the section.
 *
 * The rest are this client's own conventions: the shared-terminal clear, the
 * in-flight guards, and which reads an action is allowed to issue.
 *
 * ## Two blocks drive the hook rather than the components
 *
 * The last two, and only those. What a write **comes back with** is part of
 * `ProfileSurface`'s type and is deliberately rendered nowhere — appending a
 * declared entry the server has just confirmed would put it at the end of a
 * list ordered by term — so there is no DOM through which it can be observed.
 * It is asserted anyway, because it is the half of `contract.ts` this client
 * can check: the first thing a transport will do wrong is answer an event in a
 * shape this feature did not describe.
 *
 * `peer_profile` is in the second of the two for a different reason and it is
 * the load-bearing one: since #73 nothing on screen asks it, so the hook is the
 * only place the capability is reachable at all. Driving it there is what makes
 * "the section is hidden" distinguishable from "the feature was deleted", which
 * is the claim #73 rests on.
 */

import {
  act,
  cleanup,
  render,
  renderHook,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { ReactNode } from "react";
import { MemoryRouter } from "react-router";
import { describe, expect, it } from "vitest";

import { App } from "../../app/app";
import { SessionProvider } from "../../session/session-context";
import { createMemoryTokenStore } from "../../session/token-store";
import { SocketProvider } from "../../socket/socket-context";
import { createFakeApi, ok } from "../../test-support/fake-api";
import type { FakeChannel } from "../../test-support/fake-socket";
import { fakeSocketFactory } from "../../test-support/fake-socket";
import { createMemoryRoomStore } from "../rooms/room-store";
import { PROFILE_EVENTS } from "./contract";
import { normalisePersonId, profileTopic } from "./profile";
import { useProfileSurface } from "./use-profile-surface";

const PERSON_ID = "a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5";
const PEER_ID = "c3c3c3c3-d4d4-4e5e-8f6f-a7a7a7a7a7a7";
const ENGAGEMENT_ID = "22222222-2222-4222-8222-222222222222";
const OTHER_ENGAGEMENT_ID = "99999999-9999-4999-8999-999999999999";
const AUDIENCE_VENUE_ID = "77777777-7777-4777-8777-777777777777";
const OTHER_AUDIENCE_VENUE_ID = "88888888-8888-4888-8888-888888888888";

/**
 * The two audiences `list_audiences` offers, and both are deliberately not the
 * entry's own venue.
 *
 * An entry is never hidden from the venue that wrote it, so a fixture whose
 * only audience is "The Anchor" would be a fixture of the one audience the
 * control is useless for — which is the picker `DisclosureControl`'s old
 * docstring said was the only one this surface could have built.
 */
const AUDIENCE_VENUE_NAME = "The Bell";
const OTHER_AUDIENCE_VENUE_NAME = "The Crown";
const AUDIENCE_PERSON_NAME = "Allan Quatermain";

/** `Profiles.incompleteness_notice/0`, verbatim. */
const NOTICE =
  "This record may be incomplete. A worker chooses which of their entries each employer and each peer can see.";

const READS = [
  PROFILE_EVENTS.ownProfile,
  PROFILE_EVENTS.listDisclosures,
  PROFILE_EVENTS.listAudiences,
] as const;

/** `VisibleEntry`. */
function entryWire(overrides: Record<string, unknown> = {}) {
  return {
    attested_entry_id: "11111111-1111-4111-8111-111111111111",
    entry_engagement_id: ENGAGEMENT_ID,
    venue_id: "33333333-3333-4333-8333-333333333333",
    venue_name: "The Anchor",
    role_label: "Bartender",
    starts_at: "2026-01-01T00:00:00Z",
    ends_at: "2026-06-01T00:00:00Z",
    attested_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

/** A second job, at a second venue, whose term overlaps the first. */
function secondJobWire(overrides: Record<string, unknown> = {}) {
  return entryWire({
    attested_entry_id: "11111111-2222-4111-8111-111111111111",
    entry_engagement_id: OTHER_ENGAGEMENT_ID,
    venue_id: "33333333-4444-4333-8333-333333333333",
    venue_name: "The Crown",
    role_label: "Supervisor",
    ...overrides,
  });
}

/** A rendered `DeclaredEntry` — `declared_entry_id`, never `id`. */
function declaredWire(overrides: Record<string, unknown> = {}) {
  return {
    declared_entry_id: "44444444-4444-4444-8444-444444444444",
    role_label: "Chef",
    organisation_name: "A kitchen with no account here",
    starts_at: "2024-01-01T00:00:00Z",
    ends_at: "2025-01-01T00:00:00Z",
    declared_at: "2026-07-01T00:00:00Z",
    ...overrides,
  };
}

/** `VisibleCorrection`. */
function correctionWire(overrides: Record<string, unknown> = {}) {
  return {
    correction_request_id: "55555555-5555-4555-8555-555555555555",
    entry_engagement_id: ENGAGEMENT_ID,
    venue_id: "33333333-3333-4333-8333-333333333333",
    body: "I worked until June, not April.",
    requested_at: "2026-07-02T00:00:00Z",
    resolved_at: null,
    resolution: null,
    ...overrides,
  };
}

/** A rendered `Disclosure` — the tagged audience, in both directions. */
function disclosureWire(overrides: Record<string, unknown> = {}) {
  return {
    disclosure_id: "66666666-6666-4666-8666-666666666666",
    engagement_id: ENGAGEMENT_ID,
    audience_kind: "venue",
    audience_id: AUDIENCE_VENUE_ID,
    disclosed: false,
    decided_at: "2026-07-03T00:00:00Z",
    ...overrides,
  };
}

/** The envelope `ErrorEnvelope.new/2` builds, with a message nobody renders. */
function refusal(code: string, message = "SERVER-SIDE LOG SENTENCE") {
  return { error: { code, message } };
}

type Record_ = {
  readonly attested?: readonly object[];
  readonly declared?: readonly object[];
  readonly corrections?: readonly object[];
  readonly disclosures?: readonly object[];
  /**
   * `list_audiences`' two halves.
   *
   * They default to one of each rather than to empty, because the picker is
   * the only way to reach `set_disclosure` and every disclosure test in this
   * file needs something to pick. A test that wants the empty case says so —
   * `?? ` falls back on `undefined` and not on `[]`, so `venues: []` means
   * what it says.
   */
  readonly venues?: readonly object[];
  readonly people?: readonly object[];
};

function profilePayload(record: Record_) {
  return {
    attested_entries: record.attested ?? [],
    declared_entries: record.declared ?? [],
    correction_requests: record.corrections ?? [],
  };
}

/** `rendered_venue/1` — `venue_id`/`name`, the spelling a venue has as itself. */
function audienceVenueWire(overrides: Record<string, unknown> = {}) {
  return { venue_id: AUDIENCE_VENUE_ID, name: AUDIENCE_VENUE_NAME, ...overrides };
}

/** `rendered_person/1` — `person_id`/`display_name`, `rendered_peer/1`'s pair. */
function audiencePersonWire(overrides: Record<string, unknown> = {}) {
  return { person_id: PEER_ID, display_name: AUDIENCE_PERSON_NAME, ...overrides };
}

function audiencesPayload(record: Record_) {
  return {
    venues: record.venues ?? [audienceVenueWire()],
    people: record.people ?? [audiencePersonWire()],
  };
}

function replyFor(event: string, record: Record_) {
  if (event === PROFILE_EVENTS.ownProfile) return profilePayload(record);
  if (event === PROFILE_EVENTS.listAudiences) return audiencesPayload(record);

  return { disclosures: record.disclosures ?? [] };
}

function renderProfile(personId: string) {
  const { socket, createSocket } = fakeSocketFactory();
  const api = createFakeApi({
    currentPerson: () =>
      Promise.resolve(
        ok({ id: personId, email: "worker@example.com", displayName: "Captain Nemo" }),
      ),
  });

  render(
    <MemoryRouter initialEntries={["/profile"]}>
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <SocketProvider createSocket={createSocket}>
          <App roomStore={createMemoryRoomStore()} />
        </SocketProvider>
      </SessionProvider>
    </MemoryRouter>,
  );

  return socket;
}

/** A macrotask, so a push queued behind the ones just seen has landed. */
function settle(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

/**
 * Answers the read pushes the client has issued and not had answered.
 *
 * `expected` is the point of the shape, and it is `peers.test.tsx`'s manoeuvre:
 * every caller names exactly which reads it believes are outstanding, so an
 * action that re-asks something it has no business re-asking fails here rather
 * than passing quietly. `set_disclosure` is the one that matters — it must
 * re-read the ledger and must not re-read the record, and answering whatever
 * had accumulated could not catch the difference.
 */
function serverFor(channel: FakeChannel) {
  const reads: readonly string[] = READS;

  // Answered indices rather than a cursor, which is what `hold` needs: a read
  // left unanswered has to stay outstanding while the reads *after* it are
  // answered, and a cursor can only move past both or neither.
  const answered = new Set<number>();

  function outstanding(): number[] {
    return channel.sent
      .map((sent, index) => (reads.includes(sent.event) ? index : -1))
      .filter((index) => index !== -1 && !answered.has(index));
  }

  function pending(): string[] {
    return outstanding().map((index) => channel.sent[index]?.event ?? "");
  }

  /**
   * @param hold events to leave outstanding, so a render state that only
   * exists *before* an answer can be observed. `list_audiences` is the one
   * that needs it: "still loading" and "answered with nobody" render the same
   * thing unless a test can stop between them.
   */
  async function answerReads(
    expected: readonly string[],
    record: Record_,
    hold: readonly string[] = [],
  ): Promise<void> {
    await waitFor(() => {
      expect(pending()).toEqual([...expected]);
    });

    // And nothing more arrives a turn later. Without this, an over-fetch issued
    // in a microtask behind these would be missed by the assertion above.
    await settle();
    expect(pending()).toEqual([...expected]);

    act(() => {
      for (const index of outstanding()) {
        const sent = channel.sent[index];
        if (sent === undefined || hold.includes(sent.event)) continue;

        answered.add(index);
        sent.push.trigger("ok", replyFor(sent.event, record));
      }
    });
  }

  return { answerReads };
}

/** Answers the most recent push of one event, as the server would. */
function answer(
  channel: FakeChannel,
  event: string,
  status: "ok" | "error" | "timeout",
  payload?: unknown,
): void {
  for (let index = channel.sent.length - 1; index >= 0; index -= 1) {
    if (channel.sent[index]?.event === event) {
      act(() => {
        channel.reply(index, status, payload);
      });

      return;
    }
  }

  throw new Error(`nothing pushed ${event}`);
}

function pushesOf(channel: FakeChannel, event: string) {
  return channel.pushed.filter((sent) => sent.event === event);
}

async function openProfile(
  record: Record_ = {},
  personId: string = PERSON_ID,
  hold: readonly string[] = [],
) {
  const socket = renderProfile(personId);
  const topic = profileTopic(normalisePersonId(personId) ?? "");

  const channel = await waitFor(() => {
    const opened = socket.channelFor(topic);
    if (opened === undefined) throw new Error(`nothing joined ${topic}`);

    return opened;
  });

  act(() => {
    channel.joinPush.trigger("ok", {
      person_id: normalisePersonId(personId),
      incompleteness_notice: NOTICE,
    });
  });

  const server = serverFor(channel);
  await server.answerReads(READS, record, hold);

  return { socket, channel, server };
}

/** One entry's audience picker, found by the label that names that entry. */
function picker(entry: string): Promise<HTMLElement> {
  return screen.findByLabelText(new RegExp(`^who this is about, for ${entry}$`, "i"));
}

/**
 * Picks an audience on one entry's control and presses Show or Hide.
 *
 * `entry` names the entry in both the picker's label and the button's, which is
 * what stops this helper reaching for whichever control happens to be first
 * when a fixture carries two.
 *
 * The audience is named by the **text a worker reads** rather than by an id or
 * by the option's value. The value encodes the tagged union as
 * `<kind>:<id>` and that encoding is `profile-route.tsx`'s business; a helper
 * that spelled it would make every test using it agree with the parser by
 * construction, which is the shape of a test that cannot fail.
 */
async function decide(
  entry: string,
  audience: string,
  which: "Show" | "Hide",
): Promise<void> {
  const control = await picker(entry);

  await userEvent.selectOptions(
    control,
    within(control).getByRole("option", { name: audience }),
  );
  await userEvent.click(
    screen.getByRole("button", { name: new RegExp(`^${which} ${entry} `, "i") }),
  );
}

/** The direct `<li>` children of a list, which nested lists do not add to. */
function rowsOf(list: HTMLElement): readonly Element[] {
  return [...list.children].filter((child) => child.tagName === "LI");
}

describe("the profile surface", () => {
  it("joins `profile:<person_id>` and asks for the record and the ledger", async () => {
    const { channel } = await openProfile();

    expect(channel.topic).toBe(`profile:${PERSON_ID}`);
    expect(channel.pushed.map((sent) => sent.event)).toEqual([...READS]);
  });

  it("lowercases the person before it becomes a topic", async () => {
    // `Ecto.UUID.cast/1` downcases, so an uppercase suffix would still name
    // this person and the join would succeed — while any future announcement,
    // which goes to the literal lowercase string, would never arrive. See
    // `src/socket/topic-id.ts`.
    const { channel } = await openProfile({}, PERSON_ID.toUpperCase());

    expect(channel.topic).toBe(`profile:${PERSON_ID}`);
  });

  it("shows the worker every attested entry, concealed ones included", async () => {
    // `list_attested_entries/1` filters nothing: disclosure governs what others
    // see, and a worker who could not see what they were hiding could not
    // decide about it. The second entry here is the one hidden from a venue.
    await openProfile({
      attested: [entryWire(), secondJobWire()],
      disclosures: [disclosureWire({ engagement_id: OTHER_ENGAGEMENT_ID })],
    });

    const list = await screen.findByRole("list", {
      name: /jobs an employer confirmed/i,
    });

    expect(rowsOf(list)).toHaveLength(2);
    expect(within(list).getByText("Supervisor")).toBeInTheDocument();
  });
});

describe("each attested entry renders its current audience", () => {
  it("names every decision taken about it, and no other entry's", async () => {
    await openProfile({
      attested: [entryWire(), secondJobWire()],
      disclosures: [
        disclosureWire(),
        disclosureWire({
          disclosure_id: "66666666-7777-4666-8666-666666666666",
          engagement_id: OTHER_ENGAGEMENT_ID,
          audience_kind: "person",
          audience_id: PEER_ID,
          disclosed: true,
        }),
      ],
    });

    const first = await screen.findByRole("list", {
      name: /decisions about bartender at the anchor/i,
    });
    expect(rowsOf(first)).toHaveLength(1);
    expect(within(first).getByText("Employer")).toBeInTheDocument();
    expect(within(first).getByText("Hidden")).toBeInTheDocument();

    const second = await screen.findByRole("list", {
      name: /decisions about supervisor at the crown/i,
    });
    expect(rowsOf(second)).toHaveLength(1);
    expect(within(second).getByText("Peer")).toBeInTheDocument();
    expect(within(second).getByText("Shown")).toBeInTheDocument();
  });

  it("says an entry with no decision is undecided, and never that it is visible", async () => {
    // The ledger holds overrides. Both defaults are computed server-side from
    // stored periods and reach no wire this client reads, so "no row" means
    // "you have not decided" — which is not "they can see it". Rendering the
    // reassuring version would tell a worker their second job was disclosed to
    // the venue the concurrency default in fact conceals it from.
    await openProfile({ attested: [entryWire()], disclosures: [] });

    expect(
      await screen.findByText(/you have not made a decision about this entry/i),
    ).toBeInTheDocument();

    expect(
      screen.queryByRole("list", { name: /decisions about bartender/i }),
    ).not.toBeInTheDocument();

    expect(
      screen.getByText(/this page cannot work out what that comes to/i),
    ).toBeInTheDocument();
  });

  it("says an audience it has no row for is undecided, not visible", async () => {
    // The control renders the three-valued answer for whichever audience is
    // selected, and this is the branch where the third value is the whole
    // point: the worker is about to decide about somebody the ledger says
    // nothing about, and "Shown" there would be a claim this client cannot
    // make and which the employer default usually contradicts.
    //
    // Two audiences are offered and the ledger names exactly one of them, so
    // the same control answers differently for each. Before #73 this typed two
    // ids into a text box; the pair of audiences is what carries the property
    // now, and a fixture offering only the decided one could not show the
    // third value at all.
    await openProfile({
      attested: [entryWire()],
      venues: [
        audienceVenueWire(),
        audienceVenueWire({
          venue_id: OTHER_AUDIENCE_VENUE_ID,
          name: OTHER_AUDIENCE_VENUE_NAME,
        }),
      ],
      disclosures: [disclosureWire({ audience_id: AUDIENCE_VENUE_ID })],
    });

    const control = await picker("bartender at the anchor");

    await userEvent.selectOptions(
      control,
      within(control).getByRole("option", { name: OTHER_AUDIENCE_VENUE_NAME }),
    );
    expect(await screen.findByText("Not decided")).toBeInTheDocument();

    await userEvent.selectOptions(
      control,
      within(control).getByRole("option", { name: AUDIENCE_VENUE_NAME }),
    );

    // The same control, a different audience, and now there *is* a row.
    await waitFor(() => {
      expect(screen.queryByText("Not decided")).not.toBeInTheDocument();
    });
    expect(screen.getByText(/right now, for them/i)).toBeInTheDocument();
  });
});

describe("the audience is picked from a list rather than typed as a uuid", () => {
  // #73's second half. `DisclosureControl` made the worker type a raw uuid for
  // an audience that is a venue **or** a person, and its own docstring said
  // why: nothing this client could read enumerated either. #76's
  // `list_audiences` closed that — the venues a worker holds an engagement at
  // *now*, and the people who can see them — so the control is a picker and
  // the kind is no longer a separate choice, because the kind is a fact about
  // whichever row was picked.

  it("asks for the audiences on the join, once, beside the record and the ledger", async () => {
    const { channel } = await openProfile();

    expect(channel.pushed.map((sent) => sent.event)).toEqual([...READS]);
    expect(pushesOf(channel, PROFILE_EVENTS.listAudiences)).toHaveLength(1);
  });

  it("offers both kinds, each under its own heading", async () => {
    await openProfile({ attested: [entryWire()] });

    const control = await picker("bartender at the anchor");

    // Both halves, and they are asserted separately: a picker built from one
    // list works perfectly against every fixture that carries both.
    expect(
      within(control).getByRole("option", { name: AUDIENCE_VENUE_NAME }),
    ).toBeInTheDocument();
    expect(
      within(control).getByRole("option", { name: AUDIENCE_PERSON_NAME }),
    ).toBeInTheDocument();

    // `audienceKindLabel` names them, and the grouping is what tells a worker
    // that "The Bell" is an employer and "Allan Quatermain" is not.
    const groups = [...control.querySelectorAll("optgroup")].map((group) =>
      group.getAttribute("label"),
    );
    expect(groups).toEqual(["Employer", "Peer"]);
  });

  it("chooses nobody until the worker does, and keeps both buttons shut", async () => {
    // Found by mutation: deleting the placeholder option killed nothing, and
    // the state it leaves is worse than untested. A `<select>` whose value
    // matches no option displays the first one, so the control would read "The
    // Bell" while `picked` is still null and both buttons are disabled — a
    // surface showing a chosen audience and refusing to act on it.
    await openProfile({ attested: [entryWire()], disclosures: [] });

    const control = await picker("bartender at the anchor");

    expect(control).toHaveValue("");
    expect(screen.getByRole("button", { name: /^show bartender/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /^hide bartender/i })).toBeDisabled();

    // The control: the buttons open once an audience is chosen, so "disabled"
    // above is a state and not the only state this control has.
    await userEvent.selectOptions(
      control,
      within(control).getByRole("option", { name: AUDIENCE_VENUE_NAME }),
    );
    expect(screen.getByRole("button", { name: /^hide bartender/i })).toBeEnabled();
  });

  it("sends `person` for a person, which a control hard-coding `venue` would not", async () => {
    // Read as a pair with "sends the tagged audience and renders what comes
    // back" below, which picks a venue. Neither alone is sufficient: a control
    // that always says `"venue"` passes that one, and one that always says
    // `"person"` passes this one. The audience is a tagged union and the tag
    // has to come off the row.
    const { channel } = await openProfile({ attested: [entryWire()], disclosures: [] });

    await decide("bartender at the anchor", AUDIENCE_PERSON_NAME, "Hide");

    expect(pushesOf(channel, PROFILE_EVENTS.setDisclosure)).toEqual([
      {
        event: PROFILE_EVENTS.setDisclosure,
        payload: {
          engagement_id: ENGAGEMENT_ID,
          audience_kind: "person",
          audience_id: PEER_ID,
          disclosed: false,
        },
      },
    ]);
  });

  it("claims nothing about emptiness while the list is still in flight", async () => {
    // The render-state prompt, and the reason `audiences` is `null` until
    // answered rather than a pair of empty lists. *In flight* and *answered
    // with nobody* are the same DOM unless the state distinguishes them — and
    // telling a worker there is nobody they can name, because a round trip is
    // half a second old, is #68's venue link again: right until the network is
    // slow, and wrong in the direction that takes the control away.
    //
    // The read is held open by hand. A test that rendered and asserted would
    // see whichever of the two the scheduler happened to leave behind.
    await openProfile({ attested: [entryWire()] }, PERSON_ID, [
      PROFILE_EVENTS.listAudiences,
    ]);

    // The control: the surface is up and populated from the reads that *were*
    // answered. Without this the absence below passes against a failed mount.
    expect(await screen.findByText("Bartender")).toBeInTheDocument();
    expect(
      screen.getByText(/you have not made a decision about this entry/i),
    ).toBeInTheDocument();

    expect(screen.queryByText(/there is nobody to name yet/i)).toBeNull();
  });

  it("says there is nobody to name once the list comes back empty", async () => {
    await openProfile({ attested: [entryWire()], venues: [], people: [] });

    // The control on the assertion below: the sentence is present, so the
    // control was offered and is empty rather than missing altogether.
    expect(await screen.findByText(/there is nobody to name yet/i)).toBeInTheDocument();

    expect(screen.queryByLabelText(/^who this is about/i)).toBeNull();
  });

  it("offers the list when one half is empty and the other is not", async () => {
    // A worker between jobs still has peers for thirty days; a worker at their
    // first venue has an employer and nobody visible yet. Neither is "nobody".
    await openProfile({ attested: [entryWire()], venues: [] });

    const control = await picker("bartender at the anchor");

    expect(
      within(control).getByRole("option", { name: AUDIENCE_PERSON_NAME }),
    ).toBeInTheDocument();
    expect(
      within(control).queryByRole("option", { name: AUDIENCE_VENUE_NAME }),
    ).toBeNull();
    expect(screen.queryByText(/there is nobody to name yet/i)).toBeNull();
  });

  it("names a past decision's audience when it is still one the worker can name", async () => {
    await openProfile({
      attested: [entryWire()],
      disclosures: [disclosureWire({ audience_id: AUDIENCE_VENUE_ID })],
    });

    const decisions = within(
      await screen.findByRole("list", {
        name: /decisions about bartender at the anchor/i,
      }),
    );

    expect(
      decisions.getByText(`${AUDIENCE_VENUE_NAME} · ${AUDIENCE_VENUE_ID.slice(0, 8)}`),
    ).toBeInTheDocument();
  });

  it("keeps a decision readable when its audience has left both lists", async () => {
    // The residue, and it is ordinary rather than exceptional.
    // `list_audiences` offers venues where the worker holds an engagement
    // **active at the instant** and people visible-or-connected **now**, while
    // the ledger is permanent — so a decision about last year's employer is
    // still in force and is unnameable. #76 records the same thing from the
    // server's side.
    //
    // What it must never render is an empty name beside the separator:
    // `{name ?? ""} · {shortId(id)}` and `{audiences && name} · …` both put a
    // dangling "· 4a3f1b2c" on screen, read as a rendering fault rather than a
    // fact, and are invisible to a test that only looks for the short id.
    await openProfile({
      attested: [entryWire()],
      venues: [],
      people: [],
      disclosures: [disclosureWire({ audience_id: OTHER_AUDIENCE_VENUE_ID })],
    });

    const list = await screen.findByRole("list", {
      name: /decisions about bartender at the anchor/i,
    });
    const decisions = within(list);

    // The controls: the row is on screen and still says what was decided.
    expect(decisions.getByText(OTHER_AUDIENCE_VENUE_ID.slice(0, 8))).toBeInTheDocument();
    expect(decisions.getByText("Hidden")).toBeInTheDocument();
    expect(decisions.getByText(/still applies/i)).toBeInTheDocument();

    expect(list.textContent).not.toContain(`· ${OTHER_AUDIENCE_VENUE_ID.slice(0, 8)}`);
  });
});

describe("changing a disclosure setting confirms the new state", () => {
  it("sends the tagged audience and renders what comes back", async () => {
    const { channel, server } = await openProfile({
      attested: [entryWire()],
      disclosures: [],
    });

    expect(await screen.findByText(/you have not made a decision/i)).toBeInTheDocument();

    await decide("bartender at the anchor", AUDIENCE_VENUE_NAME, "Hide");

    expect(pushesOf(channel, PROFILE_EVENTS.setDisclosure)).toEqual([
      {
        event: PROFILE_EVENTS.setDisclosure,
        payload: {
          engagement_id: ENGAGEMENT_ID,
          audience_kind: "venue",
          audience_id: AUDIENCE_VENUE_ID,
          disclosed: false,
        },
      },
    ]);

    answer(channel, PROFILE_EVENTS.setDisclosure, "ok", disclosureWire());

    // The decision is confirmed by re-reading the ledger, not by trusting the
    // reply — and by re-reading *only* the ledger. See the next test.
    await server.answerReads([PROFILE_EVENTS.listDisclosures], {
      disclosures: [disclosureWire()],
    });

    const decisions = await screen.findByRole("list", {
      name: /decisions about bartender at the anchor/i,
    });
    expect(within(decisions).getByText("Hidden")).toBeInTheDocument();
    expect(screen.queryByText(/you have not made a decision/i)).not.toBeInTheDocument();
  });

  it("re-reads the ledger and not the record", async () => {
    // A disclosure row governs what *others* see and the worker's own read is
    // unfiltered, so re-reading the record here is a round trip that cannot
    // come back different. `answerReads` fails on an over-fetch rather than
    // absorbing it.
    const { channel, server } = await openProfile({
      attested: [entryWire()],
      disclosures: [],
    });

    await decide("bartender at the anchor", AUDIENCE_VENUE_NAME, "Show");
    answer(
      channel,
      PROFILE_EVENTS.setDisclosure,
      "ok",
      disclosureWire({ disclosed: true }),
    );

    await server.answerReads([PROFILE_EVENTS.listDisclosures], {
      disclosures: [disclosureWire({ disclosed: true })],
    });

    expect(pushesOf(channel, PROFILE_EVENTS.ownProfile)).toHaveLength(1);
  });

  it("closes both controls while a decision is in flight", async () => {
    const { channel } = await openProfile({ attested: [entryWire()], disclosures: [] });

    await decide("bartender at the anchor", AUDIENCE_VENUE_NAME, "Hide");

    const show = screen.getByRole("button", { name: /^show bartender/i });
    const hide = screen.getByRole("button", { name: /^hide bartender/i });

    expect(show).toBeDisabled();
    expect(hide).toBeDisabled();

    answer(channel, PROFILE_EVENTS.setDisclosure, "ok", disclosureWire());

    await waitFor(() => {
      expect(screen.getByRole("button", { name: /^hide bartender/i })).toBeEnabled();
    });
  });

  it("renders the refusal rather than the state it asked for", async () => {
    const { channel } = await openProfile({ attested: [entryWire()], disclosures: [] });

    await decide("bartender at the anchor", AUDIENCE_VENUE_NAME, "Hide");
    answer(channel, PROFILE_EVENTS.setDisclosure, "error", refusal("not_found"));

    expect(await screen.findByRole("alert")).toHaveTextContent(/not one of yours/i);
    // AE1 intact: the sentence must not distinguish "no such entry" from "one
    // that is somebody else's".
    expect(screen.getByRole("alert")).toHaveTextContent(/same answer/i);
    // And the server's own message is never rendered.
    expect(screen.queryByText(/SERVER-SIDE LOG SENTENCE/)).not.toBeInTheDocument();
    expect(screen.getByText(/you have not made a decision/i)).toBeInTheDocument();
  });
});

describe("the standing incompleteness notice", () => {
  it("is the join's string and not one a profile reply carries", async () => {
    // `incompleteness_notice/0` is arity zero so it cannot become an oracle
    // naming which workers conceal something. Taking it from the join is that
    // arity expressed on a transport: a join reply is about the session, and no
    // profile read can influence one. This answers `profile` with a *different*
    // notice and watches it be ignored.
    const { channel } = await openProfile();

    act(() => {
      channel.joinPush.trigger("ok", {
        person_id: PERSON_ID,
        incompleteness_notice: NOTICE,
      });
    });

    answer(channel, PROFILE_EVENTS.ownProfile, "ok", {
      ...profilePayload({ attested: [entryWire()] }),
      incompleteness_notice: "THIS WORKER IS HIDING SOMETHING",
    });

    expect(await screen.findByText(NOTICE)).toBeInTheDocument();
    expect(screen.queryByText(/HIDING SOMETHING/)).not.toBeInTheDocument();
  });

  it("is the same string beside a record with entries and one with none", async () => {
    // The oracle this forbids is a notice that varies with what it sits beside
    // — "this record may be incomplete" against a full record and something
    // else against an empty one is `hidden_count` spelled as prose.
    //
    // It used to be asserted on one screen, because a peer's record was shown
    // under the identical notice and the two could be compared in one DOM. #73
    // took that section off, so the comparison is made across two mounts of the
    // same surface with two different records, which is what the property
    // actually says. The full record is asserted full before anything is
    // compared: two empty records would satisfy the equality for the wrong
    // reason, which is this suite's own recurring shape.
    await openProfile({
      attested: [entryWire(), secondJobWire()],
      declared: [declaredWire()],
    });

    expect(await screen.findByText("Supervisor")).toBeInTheDocument();
    const beside = screen.getAllByRole("note").map((node) => node.textContent);
    expect(beside).toEqual([NOTICE]);

    cleanup();

    await openProfile({});

    expect(
      await screen.findByText(/no employer has confirmed a job for you yet/i),
    ).toBeInTheDocument();
    expect(screen.getAllByRole("note").map((node) => node.textContent)).toEqual(beside);
  });
});

/**
 * The section that read somebody else's record, inverted rather than deleted.
 *
 * Six tests here drove a text box for a peer's uuid and the `ProfileView` its
 * answer rendered. #73 took that section off the screen — the way in was a
 * paste box for the one thing a worker cannot look up — and the surface behind
 * it is untouched: `peer_profile` is still one of `ProfileChannel`'s seven
 * events and `loadPeerProfile` still serves it, which the last block in this
 * file drives directly. **That block is the control on this one.** Without it,
 * "the section is gone" and "the capability is gone" are the same green.
 *
 * The six are not simply deleted, for the reason #68's inversion gives: a
 * presence test removed leaves the markup one careless paste from coming back
 * with nothing to say so. What replaces them is one absence test whose
 * controls come first — the surface is proved up, populated, and queryable by
 * each of the shapes the absences use.
 *
 * **Two of the six could not be turned round and are recorded rather than
 * reworded.** "Renders no ledger, even while the viewer is holding one" and
 * "says nothing about how much was withheld" were about `ProfileView`'s own
 * DOM; with nothing rendering a peer's record they would compare an empty
 * region against an empty rule, which is the "both operands empty" shape this
 * project keeps finding. `profile-route.tsx`'s header carries the obligation
 * to re-assert them when a picker brings the section back.
 */
describe("somebody else's record", () => {
  /**
   * Every string that section put on screen, written out rather than matched
   * loosely.
   *
   * A regex over prose is where an absence assertion goes quietly vacuous — a
   * `/somebody else's record/i` written with a straight apostrophe never
   * matched the `&rsquo;` the heading rendered, and would have passed on the
   * day the heading was still there. These are compared as substrings of the
   * document's own text, and the control below proves that comparison finds
   * what *is* on the page.
   */
  const PEER_LOOKUP_COPY = [
    "Somebody else’s record",
    "You can read the record of anybody you have worked with recently",
    "Read their record",
  ] as const;

  it("is not on this screen, and the worker's own record is", async () => {
    const { channel } = await openProfile({
      attested: [entryWire()],
      declared: [declaredWire()],
      corrections: [correctionWire()],
      disclosures: [disclosureWire()],
    });

    // The controls, and they are mandatory: an absence assertion passes
    // against a page that rendered nothing at all. The surface is up, it is
    // populated from both reads, and each query shape used below is shown to
    // find something on this DOM before it is asked to find nothing.
    expect(await screen.findByText("Bartender")).toBeInTheDocument();
    expect(screen.getByText("Chef")).toBeInTheDocument();
    expect(screen.getByText(correctionWire().body)).toBeInTheDocument();
    expect(screen.getByText("Hidden")).toBeInTheDocument();

    const text = document.body.textContent;
    expect(text).toContain("Jobs an employer confirmed");
    expect(
      screen.getByRole("button", { name: /ask the anchor for a correction/i }),
    ).toBeInTheDocument();
    // #73's second half renamed this: it was `audience-id-…`, a text box for a
    // raw uuid, and is now `audience-…`, the picker that replaced it. Still
    // here as the control on the cut below — the surface's *other* control has
    // to be shown standing before the peer lookup is asserted gone.
    expect(
      document.getElementById(`audience-${entryWire().attested_entry_id}`),
    ).not.toBeNull();
    expect(pushesOf(channel, PROFILE_EVENTS.ownProfile)).toHaveLength(1);

    // And now the section, by each route it had onto the page. All three were
    // measured against a build with the component put back: each of the three
    // strings, the button and the id kill it on its own.
    //
    // **Two more were written here and removed for killing nothing.** A
    // `queryByRole("region", { name: /record of/i })` cannot fail, because that
    // region only ever appeared *after* a lookup nothing can now start; and
    // `pushesOf(channel, peerProfile)` being empty is already pinned by this
    // file's first test, which compares the whole push list against `READS`.
    for (const copy of PEER_LOOKUP_COPY) {
      expect(text).not.toContain(copy);
    }
    expect(
      screen.queryByRole("button", { name: /read their record/i }),
    ).not.toBeInTheDocument();
    expect(document.getElementById("peer-profile-id")).toBeNull();
  });

  it("leaves the disclosure control alone, and it is no longer a uuid box either", async () => {
    // **Re-pointed rather than deleted.** The two controls both asked for a
    // raw id, and the removed one was the other place on this surface with a
    // label beginning "Their id" — so a cut that reached one field too far
    // would have taken the audience box with it. That guard still matters; what
    // changed is what it guards, because #73's second half replaced the box
    // with a picker.
    //
    // So it asserts the same thing from both ends: exactly one audience
    // control, scoped to its entry — and **no field labelled "Their id" at
    // all**, which is now the tell that the old box came back rather than that
    // the wrong one survived.
    await openProfile({ attested: [entryWire()], disclosures: [] });

    const controls = await screen.findAllByLabelText(/^who this is about/i);

    expect(controls).toHaveLength(1);
    expect(controls[0]).toHaveAccessibleName(
      "Who this is about, for Bartender at The Anchor",
    );
    expect(screen.queryByLabelText(/^their id/i)).toBeNull();
  });
});

describe("a refused rejoin", () => {
  it("clears the record and the ledger when the session is gone", async () => {
    // Fourth shared-terminal finding this client has acted on. `phoenix`
    // re-joins on its own backoff, and a session revoked in between is refused
    // there — `RequireSession` would not have noticed, because `GET /api/me`
    // was answered minutes ago, so without this the record would sit on screen
    // under an alert saying the session was gone.
    const { channel } = await openProfile({
      attested: [entryWire()],
      declared: [declaredWire()],
      corrections: [correctionWire()],
      disclosures: [disclosureWire()],
    });

    expect(await screen.findByText("Bartender")).toBeInTheDocument();

    act(() => {
      channel.joinPush.trigger("error", refusal("unauthorized"));
    });

    await waitFor(() => {
      expect(screen.queryByText("Bartender")).not.toBeInTheDocument();
    });
    expect(screen.queryByText("Chef")).not.toBeInTheDocument();
    expect(screen.queryByText(correctionWire().body)).not.toBeInTheDocument();
    expect(
      screen.queryByRole("list", { name: /decisions about bartender/i }),
    ).not.toBeInTheDocument();
  });

  it("does not clear it for a refusal that says nothing about the session", async () => {
    // The control for the test above. Phoenix's own
    // `%{reason: "too many channels joined"}` says nothing about who is signed
    // in, and emptying somebody's record to report a transport limit would
    // throw away their own data over a detail of the connection.
    const { channel } = await openProfile({ attested: [entryWire()] });

    expect(await screen.findByText("Bartender")).toBeInTheDocument();

    act(() => {
      channel.joinPush.trigger("error", { reason: "too many channels joined" });
    });

    await waitFor(() => {
      expect(screen.getByRole("alert")).toBeInTheDocument();
    });
    expect(screen.getByText("Bartender")).toBeInTheDocument();
  });

  it("leaves the topic rather than retrying into a refusal loop", async () => {
    const { socket, channel } = await openProfile();

    act(() => {
      channel.joinPush.trigger("error", refusal("unauthorized"));
    });

    act(() => {
      socket.fireRejoinTimers(3);
    });

    expect(channel.joins).toBe(1);
    expect(channel.left).toBe(true);
  });
});

describe("the worker's own word", () => {
  it("writes a declared entry and re-reads the record", async () => {
    const { channel, server } = await openProfile();

    await userEvent.type(screen.getByLabelText("What you did"), "Chef");
    await userEvent.type(
      screen.getByLabelText("Where"),
      "A kitchen with no account here",
    );
    await userEvent.type(screen.getByLabelText("From"), "2024-01-01T00:00:00Z");
    await userEvent.type(screen.getByLabelText("Until"), "2025-01-01T00:00:00Z");
    await userEvent.click(screen.getByRole("button", { name: /write this down/i }));

    expect(pushesOf(channel, PROFILE_EVENTS.declareEntry)).toEqual([
      {
        event: PROFILE_EVENTS.declareEntry,
        payload: {
          role_label: "Chef",
          organisation_name: "A kitchen with no account here",
          starts_at: "2024-01-01T00:00:00Z",
          ends_at: "2025-01-01T00:00:00Z",
        },
      },
    ]);

    answer(channel, PROFILE_EVENTS.declareEntry, "ok", declaredWire());

    // The record and not the ledger: a declared entry carries no disclosure
    // decisions at all, because writing one is publishing it.
    await server.answerReads([PROFILE_EVENTS.ownProfile], {
      declared: [declaredWire()],
    });

    expect(await screen.findByText("Chef")).toBeInTheDocument();
  });

  it("gives two entries that read the same their own fields", async () => {
    // A worker can hold the same role at the same place twice, which is two
    // entries with one heading — and the heading was where the form's field ids
    // came from, so both forms rendered `id="Change Chef at …-role"`. A
    // `<label for>` resolves through `getElementById`, which answers the first,
    // so the second form's four fields had no label at all: clicking its "What
    // you did" put the cursor in the *first* form's input and a screen reader
    // announced the first form's names for the second form's fields.
    //
    // The assertion is that property rather than the ids: each form's label
    // resolves to that form's own input, which is what `for` is for and what
    // the duplicate took away. The two terms differ so that "its own" is
    // checkable — with one id shared, both labels resolve to the first form's
    // field and the second row's term is nowhere on screen.
    const secondStint = declaredWire({
      declared_entry_id: "44444444-5555-4444-8444-444444444444",
      starts_at: "2022-01-01T00:00:00Z",
      ends_at: "2023-01-01T00:00:00Z",
    });

    await openProfile({ declared: [declaredWire(), secondStint] });

    const list = await screen.findByRole("list", {
      name: /jobs you have written down yourself/i,
    });
    const rows = rowsOf(list).map((row) => row as HTMLElement);
    expect(rows).toHaveLength(2);

    for (const row of rows) {
      await userEvent.click(
        within(row).getByRole("button", { name: /^change chef at/i }),
      );
    }

    const fields = rows.map((row) => within(row).getByLabelText("From"));

    expect(fields.map((field) => (field as HTMLInputElement).value)).toEqual([
      declaredWire().starts_at,
      secondStint.starts_at,
    ]);
    // And the mechanism, named: two forms, two sets of ids.
    expect(new Set(fields.map((field) => field.id)).size).toBe(2);
  });

  it("shows the server's per-field messages for a refused write", async () => {
    const { channel } = await openProfile();

    await userEvent.type(screen.getByLabelText("What you did"), "Chef");
    await userEvent.type(screen.getByLabelText("Where"), "A kitchen");
    await userEvent.type(screen.getByLabelText("From"), "2025-01-01T00:00:00Z");
    await userEvent.type(screen.getByLabelText("Until"), "2024-01-01T00:00:00Z");
    await userEvent.click(screen.getByRole("button", { name: /write this down/i }));

    answer(channel, PROFILE_EVENTS.declareEntry, "error", {
      error: {
        code: "unprocessable_entity",
        message: "SERVER-SIDE LOG SENTENCE",
        fields: { ends_at: ["must be after the start"] },
      },
    });

    // `fields` is the one exception to "the server's message is never
    // rendered": these name an input the worker filled in.
    expect(await screen.findByText(/must be after the start/i)).toBeInTheDocument();
    expect(screen.queryByText(/SERVER-SIDE LOG SENTENCE/)).not.toBeInTheDocument();
  });

  it("offers a correction against an attested entry and no way to edit one", async () => {
    // R16: a person cannot edit an employer's assertion and `Profiles` exports
    // no function that would. The remedy is the request.
    const { channel, server } = await openProfile({ attested: [entryWire()] });

    const entries = await screen.findByRole("list", {
      name: /jobs an employer confirmed/i,
    });
    expect(
      within(entries).queryByRole("button", { name: /^change /i }),
    ).not.toBeInTheDocument();

    await userEvent.type(
      screen.getByLabelText(/what is wrong with it/i),
      "I worked until June, not April.",
    );
    await userEvent.click(
      screen.getByRole("button", { name: /ask the anchor for a correction/i }),
    );

    expect(pushesOf(channel, PROFILE_EVENTS.requestCorrection)).toEqual([
      {
        event: PROFILE_EVENTS.requestCorrection,
        payload: {
          engagement_id: ENGAGEMENT_ID,
          body: "I worked until June, not April.",
        },
      },
    ]);

    answer(channel, PROFILE_EVENTS.requestCorrection, "ok", correctionWire());
    await server.answerReads([PROFILE_EVENTS.ownProfile], {
      attested: [entryWire()],
      corrections: [correctionWire()],
    });

    expect(await screen.findByText(/waiting for an answer/i)).toBeInTheDocument();
  });

  it("says an accepted correction changed no entry", async () => {
    await openProfile({
      attested: [entryWire()],
      corrections: [
        correctionWire({ resolved_at: "2026-07-05T00:00:00Z", resolution: "accepted" }),
      ],
    });

    expect(await screen.findByText("Accepted")).toBeInTheDocument();
    expect(
      screen.getByText(/that is an acknowledgement and not an edit/i),
    ).toBeInTheDocument();
  });
});

/**
 * The hook on its own, joined, with the channel to answer it on.
 *
 * At module scope because two blocks need it: the three writes, whose replies
 * are rendered nowhere, and `peer_profile`, which since #73 is *asked* nowhere.
 */
async function openSurface() {
  const { socket, createSocket } = fakeSocketFactory();
  const api = createFakeApi({
    currentPerson: () =>
      Promise.resolve(
        ok({ id: PERSON_ID, email: "worker@example.com", displayName: "Captain Nemo" }),
      ),
  });

  const { result } = renderHook(() => useProfileSurface(PERSON_ID), {
    wrapper: ({ children }: { readonly children: ReactNode }) => (
      <SessionProvider api={api} tokenStore={createMemoryTokenStore("c2Vzc2lvbg")}>
        <SocketProvider createSocket={createSocket}>{children}</SocketProvider>
      </SessionProvider>
    ),
  });

  const topic = profileTopic(PERSON_ID);
  const channel = await waitFor(() => {
    const opened = socket.channelFor(topic);
    if (opened === undefined) throw new Error(`nothing joined ${topic}`);

    return opened;
  });

  act(() => {
    channel.joinPush.trigger("ok", {
      person_id: PERSON_ID,
      incompleteness_notice: NOTICE,
    });
  });

  return { channel, surface: result };
}

/** Starts an action inside `act`, and hands back the promise to await. */
function start<Value>(work: () => Promise<Value>): Promise<Value> {
  let started: Promise<Value> | undefined;

  act(() => {
    started = work();
  });

  if (started === undefined) throw new Error("nothing was started");

  return started;
}

describe("what a write comes back with", () => {
  const DRAFT = {
    roleLabel: "Chef",
    organisationName: "A kitchen with no account here",
    startsAt: "2024-01-01T00:00:00Z",
    endsAt: "2025-01-01T00:00:00Z",
  };

  it("hands back the entity, decoded, for each of the three writes", async () => {
    // All three passed `() => null` as their decoder while being typed
    // `ProfileOutcome<Profile>` — a shape none of the three replies has, over a
    // value that was always absent, under a comment saying the reply was
    // decoded. `contract.ts` names exactly what each one answers, and this is
    // the only place on this side that can tell whether a transport met it.
    const { channel, surface } = await openSurface();

    const declared = start(() => surface.current.declareEntry(DRAFT));
    answer(channel, PROFILE_EVENTS.declareEntry, "ok", declaredWire());

    const entry = {
      declaredEntryId: declaredWire().declared_entry_id,
      roleLabel: "Chef",
      organisationName: "A kitchen with no account here",
      startsAt: "2024-01-01T00:00:00Z",
      endsAt: "2025-01-01T00:00:00Z",
      declaredAt: "2026-07-01T00:00:00Z",
    };

    await expect(declared).resolves.toEqual({ status: "ok", value: entry });

    const amended = start(() =>
      surface.current.amendDeclaredEntry(declaredWire().declared_entry_id, DRAFT),
    );
    answer(channel, PROFILE_EVENTS.amendDeclaredEntry, "ok", declaredWire());

    await expect(amended).resolves.toEqual({ status: "ok", value: entry });

    // `VisibleCorrection`, decoded by the decoder the four *reads* use — which
    // is `contract.ts`'s ask here, so that the write path and the reads are one
    // shape rather than five minus one.
    const contested = start(() =>
      surface.current.requestCorrection(ENGAGEMENT_ID, correctionWire().body),
    );
    answer(channel, PROFILE_EVENTS.requestCorrection, "ok", correctionWire());

    await expect(contested).resolves.toEqual({
      status: "ok",
      value: {
        correctionRequestId: correctionWire().correction_request_id,
        entryEngagementId: ENGAGEMENT_ID,
        venueId: correctionWire().venue_id,
        body: correctionWire().body,
        requestedAt: "2026-07-02T00:00:00Z",
        resolvedAt: null,
        resolution: null,
      },
    });
  });

  it("hands back a named absence when the reply names the entry `id`", async () => {
    // The control for the test above, and the drift `contract.ts` argues
    // against by name: `DeclaredEntry` is an Ecto schema with no render struct,
    // so a channel putting it on the wire wholesale sends `id` beside the
    // `attested_entry_id` and `correction_request_id` the other shapes use.
    // `decodeDeclaredEntry` refuses that spelling rather than accepting either.
    //
    // The write is still reported as accepted, which is `ProfileOutcome`'s rule
    // rather than an oversight: the server took it, and a reply this client
    // cannot read does not un-accept it. What the worker sees is the re-read,
    // which decodes the same field through the same decoder and does raise a
    // notice when it cannot.
    const { channel, surface } = await openSurface();

    const declared = start(() => surface.current.declareEntry(DRAFT));

    answer(channel, PROFILE_EVENTS.declareEntry, "ok", {
      id: declaredWire().declared_entry_id,
      role_label: "Chef",
      organisation_name: "A kitchen with no account here",
      starts_at: "2024-01-01T00:00:00Z",
      ends_at: "2025-01-01T00:00:00Z",
      declared_at: "2026-07-01T00:00:00Z",
    });

    await expect(declared).resolves.toEqual({ status: "ok", value: null });
  });
});

/**
 * The read no screen asks for, and the reason it is asserted here.
 *
 * #73 took the peer-lookup section off the profile surface. Nothing else calls
 * `loadPeerProfile`, so without this block the capability would be uncovered
 * from the moment that section went — and "hidden" and "deleted" would be
 * indistinguishable to anybody reading the suite. It is asked, refused and
 * decoded here exactly as the removed component asked it, so the day a picker
 * puts it back on screen the contract it has to meet is already written down.
 *
 * The three cases are the three the component drove: an answer, a refusal, and
 * an id this client will not send. The last one is the only one that reaches no
 * transport, and it is the one a picker makes unreachable — which is worth
 * knowing before it is deleted as dead.
 */
describe("the peer read the surface still serves", () => {
  it("asks `peer_profile` by person and decodes the three lists", async () => {
    const { channel, surface } = await openSurface();

    const read = start(() => surface.current.loadPeerProfile(PEER_ID));

    // Named on the wire before it is answered: the event and the payload are
    // `contract.ts`'s, and a picker replacing the text box must send the same.
    expect(pushesOf(channel, PROFILE_EVENTS.peerProfile)).toEqual([
      { event: PROFILE_EVENTS.peerProfile, payload: { person_id: PEER_ID } },
    ]);

    answer(
      channel,
      PROFILE_EVENTS.peerProfile,
      "ok",
      profilePayload({
        attested: [entryWire()],
        declared: [declaredWire()],
        corrections: [correctionWire()],
      }),
    );

    await expect(read).resolves.toEqual({
      status: "ok",
      value: {
        attestedEntries: [
          {
            attestedEntryId: entryWire().attested_entry_id,
            entryEngagementId: ENGAGEMENT_ID,
            venueId: entryWire().venue_id,
            venueName: "The Anchor",
            roleLabel: "Bartender",
            startsAt: "2026-01-01T00:00:00Z",
            endsAt: "2026-06-01T00:00:00Z",
            attestedAt: "2026-01-01T00:00:00Z",
          },
        ],
        declaredEntries: [
          {
            declaredEntryId: declaredWire().declared_entry_id,
            roleLabel: "Chef",
            organisationName: "A kitchen with no account here",
            startsAt: "2024-01-01T00:00:00Z",
            endsAt: "2025-01-01T00:00:00Z",
            declaredAt: "2026-07-01T00:00:00Z",
          },
        ],
        correctionRequests: [
          {
            correctionRequestId: correctionWire().correction_request_id,
            entryEngagementId: ENGAGEMENT_ID,
            venueId: correctionWire().venue_id,
            body: correctionWire().body,
            requestedAt: "2026-07-02T00:00:00Z",
            resolvedAt: null,
            resolution: null,
          },
        ],
      },
    });
  });

  it("hands back the refusal rather than an empty record", async () => {
    // AE1 is the server's: an id that names nobody, a person this viewer may
    // not read, and one that is not an id all come back `not_found`. What this
    // side must not do is turn that into an empty profile, which reads as
    // "they have never worked anywhere" rather than "you cannot see this".
    const { channel, surface } = await openSurface();

    const read = start(() => surface.current.loadPeerProfile(PEER_ID));
    answer(channel, PROFILE_EVENTS.peerProfile, "error", refusal("not_found"));

    await expect(read).resolves.toEqual({
      status: "refused",
      failure: {
        kind: "channel_error",
        code: "not_found",
        rawCode: "not_found",
        message: "SERVER-SIDE LOG SENTENCE",
      },
    });
  });

  it("refuses an id that is not one without sending anything", async () => {
    const { channel, surface } = await openSurface();

    const read = start(() => surface.current.loadPeerProfile("not-an-id"));

    await expect(read).resolves.toMatchObject({
      status: "refused",
      failure: { code: "bad_request" },
    });
    expect(pushesOf(channel, PROFILE_EVENTS.peerProfile)).toHaveLength(0);
  });
});
