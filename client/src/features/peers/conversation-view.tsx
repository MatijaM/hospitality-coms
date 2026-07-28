/**
 * One open conversation: its history, what has arrived since, a composer, and
 * the one control that ends it.
 *
 * ## The history is fetched, unlike a room's
 *
 * `features/rooms/` shows only what arrived after the join, because there is no
 * `"history"` event and no HTTP surface for `Rooms.list_venue_room_messages/2`
 * — inventing one would have been inventing a backend. `PeerChannel` has
 * `"history"`, so this asks for it on open and the difference is the server's
 * rather than a decision made here.
 *
 * What comes back is **each party's own view**: while a conversation is open
 * both read the whole of it, and once it has been disconnected each party reads
 * their own messages and only their own. Nothing is deleted to achieve that
 * (KTD21 reserves deletion for erasure), so a closed conversation is a shorter
 * list rather than a missing one — worth knowing before reading a closed
 * conversation and wondering where the other half went, which is why it is on
 * screen and not only in this comment.
 *
 * ## Attribution is a person here, and that is not KTD15b being broken
 *
 * A room message carries `author_engagement_id` because a room lives in the
 * employer zone and no employer-zone row may name a person. A peer message
 * carries `author_id`, a person id, because the whole peer graph is person
 * zone: the counterpart's `person_id` is already in the peer list and in the
 * conversation, and it is what the two parties connected *as*. There is still
 * no name and no email anywhere on this wire.
 *
 * ## Disconnecting is confirmed, because it is not undoable and not symmetric
 *
 * R15 makes a conversation revocable by either party alone, and KTD19 makes the
 * consequence directional: whoever disconnects keeps the initiative, and their
 * counterpart may not approach again. So this is not "close a window" — it is a
 * remedy with a lasting effect on somebody else, and the two-step is there so
 * it is not reached by a mis-click.
 */

import { useEffect, useState } from "react";

import type { ChannelFieldError } from "../../socket/channel-failure";
import type { Conversation } from "./peer";
import { shortId } from "./peer";
import type { PeerErrorCode } from "./refusal-message";
import type { PeerSurface } from "./use-peer-surface";

export type ConversationViewProps = {
  readonly conversation: Conversation;
  readonly ownPersonId: string;
  readonly surface: PeerSurface;
  readonly onClose: () => void;
};

export function ConversationView({
  conversation,
  ownPersonId,
  surface,
  onClose,
}: ConversationViewProps) {
  const { connectionId, open } = conversation;
  const { loadHistory, joinGeneration } = surface;
  const messages = surface.messagesOf(connectionId);

  // `loadHistory` is stable — a `useCallback` over `run`, which is a
  // `useCallback` over nothing that changes — so the three values beside it are
  // the whole of when this re-asks, and each is there for its own reason.
  //
  //   * `connectionId` — a different conversation. The parent also keys on it,
  //     so this is a fresh mount, but naming it keeps the effect honest on its
  //     own terms.
  //   * `open` — the conversation just closed. This is what makes the
  //     counterpart's messages leave the screen: `loadHistory` **replaces**
  //     rather than merges once `open` is false, and the server sends back this
  //     party's own messages and only their own (R15). Without this dependency
  //     nothing re-asked, and the cache from while it was open stayed rendered.
  //   * `joinGeneration` — the socket rejoined. Messages sent while the link
  //     was down reached no push here, and the history is not one of the three
  //     lists `onJoined` re-asks, so this is the only thing that backfills
  //     them. `merged` dedups by `messageId`, so the re-fetch is idempotent.
  useEffect(() => {
    void loadHistory(connectionId, open);
  }, [loadHistory, connectionId, open, joinGeneration]);

  return (
    <section aria-label={`Conversation with ${shortId(conversation.peerId)}`}>
      <h2>Conversation with {shortId(conversation.peerId)}</h2>
      <p>
        Connected{" "}
        <time dateTime={conversation.connectedAt}>{conversation.connectedAt}</time>.{" "}
        <button type="button" onClick={onClose}>
          Close this view
        </button>
      </p>

      {conversation.open ? null : (
        <p role="status">
          This conversation is closed
          {conversation.disconnectedById === null
            ? ""
            : conversation.disconnectedById === ownPersonId
              ? " — you ended it"
              : " — they ended it"}
          . You keep everything you wrote and they keep everything they wrote, so what is
          below is your half of it. Nothing was deleted.
        </p>
      )}

      <ul aria-label="Conversation messages">
        {messages.map((message) => (
          <li key={message.messageId}>
            <strong>
              {message.authorId === ownPersonId ? "You" : shortId(message.authorId)}
            </strong>{" "}
            <span>{message.body}</span>{" "}
            <time dateTime={message.sentAt}>{message.sentAt}</time>
          </li>
        ))}
      </ul>

      <Composer conversation={conversation} surface={surface} />
      {conversation.open && (
        <DisconnectControl conversation={conversation} surface={surface} />
      )}
    </section>
  );
}

function Composer({
  conversation,
  surface,
}: {
  readonly conversation: Conversation;
  readonly surface: PeerSurface;
}) {
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);
  const disabled = !conversation.open || sending;

  // Cleared on success and never on submit, which is `features/rooms/`'s
  // lesson: clearing on submit means every refusal silently eats what was
  // typed, and the worker reads a sentence explaining the failure with nothing
  // left to correct and resend.
  async function submit(): Promise<void> {
    setSending(true);
    const outcome = await surface.sendMessage(conversation.connectionId, body);
    setSending(false);

    if (outcome.status === "ok") setBody("");
  }

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        if (disabled || body.trim() === "") return;

        void submit();
      }}
    >
      <label htmlFor="peer-message-body">Message</label>
      <input
        id="peer-message-body"
        name="peer-message-body"
        type="text"
        value={body}
        disabled={disabled}
        onChange={(event) => {
          setBody(event.target.value);
        }}
      />
      <button type="submit" disabled={disabled}>
        Send
      </button>
    </form>
  );
}

function DisconnectControl({
  conversation,
  surface,
}: {
  readonly conversation: Conversation;
  readonly surface: PeerSurface;
}) {
  const [asking, setAsking] = useState(false);

  if (!asking) {
    return (
      <button
        type="button"
        onClick={() => {
          setAsking(true);
        }}
      >
        Disconnect
      </button>
    );
  }

  return (
    <div role="group" aria-label="Confirm disconnect">
      <p>
        This ends the conversation for both of you. Neither of you can send to it again,
        you each keep your own messages, and{" "}
        <strong>they cannot ask you to reconnect</strong>— the next approach would have to
        come from you.
      </p>
      <button
        type="button"
        onClick={() => {
          void surface.disconnect(conversation.connectionId);
          setAsking(false);
        }}
      >
        Yes, disconnect
      </button>
      <button
        type="button"
        onClick={() => {
          setAsking(false);
        }}
      >
        Cancel
      </button>
    </div>
  );
}

/**
 * The server's per-field messages, rendered as they arrive.
 *
 * The one exception to not rendering the server's own words, for
 * `failure-message.ts`'s reason: these come from Ecto's changeset traversal and
 * name an input the worker actually typed — `body`, for a message that was too
 * long or empty.
 */
export function FieldMessages({
  failure,
}: {
  readonly failure: ChannelFieldError<PeerErrorCode>;
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
