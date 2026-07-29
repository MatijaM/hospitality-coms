/**
 * The peer surface: who this person can see, what has been asked in either
 * direction, and every conversation.
 *
 * ## Everything here comes from the server, every time
 *
 * There is no bookmark list and no local store. `list_peers`,
 * `list_requests` and `list_conversations` are real events, so this surface
 * holds nothing that would have to be written down — which is also why nothing
 * is added to `SessionProvider`'s `onSessionEnded`: there is nothing on this
 * device to clear. `features/rooms/` keeps a store because no endpoint or event
 * enumerates rooms; the contrast is worth knowing before somebody adds a
 * "recently viewed peers" cache to a shared terminal.
 *
 * ## What this surface does not decide
 *
 * **Who may ask whom.** That is `HospitalityComs.Peers.permitted/3`, read off
 * the pair's one current request row, which this client does not hold and
 * cannot reconstruct: a block is a column on that row, it survives new
 * co-rostering, and it is cleared by an exchange this surface may never have
 * seen. So the "Ask to connect" control is offered unless the server has just
 * said something that settles it — an open conversation, an approach this
 * person already sent, or **one they have already received**, which is an
 * approach that exists in the other direction. Everything else is asked, and a
 * refusal is rendered as the sentence it is. `forbidden` — KTD19's block — says
 * the next approach has to come from them.
 *
 * **Whether a request has expired.** `lapsed` is derived server-side at the
 * instant of the event, and it can go back to `pending` without anything being
 * written. So a lapsed request keeps both of its buttons: accepting it is
 * refused `gone` with a sentence saying it can come back, and declining it is
 * accepted at any time, because an addressee may always say no and refusing a
 * decline would leave the requester holding a row nobody can clear.
 *
 * ## What is deliberately absent
 *
 * **No way to withdraw an approach.** `HospitalityComs.Peers` has no
 * `withdraw_request/2` and says why: declining blocks the requester by design,
 * so a non-blocking withdrawal is a product decision tied to rate limiting
 * (issue #15) rather than a mechanical addition. There is no event for it, so
 * there is no button for it.
 *
 * **No disclosure controls, no profile, no attested entries.** U9 owns those
 * and is being written now; guessing at its shapes here would be a placeholder
 * for a surface nobody has chosen.
 */

import { useState } from "react";

import { useSession } from "../../session/session-context";
import { ConversationView, FieldMessages } from "./conversation-view";
import type { Conversation, Peer, PeerRequest } from "./peer";
import { peerKey, requestStateLabel, requestStateMessage, shortId } from "./peer";
import type { PeerNotice } from "./refusal-message";
import { noticeMessage, refusalMessage } from "./refusal-message";
import type { PeerConnection, PeerSurface } from "./use-peer-surface";
import { usePeerSurface } from "./use-peer-surface";

export function PeersRoute() {
  const { state } = useSession();

  // `RequireSession` renders this only when the session is authenticated. The
  // early return narrows the union; it is not a state that happens.
  if (state.status !== "authenticated") return null;

  return <PeerSurfaceView personId={state.person.id} />;
}

function PeerSurfaceView({ personId }: { readonly personId: string }) {
  const surface = usePeerSurface(personId);
  const [openId, setOpenId] = useState<string | null>(null);

  const open =
    openId === null
      ? null
      : (surface.conversations.find(
          (conversation) => conversation.connectionId === openId,
        ) ?? null);

  return (
    <section>
      <h1>Peers</h1>
      <p>
        Everything here comes from the server every time this page is opened. Nothing
        about who you know is stored in this browser.
      </p>

      <ConnectionState connection={surface.connection} />
      <Notice notice={surface.notice} onDismiss={surface.clearNotice} />

      {/*
        The sections are rendered whatever the connection is doing, and the
        graph leaving the screen after a refused rejoin is `usePeerSurface`
        emptying what it holds rather than this file hiding it.

        Hiding them here as well was the first shape and it was worse, for a
        reason worth keeping: two mechanisms for one rule, of which only the
        outer one was observable, so a test could not tell "not rendered" from
        "not held" and the clear — the half that actually stops a peer graph
        outliving the session in memory — was unfalsifiable. One mechanism, and
        the empty sections under the alert are its evidence.
      */}
      <PeopleYouCanSee surface={surface} onOpenConversation={setOpenId} />
      <IncomingRequests surface={surface} />
      <OutgoingRequests requests={surface.outgoing} />
      <Conversations
        conversations={surface.conversations}
        openId={openId}
        onOpen={setOpenId}
      />

      {open !== null && (
        <ConversationView
          key={open.connectionId}
          conversation={open}
          ownPersonId={personId}
          surface={surface}
          onClose={() => {
            setOpenId(null);
          }}
        />
      )}
    </section>
  );
}

