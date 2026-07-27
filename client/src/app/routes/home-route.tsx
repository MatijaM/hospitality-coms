/**
 * The authenticated placeholder.
 *
 * It shows the session is real — the person `GET /api/me` returned, and a log
 * out that ends the session server-side — and then says plainly what is not
 * here. Naming the absences beats an empty dashboard: the next unit needs to
 * know which surface it owns, and a worker looking at this needs to know
 * nothing is broken.
 */

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

      <h2>Not built yet</h2>
      <p>
        Everything below needs an endpoint or a channel that this API does not serve yet.
        Nothing is stubbed, because a placeholder for a shape nobody has chosen costs more
        to remove than to write.
      </p>
      <ul>
        <li>Shift and venue rooms, and sending a message — waiting on U7.</li>
        <li>The peer directory and peer conversations — waiting on U8.</li>
        <li>
          The profile, its attested entries and its disclosure controls — waiting on U9.
        </li>
        <li>Archived engagements and erasure — waiting on U10.</li>
        <li>The demo controls — waiting on U11.</li>
      </ul>
    </section>
  );
}
