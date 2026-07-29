/**
 * Who is signed in, and the way to stop being them.
 *
 * It was inline in `HomeRoute` and became a component when U4 added two full
 * pages of its own. Hospitality is a shared-terminal industry and the employer
 * page is the one somebody leaves open in a back office, so "log out" has to be
 * on every screen a session can rest on rather than only on the one it opened.
 *
 * The markup is `HomeRoute`'s, unchanged — same sentence, same button label —
 * because `app.test.tsx` asserts the identity block stays out of the tab panels
 * and a second spelling of "signed in as" would be a second thing that has to
 * stay true.
 *
 * It renders nothing when the session is not authenticated. Every caller is
 * already inside `RequireSession`, so that branch is a type narrowing rather
 * than a state anybody reaches.
 */

import { useSession } from "../session/session-context";

export function SessionBar() {
  const { state, logOut } = useSession();

  if (state.status !== "authenticated") return null;

  return (
    <>
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
    </>
  );
}
