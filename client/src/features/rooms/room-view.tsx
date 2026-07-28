/**
 * One open room: its state, what has been said in it since the join, and a
 * composer that is only enabled when the server would accept a message.
 *
 * ## The composer's disabled condition is the room's state, not a flag
 *
 * Three things independently mean "not now", and each is rendered as the
 * sentence it actually is:
 *
 *   * the channel is not joined — joining, refused, timed out, **lost** (a send
 *     the server answered `unauthorized`), or over;
 *   * the room is barred — closed to new messages, or this session is off the
 *     roster (`room.ts` traces both to their refusals);
 *   * a send is in flight, so a second click would be a second message.
 *
 * A disabled input with nothing next to it is the failure the "explicit
 * message" scenario is about, one step earlier: the worker types, nothing
 * happens, and there is no sentence anywhere saying why. So every disabled
 * state here carries its reason, and every one of them carries a way forward:
 * "Check again" for a bar, and re-opening the room for a lost one.
 */

import { useState } from "react";

import type { ChannelFieldError } from "../../socket/channel-failure";
import type { RoomClosure, RoomEntry, RoomMessage, SendBar } from "./room";
import { roomKindLabel } from "./room";
import type { RoomErrorCode } from "./refusal-message";
import { barFromRefusal, barMessage, refusalMessage } from "./refusal-message";
import type { Room, RoomConnection, SendState } from "./use-room";
import { useRoom } from "./use-room";

export type RoomViewProps = {
  readonly entry: RoomEntry;
  /** Called after the topic has been left, never before. */
  readonly onEnded: (entry: RoomEntry, closure: RoomClosure) => void;
  readonly onBarred: (entry: RoomEntry, bar: SendBar) => void;
  readonly onClearBar: (entry: RoomEntry) => void;
};

export function RoomView({ entry, onEnded, onBarred, onClearBar }: RoomViewProps) {
  const room = useRoom(entry.ref, {
    onEnded: (closure) => {
      onEnded(entry, closure);
    },
    onSendRefused: (failure) => {
      const bar = barFromRefusal(failure);
      if (bar !== null) onBarred(entry, bar);
    },
  });

  // Clearing the bar re-enables the composer. Leaving the sentence that closed
  // it sitting above the now-usable input says the room is still refusing,
  // which is the opposite of what the button just did.
  function checkAgain(): void {
    room.clearSend();
    onClearBar(entry);
  }

  return (
    <section aria-label={`${roomKindLabel(entry.ref.kind)} ${entry.ref.id}`}>
      <h2>{roomKindLabel(entry.ref.kind)}</h2>
      <p>
        <code>{entry.ref.id}</code>
      </p>

      <ConnectionState connection={room.connection} />
      {entry.barred !== null && (
        <div>
          <p role="status">{barMessage(entry.barred)}</p>
          <button type="button" onClick={checkAgain}>
            Check again
          </button>
        </div>
      )}

      <Messages messages={room.messages} connection={room.connection} />
      <Composer entry={entry} room={room} />
    </section>
  );
}

function ConnectionState({ connection }: { readonly connection: RoomConnection }) {
  switch (connection.status) {
    case "no_socket":
      return <p role="status">Connecting…</p>;
    case "joining":
      return <p role="status">Opening this room…</p>;
    case "joined":
      return null;
    case "timed_out":
      return (
        <p role="alert">
          The server has not answered yet. It will keep trying on its own; nothing has
          been refused.
        </p>
      );
    case "refused":
      return <p role="alert">{refusalMessage(connection.failure)}</p>;
    case "lost":
      return (
        <p role="alert">
          This room is no longer open to you. Open it again to see whether that is still
          true.
        </p>
      );
    case "ended":
      // Only a suspension is ever seen here. A revocation sets this state and
      // drops the room from the list in the same batch, so React re-renders
      // `RoomsRoute` without this component and never commits the branch — the
      // revoked copy that used to live here was unreachable in any build of
      // this code, which is worse than absent because it reads as live.
      //
      // Kept as a `null` rather than deleted outright: if a later unit decides
      // a revoked room should linger, this is the line it has to notice.
      return connection.closure.reason === "suspended" ? (
        <p role="alert">
          You have suspended this room. It stays hidden until you resume it.
        </p>
      ) : null;
  }
}

function Messages({
  messages,
  connection,
}: {
  readonly messages: readonly RoomMessage[];
  readonly connection: RoomConnection;
}) {
  if (connection.status !== "joined" && messages.length === 0) return null;

  const own = connection.status === "joined" ? connection.engagementId : null;

  return (
    <>
      <p>
        This room shows what has been said since you opened it. There is no endpoint that
        serves the history.
      </p>
      <ul aria-label="Messages">
        {messages.map((message) => (
          <li key={message.id}>
            <strong>
              {own !== null && message.authorEngagementId === own
                ? "You"
                : shortId(message.authorEngagementId)}
            </strong>{" "}
            <span>{message.body}</span>{" "}
            <time dateTime={message.sentAt}>{message.sentAt}</time>
          </li>
        ))}
      </ul>
    </>
  );
}

/**
 * An engagement id, shortened for reading.
 *
 * It is the only identity on the wire and it is venue-local by construction
 * (KTD15b) — there is no name to render, because there is no name in the
 * employer zone to put one from.
 */
function shortId(engagementId: string): string {
  return engagementId.slice(0, 8);
}

function Composer({ entry, room }: { readonly entry: RoomEntry; readonly room: Room }) {
  const [body, setBody] = useState("");
  const disabled =
    room.connection.status !== "joined" ||
    entry.barred !== null ||
    room.send.status === "sending";

  // Cleared on success, never on submit. Clearing on submit meant every
  // refusal ate what the worker wrote: they read a sentence explaining the
  // failure with nothing left to correct and resend.
  async function submit(): Promise<void> {
    const outcome = await room.sendMessage(body);

    if (outcome.status === "sent") setBody("");
  }

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        if (disabled || body.trim() === "") return;

        void submit();
      }}
    >
      <label htmlFor="message-body">Message</label>
      <input
        id="message-body"
        name="message-body"
        type="text"
        value={body}
        disabled={disabled}
        onChange={(event) => {
          setBody(event.target.value);
        }}
      />
      <SendOutcome send={room.send} />
      <button type="submit" disabled={disabled}>
        Send
      </button>
    </form>
  );
}

function SendOutcome({ send }: { readonly send: SendState }) {
  switch (send.status) {
    case "idle":
    case "sending":
    case "sent":
      return null;
    case "unsent":
      return (
        <p role="alert">
          That was not sent. This room was closed before the message left this browser.
        </p>
      );
    case "refused":
      return (
        <>
          <p role="alert">{refusalMessage(send.failure)}</p>
          {send.failure.kind === "channel_field_error" && (
            <FieldMessages failure={send.failure} />
          )}
        </>
      );
  }
}

/**
 * The server's per-field messages, rendered as they arrive.
 *
 * The one exception to not rendering the server's own words, for the reason
 * `failure-message.ts` gives: these come from Ecto's changeset traversal and
 * name `body`, which is the thing the worker typed.
 */
function FieldMessages({
  failure,
}: {
  readonly failure: ChannelFieldError<RoomErrorCode>;
}) {
  const messages = Object.values(failure.fields).flat();

  return (
    <ul>
      {messages.map((message) => (
        <li key={message} role="alert">
          {message}
        </li>
      ))}
    </ul>
  );
}
