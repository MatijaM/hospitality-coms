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
 * Three of the properties below are U9's rules holding at the render layer,
 * which is the one place the database and the context cannot reach:
 *
 *   * a viewer of somebody else's record cannot tell a worker concealing three
 *     jobs from one who has only ever had the one;
 *   * the standing notice is one string per session, off the join, and no
 *     profile reply can influence it;
 *   * an audience the worker has not decided about renders as undecided and
 *     never as visible.
 *
 * The rest are this client's own conventions: the shared-terminal clear, the
 * in-flight guards, and which reads an action is allowed to issue.
 */

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
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

const PERSON_ID = "a1a1a1a1-b2b2-4c3c-8d4d-e5e5e5e5e5e5";
const PEER_ID = "c3c3c3c3-d4d4-4e5e-8f6f-a7a7a7a7a7a7";
const ENGAGEMENT_ID = "22222222-2222-4222-8222-222222222222";
const OTHER_ENGAGEMENT_ID = "99999999-9999-4999-8999-999999999999";
const AUDIENCE_VENUE_ID = "77777777-7777-4777-8777-777777777777";

/** `Profiles.incompleteness_notice/0`, verbatim. */
const NOTICE =
  "This record may be incomplete. A worker chooses which of their entries each employer and each peer can see.";

const READS = [PROFILE_EVENTS.ownProfile, PROFILE_EVENTS.listDisclosures] as const;

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
};

function profilePayload(record: Record_) {
  return {
    attested_entries: record.attested ?? [],
    declared_entries: record.declared ?? [],
    correction_requests: record.corrections ?? [],
  };
}

