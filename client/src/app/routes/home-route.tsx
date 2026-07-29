/**
 * Where a signed-in worker lands, and the only screen that carries more than
 * one surface.
 *
 * It was a page of links to three routes, which meant the first thing anybody
 * saw after signing in was a table of contents. The three surfaces are the
 * product; this puts them behind tabs on the page the session opens on, and
 * changes nothing about the surfaces themselves.
 *
 * ## The routes are still there, and that is the point
 *
 * `/rooms`, `/peers` and `/profile` are unchanged. The tabs are a second door
 * rather than a replacement, which is what keeps every test above those three
 * surfaces — all of which enter through their own path — untouched by this
 * file. It also means a link somebody has kept still works.
 *
 * The open tab is deliberately **not** in the URL. Each surface already has a
 * URL, and a second spelling of "the peer surface" is a second thing that has
 * to stay true; `?tab=peers` and `/peers` disagreeing about which is canonical
 * is a bug nobody would find quickly.
 *
 * ## Only the open tab is mounted, and that is a constraint rather than a saving
 *
 * `usePeerSurface` is one hook because there is one topic: KTD10 puts the
 * conversation in every payload and never in the topic, so a second instance
 * joins `peer:<person_id>` a second time and every announcement — every
 * message — arrives twice. Panels kept in the tree and hidden with CSS would
 * put that second instance there the moment a worker looked at Rooms. One
 * mounted panel means one instance and the problem never arises.
 *
 * **So switching tabs unmounts the panel that was showing.** An open room
 * leaves its channel, the peer channel is left and rejoined, and any typing in
 * progress goes. That is exactly what navigating from `/rooms` to `/peers`
 * already did, so nothing is worse than it was — but a tab strip reads like
 * Slack's, where the conversation is still there when you come back, and this
 * one is not. Do not add persistence here by rendering all three and hiding
 * two; the paragraph above is why.
 *
 * ## The identity block is above the tabs
 *
 * Who you are and how to stop being them are not one surface among three, and
 * a log-out control that moved with the tab would be a log-out control a worker
 * has to hunt for.
 *
 * It is `SessionBar` now rather than inline markup, because U4 added two full
 * pages of their own and a shared terminal needs the log-out on every screen a
 * session rests on. Same sentence, same button label, moved verbatim.
 *
 * ## The two employer doors are links and not tabs
 *
 * `/employer` and `/claim` are used by two people in two windows at once, so
 * neither is "another surface of mine" the way the three tabs are — and the
 * tab strip is a keyboard widget whose wrapping is asserted over exactly three
 * entries. They sit under their own heading with a sentence saying which
 * person each is for, which is also the only place this client says out loud
 * that managing a venue and working at one are the same account.
 *
 * It lost its `<h1>Signed in</h1>` in the move. Each of the three surfaces
 * brings its own — "Rooms", "Peers", "Your record" — so keeping one here made
 * two on the page, and the one that would have won the reader's attention was
 * a greeting rather than the name of what they were looking at.
 *
 * ## Say what is missing, not which unit owes it
 *
 * The notes under the panel previously read "waiting on U9", "waiting on U10",
 * "waiting on U11". All three shipped, and the list still said so — it was
 * written when they were future work and nothing brought it back. Worse, the
 * vocabulary was the plan's: a worker reading "waiting on U9" learns nothing,
 * and a developer reading it after U9 merged learns something false.
 *
 * So each entry now names the thing that is actually absent. Those are
 * checkable claims, and one of them is checked: the Profile tab cannot connect
 * because `PersonSocket` routes no `profile:*` topic, and `sockets_test.exs`
 * pins that socket's routing table exactly, with a control. Adding the channel
 * fails that test, which is where somebody will be standing when this
 * paragraph needs deleting.
 *
 * The profile is stated separately from the two absences below it, and the
 * split is the claim rather than layout: that surface **is** reachable — it is
 * a tab, it mounts, it renders — and only its wire is missing. Erasure and the
 * demo controls have no way in from a browser at all. Folding the three into
 * one list is what made the old one say three false things at once.
 */

import type { KeyboardEvent } from "react";
import { useId, useRef, useState } from "react";
import { Link } from "react-router";

import { PeersRoute } from "../../features/peers/peers-route";
import { ProfileRoute } from "../../features/profile/profile-route";
import type { RoomStore } from "../../features/rooms/room-store";
import { RoomsRoute } from "../../features/rooms/rooms-route";
import { useSession } from "../../session/session-context";
import { SessionBar } from "../session-bar";

const TABS = [
  { id: "rooms", label: "Rooms" },
  { id: "peers", label: "Peers" },
  { id: "profile", label: "Profile" },
] as const;

type TabId = (typeof TABS)[number]["id"];

export type HomeRouteProps = {
  readonly roomStore: RoomStore;
};

