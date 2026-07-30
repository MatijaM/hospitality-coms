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
 * one is not. Do not add persistence here by rendering all four and hiding
 * three; the paragraph above is why.
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
 * ## Venues is the fourth tab, and it is not like the other three
 *
 * `/rooms`, `/peers` and `/profile` are each a real route that this page mounts
 * a *second* door to. **Venues mounts no surface and has no route of its own**
 * — there is no `/venues`, so do not go looking for one. Its panel is two
 * links, and the pages behind them stay full screens rather than becoming
 * panels: `/employer` and `/claim` are used by two people in two windows at
 * once, which is why they were never candidates to be tabs themselves.
 *
 * What changed is where those two links live. They sat under their own heading
 * *below* the panel, which put the thing a manager comes here for underneath
 * whichever surface happened to be open, and left the tab strip claiming to be
 * the page's navigation while the most consequential control on it was not a
 * tab. As a tab it is one press from anywhere on the page, and reachable from
 * the keyboard like the other three.
 *
 * The strip's wrapping is asserted over exactly the entries in `TABS`, so
 * adding one is a change to `app.test.tsx` rather than only to this file.
 *
 * **The `/employer` link is shown unless the server has said there are none.**
 * That is deliberately not "shown once we know there are some" — the two read
 * identically until the network fails. `venueDoorOpen` below carries the
 * argument.
 *
 * It lost its `<h1>Signed in</h1>` in the move to tabs. Each of the three
 * surfaces brings its own — "Rooms", "Peers", "Your record" — so keeping one
 * here made two on the page, and the one that would have won the reader's
 * attention was a greeting rather than the name of what they were looking at.
 *
 * ## The page no longer explains itself to a developer
 *
 * Three blocks of prose used to sit under the panel: a paragraph on the profile
 * tab having no channel behind it, and a list headed "Not reachable from here
 * yet" naming erasure, retention and the demo controls. They were addressed to
 * whoever was building the next unit — they cited units, a file path, "no
 * endpoint and no channel", and an HTTP header — so a worker who signed in to
 * read a room was handed a status report on the project instead of the product.
 *
 * They are deleted rather than reworded, because the reader they were written
 * for is not on this screen and every claim they made is still recorded where
 * that reader will be standing: `features/profile/contract.ts` is the one place
 * that says nothing on the server answers a profile event, and `sockets_test.exs`
 * pins the routing table that makes it true.
 *
 * The rule the sweep followed, for whoever does the next surface: copy that
 * tells a worker what is true of *their* record, or what to do next, stays.
 * Copy that tells a developer how the thing is put together goes.
 */

import type { KeyboardEvent } from "react";
import { useId, useRef, useState } from "react";
import { Link } from "react-router";

import type { ManagedVenue } from "../../features/employer/employer";
import { useManagedVenues } from "../../features/employer/use-employer-venue";
import { PeersRoute } from "../../features/peers/peers-route";
import { ProfileRoute } from "../../features/profile/profile-route";
import type { RoomStore } from "../../features/rooms/room-store";
import { RoomsRoute } from "../../features/rooms/rooms-route";
import { useSession } from "../../session/session-context";
import { SessionBar } from "../session-bar";
import type { Loaded } from "../use-fetched";

const TABS = [
  { id: "rooms", label: "Rooms" },
  { id: "peers", label: "Peers" },
  { id: "profile", label: "Profile" },
  { id: "venues", label: "Venues" },
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
  // other three tabs out of the tab order, so after an arrow key the browser
  // has nowhere to put focus on its own.
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
   * Selection follows focus, which is the pattern's automatic-activation form.
   * It was free when every panel was already on this device; **Venues fetches**,
   * so arrowing past it now costs one `GET /api/employer/venues` for a tab the
   * worker was only passing through.
   *
   * Kept anyway. That read is idempotent, it is the same call opening the tab
   * makes deliberately, and the alternative — manual activation, where the
   * arrow keys move focus and Enter selects — is a second interaction rule for
   * one tab in four, on the surface a session opens on. The cost is one request
   * somebody's keyboard travel decided to make; the cost of the other is that
   * three tabs behave one way and the fourth another.
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
              Named only on the selected tab, because the other three panels
              are not in the document — see this file's header — and an
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
    </section>
  );
}

/**
 * What the open tab shows.
 *
 * Three of the four are a surface rendered exactly as its own route renders it.
 * The fourth is `VenueDoors`, which is this file's own and is why the return
 * type is not "one of the three routes" — see the header.
 *
 * An exhaustive switch rather than four `&&`s, so that a fifth tab is a compile
 * error here rather than a blank panel at runtime.
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
    case "venues":
      return <VenueDoors />;
  }
}

/**
 * The two ways into the employer half of the product.
 *
 * `useManagedVenues` is the hook `EmployerRoute` already uses rather than a
 * second fetch of the same list, so there is one spelling of "which venues may
 * this session act for" and one place a change to it lands.
 *
 * **The request is made when this tab is opened and not before**, which is the
 * one place the "only the open tab is mounted" rule in the header pays rather
 * than costs: a worker who never manages anything never opens this tab and
 * never makes the call. Nothing is cached between opens, deliberately —
 * `use-employer-venue.ts` gives the reason, and it is the same one that keeps a
 * revoked authority off the screen.
 */
function VenueDoors() {
  const venues = useManagedVenues();

  return (
    <ul>
      {venueDoorOpen(venues.state) && (
        <li>
          <Link to="/employer">Venues you manage</Link>
        </li>
      )}
      <li>
        <Link to="/claim">Claim a job</Link>
      </li>
    </ul>
  );
}

/**
 * Whether to offer the way into `/employer`.
 *
 * **Hidden only on a successful answer naming no venues** — never on "not known
 * to be non-empty", and the two are indistinguishable until the network fails,
 * which is exactly when the difference matters. Written the other way round, a
 * manager whose one request timed out loses their only door into their own
 * venues and has nothing on screen to say why.
 *
 * So a read that is still in flight, refused, or idle all show the link. The
 * cost is bounded and already paid for: `/employer` has its own copy for the
 * empty case *and* for the failed one, so the worst outcome is a link to a page
 * that explains itself properly. The cost of the other choice is unbounded —
 * there is no other route to that page from this client.
 *
 * **In-flight is therefore the same answer as refused, on purpose.** A separate
 * "wait and see" branch would spare somebody who manages nothing a link that
 * appears and vanishes, and would charge the manager — the person the door is
 * for — a wait for it. One predicate, and the person who needs it never waits.
 */
function venueDoorOpen(state: Loaded<readonly ManagedVenue[]>): boolean {
  return state.status !== "ready" || state.value.length > 0;
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