function renderProfile(personId: string) {
  const { socket, createSocket } = fakeSocketFactory();
  const api = createFakeApi({
    currentPerson: () =>
      Promise.resolve(ok({ id: personId, email: "worker@example.com" })),
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
  let cursor = 0;
  const reads: readonly string[] = READS;

  function pending(): string[] {
    return channel.sent
      .slice(cursor)
      .map((sent) => sent.event)
      .filter((event) => reads.includes(event));
  }

  async function answerReads(
    expected: readonly string[],
    record: Record_,
  ): Promise<void> {
    await waitFor(() => {
      expect(pending()).toEqual([...expected]);
    });

    // And nothing more arrives a turn later. Without this, an over-fetch issued
    // in a microtask behind these would be missed by the assertion above.
    await settle();
    expect(pending()).toEqual([...expected]);

    act(() => {
      for (; cursor < channel.sent.length; cursor += 1) {
        const sent = channel.sent[cursor];
        if (sent === undefined || !reads.includes(sent.event)) continue;

        sent.push.trigger(
          "ok",
          sent.event === PROFILE_EVENTS.ownProfile
            ? profilePayload(record)
            : { disclosures: record.disclosures ?? [] },
        );
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

async function openProfile(record: Record_ = {}, personId: string = PERSON_ID) {
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
  await server.answerReads(READS, record);

  return { socket, channel, server };
}

/**
 * Types an audience into one entry's control and presses Show or Hide.
 *
 * `entry` names the entry in both the field's label and the button's, which is
 * what stops this helper reaching for whichever control happens to be first
 * when a fixture carries two.
 */
async function decide(
  entry: string,
  audienceId: string,
  which: "Show" | "Hide",
): Promise<void> {
  const control = await screen.findByLabelText(
    new RegExp(`^their id, for ${entry}$`, "i"),
  );

  await userEvent.clear(control);
  await userEvent.type(control, audienceId);
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
    // being typed, and this is the branch where the third value is the whole
    // point: the worker is about to decide about somebody the ledger says
    // nothing about, and "Shown" there would be a claim this client cannot
    // make and which the employer default usually contradicts.
    await openProfile({
      attested: [entryWire()],
      disclosures: [disclosureWire({ audience_id: AUDIENCE_VENUE_ID })],
    });

    const control = await screen.findByLabelText(
      /^their id, for bartender at the anchor$/i,
    );

    await userEvent.type(control, "88888888-8888-4888-8888-888888888888");
    expect(await screen.findByText("Not decided")).toBeInTheDocument();

    await userEvent.clear(control);
    await userEvent.type(control, AUDIENCE_VENUE_ID);

    // The same field, a different audience, and now there *is* a row.
    await waitFor(() => {
      expect(screen.queryByText("Not decided")).not.toBeInTheDocument();
    });
    expect(screen.getByText(/right now, for them/i)).toBeInTheDocument();
  });
});

describe("changing a disclosure setting confirms the new state", () => {
  it("sends the tagged audience and renders what comes back", async () => {
    const { channel, server } = await openProfile({
      attested: [entryWire()],
      disclosures: [],
    });

    expect(await screen.findByText(/you have not made a decision/i)).toBeInTheDocument();

    await decide("bartender at the anchor", AUDIENCE_VENUE_ID, "Hide");

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

    await decide("bartender at the anchor", AUDIENCE_VENUE_ID, "Show");
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

    await decide("bartender at the anchor", AUDIENCE_VENUE_ID, "Hide");

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

    await decide("bartender at the anchor", AUDIENCE_VENUE_ID, "Hide");
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

  it("is the same string beside a full record and an empty one", async () => {
    // A worker with two jobs is looking at somebody whose record comes back
    // empty. Both notices must be the identical string: a viewer who could read
    // "how much is missing" off *which* notice they were shown would have the
    // oracle back, and it would be this client that handed it to them.
    const { channel } = await openProfile({
      attested: [entryWire(), secondJobWire()],
      declared: [declaredWire()],
    });

    expect(await screen.findByText("Supervisor")).toBeInTheDocument();
    expect(screen.getAllByRole("note").map((node) => node.textContent)).toEqual([NOTICE]);

    await userEvent.type(screen.getByLabelText("Their id"), PEER_ID);
    await userEvent.click(screen.getByRole("button", { name: /read their record/i }));
    answer(channel, PROFILE_EVENTS.peerProfile, "ok", profilePayload({}));

    await screen.findByRole("region", { name: /record of c3c3c3c3/i });

    const notices = screen.getAllByRole("note").map((node) => node.textContent);
    expect(notices).toHaveLength(2);
    expect(new Set(notices).size).toBe(1);
    expect(notices[0]).toBe(NOTICE);
  });
});

describe("somebody else's record", () => {
  async function openPeerRecord(record: Record_) {
    const opened = await openProfile();

    await userEvent.type(screen.getByLabelText("Their id"), PEER_ID);
    await userEvent.click(screen.getByRole("button", { name: /read their record/i }));

    answer(opened.channel, PROFILE_EVENTS.peerProfile, "ok", profilePayload(record));

    return opened;
  }

  it("asks for it by person and renders the three lists", async () => {
    const { channel } = await openPeerRecord({
      attested: [entryWire()],
      declared: [declaredWire()],
      corrections: [correctionWire()],
    });

    expect(pushesOf(channel, PROFILE_EVENTS.peerProfile)).toEqual([
      { event: PROFILE_EVENTS.peerProfile, payload: { person_id: PEER_ID } },
    ]);

    const record = await screen.findByRole("region", { name: /record of c3c3c3c3/i });
    expect(within(record).getByText("Bartender")).toBeInTheDocument();
    expect(within(record).getByText("Chef")).toBeInTheDocument();
    expect(within(record).getByText(correctionWire().body)).toBeInTheDocument();
  });

  it("renders no ledger, even while the viewer is holding one", async () => {
    // This is the render-layer half of the rule `incompleteness_notice/0`'s
    // arity and the views' pinned column lists hold on the other side.
    //
    // The fixture is the point. The viewer *is* holding a ledger — their own,
    // loaded for their own record — and it carries a decision keyed on the
    // engagement the peer's visible entry names, so a `ProfileView` that
    // reached for `surface.disclosures` would have something real to render
    // rather than an empty list that renders as nothing either way. A fixture
    // that is empty exactly where the property lives cannot fail, which is the
    // lesson `peers.test.tsx` records in its own header.
    //
    // `ProfileView`'s props carry no ledger and cannot be handed one; that is
    // the structural half, and this is the observable one.
    const { channel } = await openProfile({
      attested: [entryWire()],
      disclosures: [disclosureWire()],
    });

    expect(await screen.findByText("Hidden")).toBeInTheDocument();

    await userEvent.type(screen.getByLabelText("Their id"), PEER_ID);
    await userEvent.click(screen.getByRole("button", { name: /read their record/i }));
    answer(
      channel,
      PROFILE_EVENTS.peerProfile,
      "ok",
      profilePayload({
        attested: [entryWire()],
      }),
    );

    const region = await screen.findByRole("region", { name: /record of c3c3c3c3/i });

    // `Shown`, `Hidden` and `Not decided` are the disclosure vocabulary and
    // none of it belongs to a viewer — nor do the controls that write it.
    expect(within(region).queryByText("Hidden")).not.toBeInTheDocument();
    expect(within(region).queryByText("Shown")).not.toBeInTheDocument();
    expect(within(region).queryByText("Not decided")).not.toBeInTheDocument();
    expect(
      within(region).queryByRole("button", { name: /^hide |^show /i }),
    ).not.toBeInTheDocument();
    expect(
      within(region).queryByText(/you have not made a decision/i),
    ).not.toBeInTheDocument();
  });

  it("says nothing about how much was withheld", async () => {
    await openPeerRecord({ attested: [entryWire()] });

    const region = await screen.findByRole("region", { name: /record of c3c3c3c3/i });

    // No count, no total, no ordinal, and no word that could only come from
    // knowing what was left out. A surface that rendered "1 of 3" here would
    // defeat the unit at the render layer with the database and the context
    // both still correct.
    expect(region.textContent).not.toMatch(/hidden|concealed|of \d|\d+ entr/i);
  });

  it("renders one AE1 sentence for a refusal and shows no record", async () => {
    const { channel } = await openProfile();

    await userEvent.type(screen.getByLabelText("Their id"), PEER_ID);
    await userEvent.click(screen.getByRole("button", { name: /read their record/i }));

    answer(channel, PROFILE_EVENTS.peerProfile, "error", refusal("not_found"));

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveTextContent(/no record here for you to read/i);
    expect(alert).toHaveTextContent(
      /same answer you would get for a person who does not exist/i,
    );
    expect(screen.queryByRole("region", { name: /record of/i })).not.toBeInTheDocument();
  });

  it("takes a record off the screen when a later read of it is refused", async () => {
    // The test above asserts no record is shown after a refusal, and on its own
    // that is worth very little: no record had ever been shown, so "cleared"
    // and "never set" are the same DOM. Measured — a mutation that dropped the
    // clear entirely survived it.
    //
    // This is the case the clear exists for. `fetch_peer_profile/2`'s gate is
    // derived at the instant of the event and visibility lapses thirty days
    // after the first of the two engagements ends (R13), so the second read of
    // a record that was readable a moment ago is genuinely refused — and a
    // record left on screen then is one the server has just declined to send.
    const { channel } = await openPeerRecord({ attested: [entryWire()] });

    const region = await screen.findByRole("region", { name: /record of c3c3c3c3/i });
    expect(within(region).getByText("Bartender")).toBeInTheDocument();

    // The same person again, which is what the attempt counter is for: without
    // it the second press sets identical state and the effect never re-runs.
    await userEvent.click(screen.getByRole("button", { name: /read their record/i }));
    answer(channel, PROFILE_EVENTS.peerProfile, "error", refusal("not_found"));

    await waitFor(() => {
      expect(
        screen.queryByRole("region", { name: /record of/i }),
      ).not.toBeInTheDocument();
    });
    expect(pushesOf(channel, PROFILE_EVENTS.peerProfile)).toHaveLength(2);
  });

  it("refuses an id that is not one without sending anything", async () => {
    const { channel } = await openProfile();

    await userEvent.type(screen.getByLabelText("Their id"), "not-an-id");
    await userEvent.click(screen.getByRole("button", { name: /read their record/i }));

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent(
        /could not be sent as written/i,
      );
    });
    expect(pushesOf(channel, PROFILE_EVENTS.peerProfile)).toHaveLength(0);
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