export function HomeRoute({ roomStore }: HomeRouteProps) {
  const { state } = useSession();
  const [open, setOpen] = useState<TabId>("rooms");

  // Unique per rendered strip, because two landing pages in one document would
  // otherwise share `aria-controls` targets — `DeclaredEntryForm`'s hazard,
  // which was a real defect there rather than a hypothetical one.
  const ids = useId();

  // Only for moving focus with the arrow keys. A roving `tabIndex` takes the
  // other two tabs out of the tab order, so after an arrow key the browser has
  // nowhere to put focus on its own.
  const buttons = useRef(new Map<TabId, HTMLButtonElement>());

  // `RequireSession` renders this only when the session is authenticated. The
  // early return is what narrows the union; it is not a state that happens.
  if (state.status !== "authenticated") return null;

  function tabId(id: TabId): string {
    return `${ids}-tab-${id}`;
  }

  function panelId(id: TabId): string {
    return `${ids}-panel-${id}`;
  }

  function show(id: TabId): void {
    setOpen(id);
    buttons.current.get(id)?.focus();
  }

  /**
   * Arrow keys move between the tabs, wrapping at both ends; Home and End go
   * to the first and last.
   *
   * Selection follows focus, which is the pattern's automatic-activation form
   * and the right one here: the three panels are already on this device and
   * nothing is fetched by arriving at one, so there is no cost to landing on a
   * tab you were only passing through.
   */
  function onKeyDown(event: KeyboardEvent<HTMLButtonElement>): void {
    const here = TABS.findIndex((tab) => tab.id === open);
    const there = neighbour(event.key, here);

    if (there === null) return;

    // Otherwise Home and End scroll the page out from under the strip.
    event.preventDefault();
    show(there);
  }

  return (
    <section>
      <SessionBar />

      <div role="tablist" aria-label="Your surfaces">
        {TABS.map((tab) => (
          <button
            key={tab.id}
            type="button"
            role="tab"
            id={tabId(tab.id)}
            ref={(node) => {
              if (node === null) buttons.current.delete(tab.id);
              else buttons.current.set(tab.id, node);
            }}
            aria-selected={tab.id === open}
            /*
              Named only on the selected tab, because the other two panels are
              not in the document — see this file's header — and an
              `aria-controls` pointing at an id nothing has is worse than none
              at all: a screen reader offers a jump that goes nowhere.
            */
            aria-controls={tab.id === open ? panelId(tab.id) : undefined}
            tabIndex={tab.id === open ? 0 : -1}
            onKeyDown={onKeyDown}
            onClick={() => {
              show(tab.id);
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>

      <div role="tabpanel" id={panelId(open)} aria-labelledby={tabId(open)}>
        <Surface open={open} roomStore={roomStore} />
      </div>

      {/*
        Below the panel rather than above it: these are notes about the product,
        and a worker who came here to read a room should not have to scroll past
        them to reach one.
      */}
      <h2>Venues</h2>
      <p>
        The same account does both of these. There is no separate employer log-in and no
        employer password — an authority is something a venue grants to a person, and it
        is checked against the database on every single request.
      </p>
      <ul>
        <li>
          <Link to="/employer">Venues you manage</Link> — who is engaged at one of them
          right now, and the offer that brings somebody new onto it. Empty, with a
          sentence, if nobody has granted you an authority anywhere.
        </li>
        <li>
          <Link to="/claim">Claim a job</Link> — paste a code a manager handed you and see
          the engagement it produced.
        </li>
      </ul>

      <h2>Profile</h2>
      <p>
        <strong>That tab cannot connect yet.</strong> The record itself is built —
        attested entries, declared entries, corrections, and the per-venue and per-person
        disclosure rules — but no channel carries any of it to this browser, so the tab
        renders against the shapes in <code>features/profile/contract.ts</code> and waits
        for a reply that does not come. It is a tab rather than one of the absences below
        because the thing it names exists; what is missing is the wire to it.
      </p>

      <h2>Not reachable from here yet</h2>
      <p>
        Both of these exist in the backend and neither has a way in from a browser.
        Nothing is stubbed, because a placeholder for a shape nobody has chosen costs more
        to remove than to write.
      </p>
      <ul>
        <li>
          <strong>Erasure and retention.</strong> Erasing an account, and the deadlines
          that delete old messages, run on the server. There is no endpoint and no
          channel, so no screen can ask for them.
        </li>
        <li>
          <strong>The demo controls.</strong> Seeding, moving the clock and running due
          work are HTTP endpoints under <code>/api/demo</code>, in development builds
          only, and they need an <code>x-demo-control</code> header. There is no UI for
          them.
        </li>
      </ul>
    </section>
  );
}

/**
 * The three surfaces, rendered exactly as their own routes render them.
 *
 * An exhaustive switch rather than three `&&`s, so that a fourth tab is a
 * compile error here rather than a blank panel at runtime.
 */
function Surface({
  open,
  roomStore,
}: {
  readonly open: TabId;
  readonly roomStore: RoomStore;
}) {
  switch (open) {
    case "rooms":
      return <RoomsRoute store={roomStore} />;
    case "peers":
      return <PeersRoute />;
    case "profile":
      return <ProfileRoute />;
  }
}

/** The tab an arrow, Home or End key asks for, or `null` for any other key. */
function neighbour(key: string, here: number): TabId | null {
  switch (key) {
    case "ArrowRight":
      return TABS[(here + 1) % TABS.length]?.id ?? null;
    case "ArrowLeft":
      return TABS[(here + TABS.length - 1) % TABS.length]?.id ?? null;
    case "Home":
      return TABS[0].id;
    case "End":
      return TABS[TABS.length - 1]?.id ?? null;
    default:
      return null;
  }
}
