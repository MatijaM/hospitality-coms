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
 *
 * ## History comes over HTTP and the stream comes over the channel
 *
 * `useRoomHistory` fetches what was said before this session opened the room;
 * `useRoom` collects what arrives after. They are two independent requests and
 * neither waits for the other, so a message sent between them arrives twice and
 * `mergeMessages` keys on the id — the same manoeuvre `use-room.ts` already
 * makes for the send reply and the broadcast of one message.
 *
 * **The "load the whole history" control is conditional on `complete`.** The
 * server bounds the default read at `HospitalityComs.Rooms
 * .recent_message_limit/0` and says whether that was the lot; offering the
 * control unconditionally would tell somebody whose room holds three messages
 * that there are more. That is also the only thing this client knows about the
 * bound — there is no number here and there must not be one.
 *
 * ## The header is the room's name, and it is `roomLabel`'s order or nothing
 *
 * It was `<h2>Venue room</h2>` over `<code>{ref.id}</code>` — the one uuid left
 * on this surface after #72 named every row of both lists, and the largest one,
 * since it sat over the conversation rather than in a list. It is the room's
 * name now, over the kind, and the order behind it is **not written here**:
 * `roomLabel` is live → stored → fallback and there is one spelling of that in
 * this client. A second one would drift, and the direction it would drift in is
 * the reported bug — a header preferring the stored name keeps a renamed venue
 * reading under its old name, and one that skipped straight to the fallback
 * would put a shortened uuid back where a whole one used to be.
 *
 * The live name is a **prop** rather than something fetched here, because the
 * two lists that carry one already live in `rooms-route.tsx` — the
 * recently-opened list needs them too, which is why they moved up a component
 * in #72. Fetching them again here would be a second request per open and a
 * second answer to disagree with.
 */

import { useState } from "react";

import type { ChannelFieldError } from "../../socket/channel-failure";
import type { RoomClosure, RoomEntry, RoomMessage, SendBar } from "./room";
import { instantLabel, mergeMessages, roomKindLabel, roomLabel } from "./room";
import type { RoomErrorCode } from "./refusal-message";
import {
  barFromRefusal,
  barMessage,
  readFailureMessage,
  refusalMessage,
} from "./refusal-message";
import type { RoomHistory } from "./use-room-history";
import { useRoomHistory } from "./use-room-history";
import type { Room, RoomConnection, SendState } from "./use-room";
import { useRoom } from "./use-room";

export type RoomViewProps = {
  readonly entry: RoomEntry;
  /**
   * What a list on screen calls this room at this instant, or `null` when none
   * does.
   *
   * `null` is a real answer rather than a missing one: a shift room reached
   * after a reload with its venue collapsed has no live name anywhere in this
   * client, which is the case `RoomEntry.name` exists for. It is handed
   * straight to `roomLabel`, which decides between the three.
   */
  readonly liveName: string | null;
  /** Called after the topic has been left, never before. */
  readonly onEnded: (entry: RoomEntry, closure: RoomClosure) => void;
  readonly onBarred: (entry: RoomEntry, bar: SendBar) => void;
  readonly onClearBar: (entry: RoomEntry) => void;
};

export function RoomView({
  entry,
  liveName,
  onEnded,
  onBarred,
  onClearBar,
}: RoomViewProps) {
  const room = useRoom(entry.ref, {
    onEnded: (closure) => {
      onEnded(entry, closure);
    },
    onSendRefused: (failure) => {
      const bar = barFromRefusal(failure);
      if (bar !== null) onBarred(entry, bar);
    },
  });

  const history = useRoomHistory(entry.ref);

  const fetched = history.state.status === "ready" ? history.state.page.messages : [];
  const messages = mergeMessages(fetched, room.messages);

  // Clearing the bar re-enables the composer. Leaving the sentence that closed
  // it sitting above the now-usable input says the room is still refusing,
  // which is the opposite of what the button just did.
  function checkAgain(): void {
    room.clearSend();
    onClearBar(entry);
  }

  // One string for the heading and for the region's accessible name, so a
  // screen reader and a sighted reader are told the same thing about which
  // room this is. Only one room is open at a time, so it is unique among the
  // regions on this screen.
  const label = roomLabel(entry, liveName);

  return (
    <section aria-label={label}>
      <h2>{label}</h2>
      {/*
        The kind, where the id used to be. It is still worth saying — a venue
        room and a shift room refuse a send for different reasons and one of
        them closes — and `roomFallbackLabel` already carries it for a room
        with no name, so the duplication is confined to the degenerate row.
      */}
      <p>{roomKindLabel(entry.ref.kind)}</p>

      <ConnectionState connection={room.connection} />
      {entry.barred !== null && (
        <div>
          <p role="status">{barMessage(entry.barred)}</p>
          <button type="button" onClick={checkAgain}>
            Check again
          </button>
        </div>
      )}

      <History history={history} />
      <Messages messages={messages} connection={room.connection} />
      <Composer entry={entry} room={room} />
    </section>
  );
}

/**
 * What the history fetch is doing, and the control that lifts its bound.
 *
 * `aria-live` without `role="status"` for `rooms-route.tsx`'s reason: the one
 * status region on this screen is the room's own connection, and a second one
 * competing with it makes the important one harder to find.
 */
function History({ history }: { readonly history: RoomHistory }) {
  switch (history.state.status) {
    case "idle":
      return null;
    case "loading":
      return <p aria-live="polite">Loading what was said before…</p>;
    case "failed":
      return <p aria-live="polite">{readFailureMessage(history.state.failure)}</p>;
    case "ready":
      return history.state.page.complete ? null : (
        <div>
          <p aria-live="polite">
            This is the most recent part of the room. There is more before it.
          </p>
          <button type="button" onClick={history.loadAll}>
            Load the whole history
          </button>
        </div>
      );
  }
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
      <ul aria-label="Messages">
        {messages.map((message) => (
          <li key={message.id}>
            <strong>
              {own !== null && message.authorEngagementId === own
                ? "You"
                : authorLabel(message)}
            </strong>{" "}
            <span>{message.body}</span>{" "}
            {/*
              Formatted for the same reason the shift room's `closes_at` is,
              and this list is where it started mattering: until this unit a
              room only showed what had arrived since it was opened, so every
              timestamp here was minutes old. It now opens on a fetched
              history, so the list carries instants from days ago — which is
              exactly where a raw `2026-03-09T14:00:00Z` is least readable.
            */}
            <time dateTime={message.sentAt}>{instantLabel(message.sentAt)}</time>
          </li>
        ))}
      </ul>
    </>
  );
}

/**
 * How somebody else's message is attributed: who they are, what they do here,
 * and the id beside both.
 *
 * The name is theirs (#66) and the label is the venue's own words for their job
 * (#65); the server joins both on every read, so they follow a rename and a
 * corrected engagement, and an erased author reads as two non-identifying
 * constants. **Neither is unique** — a globally unique readable name would be a
 * second `person_id` in plain text, and a venue can hold two Bartenders — so
 * the shortened engagement id stays, and it is the only one of the three that
 * tells two speakers apart.
 *
 * The order is who, then what, then the id nobody can read. Reversing the first
 * two would put a job title where a name belongs in a sentence about a person.
 */
function authorLabel(message: RoomMessage): string {
  return [
    message.authorDisplayName,
    message.authorRoleLabel,
    shortId(message.authorEngagementId),
  ].join(" · ");
}

/**
 * An engagement id, shortened for reading.
 *
 * Venue-local by construction (KTD15b), which is why it is still here beside a
 * name that is not.
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
