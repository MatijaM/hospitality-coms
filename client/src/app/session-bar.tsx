/**
 * Who is signed in, the name they are shown under, and the way to stop being
 * them.
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
 *
 * ## Why the display-name control is here (#66)
 *
 * A name a person chose about themselves belongs on their profile, and
 * `/profile` **cannot connect**: `features/profile/contract.ts` exists because
 * no channel on the server answers a single profile event, and nothing has
 * changed that. So the control has to live on a surface that works today.
 *
 * This is the only place in the client that renders your own identity, and it
 * is on every screen a session rests on — `HomeRoute`, `EmployerRoute` and
 * `ClaimPanel` — which is strictly more reach than a tab on the landing page
 * would have had. Exactly one instance mounts at a time, since one route
 * renders at a time, so the input's `id` needs no per-instance prefix the way
 * `DeclaredEntryForm`'s does.
 *
 * The form is behind a toggle rather than always open. A bar is a bar, and an
 * always-visible text input on every screen reads as something that wants
 * filling in.
 *
 * The address keeps an element of its own rather than becoming a bare text node
 * beside the name. Nine assertions in `app.test.tsx` find it with
 * `findByText("worker@example.com")`, and that query matches an *element* whose
 * text is the address — so splitting the sentence around `<strong>` would have
 * broken all nine for a reason that has nothing to do with what they assert.
 * The claim each of them makes ("the signed-in address is on screen") is
 * unchanged, so the markup is what moved.
 */

import { useState } from "react";

import { failureMessage } from "./failure-message";
import type { RequestFailure } from "../api/errors";
import { copy } from "../i18n/copy";
import { useSession } from "../session/session-context";

export function SessionBar() {
  const { state, logOut } = useSession();
  const [editing, setEditing] = useState(false);

  if (state.status !== "authenticated") return null;

  return (
    <>
      <p>
        {copy["session.signedInAs"]} <strong>{state.person.displayName}</strong> (
        <span>{state.person.email ?? copy["session.erasedAccount"]}</span>).
      </p>
      {editing ? (
        <DisplayNameForm
          current={state.person.displayName}
          onDone={() => {
            setEditing(false);
          }}
        />
      ) : (
        <button
          type="button"
          onClick={() => {
            setEditing(true);
          }}
        >
          {copy["session.changeName"]}
        </button>
      )}
      <button
        type="button"
        onClick={() => {
          void logOut();
        }}
      >
        {copy["session.logOut"]}
      </button>
    </>
  );
}

/**
 * The name, and one attempt to change it.
 *
 * `saving` disables the fieldset rather than the button alone, which is
 * `DeclaredEntryForm`'s shape: a submit that is in flight must not be able to
 * be re-submitted with a different value.
 *
 * A refusal leaves the form open with what was typed still in it and the
 * server's own sentence beside it. Nothing is rendered optimistically — the
 * name on the bar changes only when the server has answered with the row, which
 * is what `rename` puts on the session.
 */
function DisplayNameForm({
  current,
  onDone,
}: {
  readonly current: string;
  readonly onDone: () => void;
}) {
  const { rename } = useSession();
  const [name, setName] = useState(current);
  const [saving, setSaving] = useState(false);
  const [failure, setFailure] = useState<RequestFailure | null>(null);

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        setSaving(true);
        setFailure(null);

        void rename(name).then((outcome) => {
          setSaving(false);

          if (outcome.ok) {
            onDone();

            return;
          }

          setFailure(outcome.failure);
        });
      }}
    >
      <fieldset disabled={saving}>
        <label htmlFor="session-display-name">{copy["session.yourNameLabel"]}</label>
        <input
          id="session-display-name"
          name="display_name"
          type="text"
          value={name}
          onChange={(event) => {
            setName(event.target.value);
          }}
        />
        <button type="submit">{copy["session.saveName"]}</button>
        <button
          type="button"
          onClick={() => {
            onDone();
          }}
        >
          {copy["common.cancel"]}
        </button>
      </fieldset>
      {failure === null ? null : <p aria-live="polite">{refusalText(failure)}</p>}
    </form>
  );
}

/**
 * What to show when a rename is refused.
 *
 * A `422` carries `fields.display_name` — Ecto's own words about the thing the
 * worker typed — and `failure-message.ts` names that as the one exception to
 * rendering this client's copy instead of the server's. Its generic
 * `unprocessable_entity` line is "That was not accepted", which does not say
 * *why*, and "why" here is either "can't be blank" or a character bound.
 *
 * `Object.values(...).flat()` is `room-view.tsx`'s and `conversation-view.tsx`'s
 * spelling of the same thing.
 */
function refusalText(failure: RequestFailure): string {
  if (failure.kind !== "api_field_error") return failureMessage(failure);

  const messages = Object.values(failure.fields).flat();

  return messages.length === 0 ? failureMessage(failure) : messages.join(", ");
}
