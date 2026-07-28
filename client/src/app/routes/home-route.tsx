/**
 * The authenticated placeholder.
 *
 * It shows the session is real — the person `GET /api/me` returned, and a log
 * out that ends the session server-side — and then says plainly what is not
 * here. Naming the absences beats an empty dashboard: the next unit needs to
 * know which surface it owns, and a worker looking at this needs to know
 * nothing is broken.
 *
 * ## Say what is missing, not which unit owes it
 *
 * This list previously read "waiting on U9", "waiting on U10", "waiting on
 * U11". All three shipped, and the list still said so — it was written when
 * they were future work and nothing brought it back. Worse, the vocabulary was
 * the plan's: a worker reading "waiting on U9" learns nothing, and a developer
 * reading it after U9 merged learns something false.
 *
 * So each entry now names the thing that is actually absent. Those are
 * checkable claims, and one of them is checked: `/profile` cannot connect
 * because `PersonSocket` routes no `profile:*` topic, and `sockets_test.exs`
 * pins that socket's routing table exactly, with a control. Adding the channel
 * fails that test, which is where somebody will be standing when this paragraph
 * needs deleting.
 */

import { Link } from "react-router";

import { useSession } from "../../session/session-context";

export function HomeRoute() {
  const { state, logOut } = useSession();

  // `RequireSession` renders this only when the session is authenticated. The
  // early return is what narrows the union; it is not a state that happens.
  if (state.status !== "authenticated") return null;

  return (
    <section>
      <h1>Signed in</h1>
      <p>
        You are signed in as <strong>{state.person.email ?? "an erased account"}</strong>.
      </p>
      <button
        type="button"
        onClick={() => {
          void logOut();
        }}
      >
        Log out
      </button>

      <h2>Rooms</h2>
      <p>
        <Link to="/rooms">Your venue and shift rooms</Link>. The list of rooms lives in
        this browser, because the API serves no endpoint that lists them; everything about
        each room comes from its channel.
      </p>

      <h2>Peers</h2>
      <p>
        <Link to="/peers">The people you worked with, and your conversations</Link>.
        Unlike the rooms, nothing about this is kept in this browser — the peer channel
        serves the lists, so there is nothing here to remember and nothing to clear.
      </p>

      <h2>Profile</h2>
      <p>
        <Link to="/profile">Your record, and who can see each part of it</Link>.{" "}
        <strong>This screen cannot connect yet.</strong> The record itself is built —
        attested entries, declared entries, corrections, and the per-venue and per-person
        disclosure rules — but nothing carries it to this browser, so the screen loads and
        then reports that it could not join.
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