function ConnectionState({ connection }: { readonly connection: PeerConnection }) {
  switch (connection.status) {
    case "no_socket":
      return <p role="status">Connecting…</p>;
    case "no_person":
      return (
        <p role="alert">
          This session does not name a person this client can build a peer surface for.
        </p>
      );
    case "joining":
      return <p role="status">Opening your peer surface…</p>;
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
      return <p role="alert">{refusalMessage("join", connection.failure)}</p>;
  }
}

/**
 * The most recent refusal, in one place.
 *
 * One slot rather than one per control, because a worker does one thing at a
 * time and a surface with five stale sentences on it is a surface nobody reads.
 * It is dismissible so that a refusal answered by doing something else does not
 * sit there contradicting the screen.
 */
function Notice({
  notice,
  onDismiss,
}: {
  readonly notice: PeerNotice | null;
  readonly onDismiss: () => void;
}) {
  if (notice === null) return null;

  return (
    <div>
      <p role="alert">{noticeMessage(notice)}</p>
      {notice.kind === "refused" && notice.failure.kind === "channel_field_error" && (
        <FieldMessages failure={notice.failure} />
      )}
      <button type="button" onClick={onDismiss}>
        Dismiss
      </button>
    </div>
  );
}

function PeopleYouCanSee({
  surface,
  onOpenConversation,
}: {
  readonly surface: PeerSurface;
  readonly onOpenConversation: (connectionId: string) => void;
}) {
  return (
    <>
      <h2>People you can see</h2>
      <p>
        Anybody you worked with at the same place at the same time, for thirty days after
        the first of the two engagements ended. It is worked out fresh on every request —
        nothing here is a list somebody keeps.
      </p>
      {surface.peers.length === 0 ? (
        <p>Nobody right now.</p>
      ) : (
        <ul aria-label="People you can see">
          {surface.peers.map((peer) => (
            <li key={peerKey(peer)}>
              <PeerEntry
                peer={peer}
                surface={surface}
                onOpenConversation={onOpenConversation}
              />
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

function PeerEntry({
  peer,
  surface,
  onOpenConversation,
}: {
  readonly peer: Peer;
  readonly surface: PeerSurface;
  readonly onOpenConversation: (connectionId: string) => void;
}) {
  const [asking, setAsking] = useState(false);
  const conversation =
    surface.conversations.find(
      (candidate) => candidate.peerId === peer.personId && candidate.open,
    ) ?? null;
  const pending =
    surface.outgoing.find(
      (request) =>
        request.addresseeId === peer.personId &&
        (request.state === "pending" || request.state === "lapsed"),
    ) ?? null;

  // Everything on `list_incoming_requests/1` is outstanding — the server's
  // query is narrower than the outgoing one and returns only what this person
  // can still answer — so any entry from this peer means the approach has
  // already been made, in the other direction.
  //
  // Offering "Ask … to connect" beside it was wrong twice over. The server
  // refuses it `conflict` (`:already_requested`), so the button could only ever
  // produce an error; and it reads as though the two of you have not spoken,
  // when in fact somebody is waiting on an answer a few lines further down.
  const asked =
    surface.incoming.find((request) => request.requesterId === peer.personId) ?? null;

  async function ask(): Promise<void> {
    setAsking(true);
    await surface.requestConnection(peer.personId);
    setAsking(false);
  }

  return (
    <>
      <strong>
        {peer.displayName} · {shortId(peer.personId)}
      </strong>{" "}
      <span>
        {peer.roleLabel} at {peer.venueName}
      </span>{" "}
      <span>
        visible until <time dateTime={peer.visibleUntil}>{peer.visibleUntil}</time>
      </span>{" "}
      {conversation !== null ? (
        <button
          type="button"
          onClick={() => {
            onOpenConversation(conversation.connectionId);
          }}
        >
          Open conversation with {peer.displayName}
        </button>
      ) : asked !== null ? (
        // Its own sentence rather than `requestStateLabel`, which names the
        // state of a request *this person sent* — "Pending" beside somebody who
        // is waiting on you reads as though you are the one waiting.
        <span>They asked you to connect — answer under &ldquo;Asked you&rdquo;.</span>
      ) : pending === null ? (
        <button
          type="button"
          disabled={asking}
          onClick={() => {
            void ask();
          }}
        >
          Ask {peer.displayName} to connect
        </button>
      ) : (
        <span>{requestStateLabel(pending.state)}</span>
      )}
    </>
  );
}

function IncomingRequests({ surface }: { readonly surface: PeerSurface }) {
  return (
    <>
      <h2>Asked you</h2>
      {surface.incoming.length === 0 ? (
        <p>Nobody has asked you to connect.</p>
      ) : (
        <ul aria-label="Requests to you">
          {surface.incoming.map((request) => (
            <li key={request.requestId}>
              <IncomingRequest request={request} surface={surface} />
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

/**
 * One request to answer, and the two ways of answering it.
 *
 * A component of its own so that "an answer is in flight" is per request rather
 * than per surface. Both controls close while one is running, and both close
 * for **either** answer: accepting and declining are the same conditional
 * `UPDATE` on the server (`Records.answerable/2`), so the second click of a
 * double-click loses whichever it was and gets `:not_found` — the same answer a
 * request addressed to somebody else gets. That refusal is indistinguishable
 * from an id that names nothing (AE1), so the surface could not explain it if
 * it wanted to. It is cheaper not to send it.
 *
 * The controls are **not** disabled for a `lapsed` request, which they easily
 * could have been: accepting one is refused `gone`. `lapsed` is derived at the
 * instant the list was read and can go back to `pending` with nothing written,
 * so disabling on it would be this client caching a guess about the future —
 * which is the mistake `features/rooms/` had to build a "Check again" button to
 * undo. Declining is accepted at any time regardless.
 */
function IncomingRequest({
  request,
  surface,
}: {
  readonly request: PeerRequest;
  readonly surface: PeerSurface;
}) {
  const [answering, setAnswering] = useState(false);

  async function answer(reply: () => Promise<unknown>): Promise<void> {
    setAnswering(true);
    await reply();
    setAnswering(false);
  }

  return (
    <>
      <strong>{shortId(request.requesterId)}</strong>{" "}
      <span>
        asked on <time dateTime={request.requestedAt}>{request.requestedAt}</time>
      </span>{" "}
      <span>{requestStateLabel(request.state)}</span>{" "}
      {request.state === "lapsed" && <span>{requestStateMessage(request.state)}</span>}{" "}
      <button
        type="button"
        disabled={answering}
        onClick={() => {
          void answer(() => surface.acceptRequest(request.requestId));
        }}
      >
        Accept {shortId(request.requesterId)}
      </button>
      <button
        type="button"
        disabled={answering}
        onClick={() => {
          void answer(() => surface.declineRequest(request.requestId));
        }}
      >
        Decline {shortId(request.requesterId)}
      </button>
    </>
  );
}

function OutgoingRequests({ requests }: { readonly requests: readonly PeerRequest[] }) {
  return (
    <>
      <h2>You asked</h2>
      {requests.length === 0 ? (
        <p>You have not asked anybody to connect.</p>
      ) : (
        <ul aria-label="Requests you sent">
          {requests.map((request) => (
            <li key={request.requestId}>
              <strong>{shortId(request.addresseeId)}</strong>{" "}
              <span>{requestStateLabel(request.state)}</span>{" "}
              <span>{requestStateMessage(request.state)}</span>{" "}
              <time dateTime={request.requestedAt}>{request.requestedAt}</time>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

function Conversations({
  conversations,
  openId,
  onOpen,
}: {
  readonly conversations: readonly Conversation[];
  readonly openId: string | null;
  readonly onOpen: (connectionId: string) => void;
}) {
  return (
    <>
      <h2>Conversations</h2>
      <p>
        A connection is permanent: it outlives every engagement either of you holds, until
        one of you ends it. Closed ones stay listed, because each of you keeps what you
        wrote.
      </p>
      {conversations.length === 0 ? (
        <p>No conversations yet.</p>
      ) : (
        <ul aria-label="Your conversations">
          {conversations.map((conversation) => (
            <li key={conversation.connectionId}>
              <button
                type="button"
                aria-current={conversation.connectionId === openId}
                onClick={() => {
                  onOpen(conversation.connectionId);
                }}
              >
                Open conversation {shortId(conversation.peerId)}
              </button>{" "}
              <span>{conversation.open ? "Open" : "Closed"}</span>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
