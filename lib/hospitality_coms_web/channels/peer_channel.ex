defmodule HospitalityComsWeb.PeerChannel do
  @moduledoc """
  Every one of this person's peer conversations, on one channel (KTD10).

  ## One channel, not one per conversation

  `"peer"` is an exact topic and carries the whole peer surface for this person:
  who they can see, what they have been asked, what they have asked, every
  conversation, and every message in every one of them. **Every event names its
  conversation in the payload and never in the topic**, which is what makes that
  possible and what stops a per-conversation topic name existing for a later
  unit to copy into an employer socket's routing table by accident.

  `max_channels_per_transport` is at Phoenix's default of 100, and a worker with
  engagements at three venues is already holding a venue room and several shift
  rooms at each before a conversation is opened. `HospitalityComsWeb.Endpoint`
  writes out where the real bound is and who can exceed it; what this file
  contributes is that conversations are not part of the count.

  ## The topic is the same string for everybody, and that matters

  `"peer"` has no suffix, so **every person's peer channel is subscribed to the
  same Phoenix topic** — `Phoenix.Channel.Server` subscribes each joined channel
  to its own topic, and here that is one shared group. A `broadcast/3` or
  `broadcast!/3` from this channel would therefore deliver to every peer channel
  in the cluster, which is a disclosure of everybody's conversations to
  everybody.

  So there is not one in this file and there must never be one. All fan-out goes
  through `HospitalityComs.Peers`, which publishes on
  `HospitalityComs.PubSub.topic({:peer, person_id})` — a topic per person — and
  `join/3` subscribes this channel to its own and to nothing else, with
  `HospitalityComs.PubSub.subscribe/2` pinning the id to the scope in its
  function head so a channel cannot subscribe to anybody else's even if a caller
  tried.

  ## The instant is per event (KTD5)

  `HospitalityComsWeb.ChannelAuth.person_scope/1` reads the clock at the top of
  every `handle_in/3`, exactly as the room channels do. A channel joined this
  morning has this afternoon's request refused against this afternoon's
  visibility, on the same process, with no rejoin and no job.

  Unlike the room channels, `join/3` authorises nothing beyond the session:
  there is no membership behind `"peer"` to check. **Every event authorises
  itself**, in the context, against the caller's own person id — which is the
  only shape that could work here, because one channel carries conversations
  with different people that were opened and closed at different times.

  ## Ids in payloads are user input

  Every one goes through `HospitalityComsWeb.ChannelAuth.topic_id/1` before it
  reaches a context, for the reason that function's docstring gives: uncast, it
  reaches Ecto's query builder and raises `Ecto.Query.CastError`, which the
  transport reports as a crash — so a caller could tell a malformed id from an
  unknown one by which answer they got, which is AE1 lost at the one place the
  id comes from outside.

  ## What a refusal says

  `:not_found` for a person who is not among the caller's peers, a request or a
  connection between two other people, and an id that names nothing —
  identically. The three refusals that say more (`already_requested`,
  `already_connected`, `blocked`) are all statements about something the caller
  was party to, so they disclose nothing they did not already have.
  """

  use HospitalityComsWeb, :channel

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.Conversation
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Peers.Visibility
  alias HospitalityComs.PubSub
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.RoomChannel
  alias Phoenix.Socket

  @refusal "this session is not live"
  @unknown "no such peer, request, or conversation"

  @typedoc """
  What this channel replies to an inbound event with.

  Spelled out rather than left as `term()`, because the union is the contract
  U12's client is written against.
  """
  @type reply() ::
          {:ok, map()} | {:error, ErrorEnvelope.t() | ErrorEnvelope.with_fields()}

  @doc """
  Joins this person's peer surface, if the session is still live.

  The session is derived again here rather than taken from the socket, which is
  what stops a socket outliving the token it connected with — see
  `HospitalityComsWeb.ChannelAuth`. This topic needs it as much as the room
  topics do and has less to fall back on: there is no membership behind `"peer"`
  to refuse a stale session on its way past.

  An anonymous scope is refused by function clause on top of that.
  `PersonSocket.connect/3` cannot produce one, so the clause is the belt to that
  brace.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  def join("peer", _payload, socket) do
    socket |> ChannelAuth.join_scope() |> admit(socket)
  end

  @spec admit({:ok, PersonScope.t()} | {:error, :no_session}, Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp admit({:ok, %PersonScope{person: %Person{id: person_id}} = scope}, socket) do
    :ok = PubSub.subscribe(scope, {:peer, person_id})

    {:ok, %{person_id: person_id}, socket}
  end

  defp admit({:error, :no_session}, _socket) do
    {:error, ErrorEnvelope.new(:unauthorized, @refusal)}
  end

  @doc """
  Answers one inbound event, authorised at the instant it arrives.

  Nine events and a terminal clause. The terminal one is not optional:
  `Phoenix.Channel.Server` dispatches to `handle_in/3` unconditionally, so a
  channel without it crashes on every event a client can invent.
  """
  @impl true
  @spec handle_in(String.t(), map(), Socket.t()) :: {:reply, reply(), Socket.t()}
  def handle_in("list_peers", _payload, socket) do
    peers = socket |> ChannelAuth.person_scope() |> Peers.list_visible_peers()

    {:reply, {:ok, %{peers: Enum.map(peers, &rendered_peer/1)}}, socket}
  end

  def handle_in("list_conversations", _payload, socket) do
    conversations = socket |> ChannelAuth.person_scope() |> Peers.list_conversations()

    {:reply, {:ok, %{conversations: Enum.map(conversations, &rendered_conversation/1)}}, socket}
  end

  def handle_in("list_requests", _payload, socket) do
    scope = ChannelAuth.person_scope(socket)

    reply = %{
      incoming: scope |> Peers.list_incoming_requests() |> Enum.map(&rendered_request/1),
      outgoing: scope |> Peers.list_outgoing_requests() |> Enum.map(&rendered_request/1)
    }

    {:reply, {:ok, reply}, socket}
  end

  def handle_in("request", %{"person_id" => person_id}, socket) when is_binary(person_id) do
    with_id(person_id, socket, fn scope, id ->
      scope |> Peers.request_connection(id) |> answered_with(&rendered_request/1)
    end)
  end

  def handle_in("accept", %{"request_id" => request_id}, socket) when is_binary(request_id) do
    with_id(request_id, socket, fn scope, id ->
      scope |> Peers.accept_request(id) |> connected(scope)
    end)
  end

  def handle_in("decline", %{"request_id" => request_id}, socket) when is_binary(request_id) do
    with_id(request_id, socket, fn scope, id ->
      scope |> Peers.decline_request(id) |> answered_with(&rendered_request/1)
    end)
  end

  def handle_in("history", %{"connection_id" => connection_id}, socket)
      when is_binary(connection_id) do
    with_id(connection_id, socket, fn scope, id ->
      scope |> Peers.list_messages(id) |> history()
    end)
  end

  def handle_in("send", %{"connection_id" => connection_id, "body" => body}, socket)
      when is_binary(connection_id) and is_binary(body) do
    with_id(connection_id, socket, fn scope, id ->
      scope |> Peers.send_message(id, body) |> answered_with(&rendered_message/1)
    end)
  end

  def handle_in("disconnect", %{"connection_id" => connection_id}, socket)
      when is_binary(connection_id) do
    with_id(connection_id, socket, fn scope, id ->
      scope |> Peers.disconnect(id) |> answered_with(&rendered_connection(&1, scope))
    end)
  end

  def handle_in(event, _payload, socket) when event in ~w(request accept decline history
                                                          send disconnect) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, "that event needs an id")}, socket}
  end

  def handle_in(_event, _payload, socket), do: RoomChannel.unknown_event(socket)

  # Every id a client supplies goes through the same cast, and a malformed one
  # gets exactly what an unknown one gets. See the moduledoc.
  @spec with_id(String.t(), Socket.t(), (PersonScope.t(), Ecto.UUID.t() -> reply())) ::
          {:reply, reply(), Socket.t()}
  defp with_id(raw, socket, work) do
    scope = ChannelAuth.person_scope(socket)

    raw |> ChannelAuth.topic_id() |> resolved(scope, work) |> replied(socket)
  end

  @spec resolved(
          {:ok, Ecto.UUID.t()} | :error,
          PersonScope.t(),
          (PersonScope.t(), Ecto.UUID.t() -> reply())
        ) :: reply()
  defp resolved(:error, _scope, _work), do: {:error, ErrorEnvelope.new(:not_found, @unknown)}
  defp resolved({:ok, id}, scope, work), do: work.(scope, id)

  @spec replied(reply(), Socket.t()) :: {:reply, reply(), Socket.t()}
  defp replied(answer, socket), do: {:reply, answer, socket}

  ## Turning a context answer into a reply

  @spec answered_with({:ok, term()} | tuple(), (term() -> map())) :: reply()
  defp answered_with({:ok, record}, render), do: {:ok, render.(record)}
  defp answered_with(failure, _render), do: refused(failure)

  @spec connected({:ok, Connection.t()} | Peers.acceptance_failure(), PersonScope.t()) ::
          reply()
  defp connected({:ok, %Connection{} = connection}, scope) do
    {:ok, rendered_connection(connection, scope)}
  end

  defp connected(failure, _scope), do: refused(failure)

  @spec history({:ok, [PeerMessage.t()]} | {:error, :not_found}) :: reply()
  defp history({:ok, messages}), do: {:ok, %{messages: Enum.map(messages, &rendered_message/1)}}
  defp history({:error, :not_found} = failure), do: refused(failure)

  # Both failure shapes in one place: the flat `{:error, reason}` a single-write
  # function gives, and the `{:error, step, reason, changes}` an `Ecto.Multi`
  # gives. The step is dropped on the wire and kept in the tuple the context
  # returns — a client has no use for the name of a transaction step, and a
  # caller in Elixir does.
  @spec refused(tuple()) :: {:error, ErrorEnvelope.t() | ErrorEnvelope.with_fields()}
  defp refused({:error, _step, reason, _changes}), do: refused({:error, reason})
  defp refused({:error, :not_found}), do: {:error, ErrorEnvelope.new(:not_found, @unknown)}
  defp refused({:error, :not_visible}), do: {:error, ErrorEnvelope.new(:not_found, @unknown)}

  defp refused({:error, :lapsed}) do
    {:error, ErrorEnvelope.new(:gone, "that request lapsed when you stopped working together")}
  end

  defp refused({:error, :blocked}) do
    {:error, ErrorEnvelope.new(:forbidden, "they have to be the one to ask")}
  end

  defp refused({:error, :already_requested}) do
    {:error, ErrorEnvelope.new(:conflict, "a request between you two is already outstanding")}
  end

  defp refused({:error, :already_connected}) do
    {:error, ErrorEnvelope.new(:conflict, "you are already connected")}
  end

  defp refused({:error, :already_disconnected}) do
    {:error, ErrorEnvelope.new(:conflict, "that conversation is already closed")}
  end

  defp refused({:error, :disconnected}) do
    {:error, ErrorEnvelope.new(:conflict, "that conversation is closed")}
  end

  defp refused({:error, %Ecto.Changeset{} = changeset}) do
    {:error, ErrorEnvelope.for_changeset(:unprocessable_entity, "that was rejected", changeset)}
  end

  ## What arrives from the person's own peer topic

  @doc """
  Pushes what happened on this person's peer surface, wherever it happened.

  Five shapes, all published by `HospitalityComs.Peers` on **this person's own**
  topic — never on the channel topic, which is shared by every peer channel in
  the cluster (see the moduledoc).

  The channel does not stop on a disconnect, and that is multiplexing being the
  point rather than an oversight: one conversation closing must leave the other
  conversations on this topic working. A room channel stops because the topic
  *is* the room; here the topic is the person.

  The catch-all is `HospitalityComsWeb.RoomChannel.ignored/1`. Exporting
  `handle_info/2` at all opts out of Phoenix's warn-and-ignore fallback, so this
  puts it back.
  """
  @impl true
  @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_info({:peer_request, notice}, socket) do
    push(socket, "peer_request", stamped(notice))
    {:noreply, socket}
  end

  def handle_info({:peer_request_declined, notice}, socket) do
    push(socket, "peer_request_declined", stamped(notice))
    {:noreply, socket}
  end

  def handle_info({:peer_connected, notice}, socket) do
    push(socket, "peer_connected", peered(notice, socket))
    {:noreply, socket}
  end

  def handle_info({:peer_disconnected, notice}, socket) do
    push(socket, "peer_disconnected", stamped(notice))
    {:noreply, socket}
  end

  def handle_info({:peer_message, notice}, socket) do
    push(socket, "peer_message", stamped(notice))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: RoomChannel.ignored(socket)

  @spec stamped(map()) :: map()
  defp stamped(%{at: %DateTime{} = at} = notice), do: %{notice | at: DateTime.to_iso8601(at)}

  # A connection announcement names both parties, because one broadcast serves
  # both of them. Which one is the *peer* depends on who is reading, so it is
  # resolved here rather than published twice with different payloads.
  @spec peered(map(), Socket.t()) :: map()
  defp peered(notice, %Socket{assigns: %{person_id: person_id}}) do
    notice
    |> stamped()
    |> Map.put(:peer_id, counterpart(notice, person_id))
    |> Map.drop([:person_a_id, :person_b_id])
  end

  @spec counterpart(map(), Ecto.UUID.t()) :: Ecto.UUID.t()
  defp counterpart(%{person_a_id: person_id, person_b_id: other}, person_id), do: other
  defp counterpart(%{person_b_id: person_id, person_a_id: other}, person_id), do: other

  ## Rendering

  @spec rendered_peer(Visibility.t()) :: map()
  defp rendered_peer(%Visibility{} = visibility) do
    %{
      person_id: visibility.person_id,
      venue_id: visibility.venue_id,
      venue_name: visibility.venue_name,
      role_label: visibility.role_label,
      visible_from: DateTime.to_iso8601(visibility.visible_from),
      visible_until: DateTime.to_iso8601(visibility.visible_until)
    }
  end

  @spec rendered_conversation(Conversation.t()) :: map()
  defp rendered_conversation(%Conversation{} = conversation) do
    %{
      connection_id: conversation.connection_id,
      peer_id: conversation.peer_id,
      connected_at: DateTime.to_iso8601(conversation.connected_at),
      disconnected_at: iso8601(conversation.disconnected_at),
      disconnected_by_id: conversation.disconnected_by_id,
      open: conversation.open?
    }
  end

  @spec rendered_connection(Connection.t(), PersonScope.t()) :: map()
  defp rendered_connection(%Connection{} = connection, %PersonScope{person: %Person{id: id}}) do
    connection |> Conversation.of_connection(id) |> rendered_conversation()
  end

  @spec rendered_request(ConnectionRequest.t()) :: map()
  defp rendered_request(%ConnectionRequest{} = request) do
    %{
      request_id: request.id,
      requester_id: request.requester_id,
      addressee_id: request.addressee_id,
      state: request.state,
      requested_at: DateTime.to_iso8601(request.requested_at)
    }
  end

  @spec rendered_message(PeerMessage.t()) :: map()
  defp rendered_message(%PeerMessage{} = message) do
    %{
      id: message.id,
      connection_id: message.connection_id,
      author_id: message.author_id,
      body: message.body,
      sent_at: DateTime.to_iso8601(message.sent_at)
    }
  end

  @spec iso8601(DateTime.t() | nil) :: String.t() | nil
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
