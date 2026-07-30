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

  // Named once and used for the heading and the region's accessible name, so
  // the two cannot come to say different things. The short id stays beside the
  // name for the reason it stays everywhere on this surface: collisions are
  // deliberate, and an erased counterpart reads "Former colleague", which every
  // erased counterpart reads.
  const counterpart = `${conversation.peerDisplayName} · ${shortId(conversation.peerId)}`;

  return (
    <section aria-label={`Conversation with ${counterpart}`}>
      <h2>Conversation with {counterpart}</h2>
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
            {/*
              The server sends this person's own name like anybody else's — the
              join does not know who is asking — so "You" is a choice made here
              rather than an absence inherited from the wire.
            */}
            <strong>
              {message.authorId === ownPersonId
                ? "You"
                : `${message.authorDisplayName} · ${shortId(message.authorId)}`}
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

/**
 * The confirm step, and the one control that ends the conversation.
 *
 * Two flags rather than one, because they answer two different questions:
 * `asking` is whether the confirmation is on screen, and `disconnecting` is
 * whether an answer is in flight. Both controls close while one is running,
 * which is `IncomingRequest`'s shape in `peers-route.tsx` and is here for the
 * same reason: the second click of a double-click sends a second `disconnect`
 * for a conversation the first one closed, and the server answers it `conflict`
 * — a refusal this surface would then render beside a conversation that did in
 * fact end, which is worse than not sending it.
 *
 * `asking` is cleared **after** the reply rather than beside the push. Clearing
 * it first re-rendered the "Disconnect" button while the request was still out,
 * so the confirm step could be reached again and the flag guarded nothing.
 */
function DisconnectControl({
  conversation,
  surface,
}: {
  readonly conversation: Conversation;
  readonly surface: PeerSurface;
}) {
  const [asking, setAsking] = useState(false);
  const [disconnecting, setDisconnecting] = useState(false);

  // On success the conversation closes and `ConversationView` stops rendering
  // this at all, so the two writes below land on a component that is going
  // away. On a refusal they are what puts the surface back where it was, with
  // the sentence the notice is already showing.
  async function confirm(): Promise<void> {
    setDisconnecting(true);
    await surface.disconnect(conversation.connectionId);
    setDisconnecting(false);
    setAsking(false);
  }

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
        disabled={disconnecting}
        onClick={() => {
          void confirm();
        }}
      >
        Yes, disconnect
      </button>
      <button
        type="button"
        disabled={disconnecting}
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
