defmodule HospitalityComsWeb.ShiftRoomChannel do
  @moduledoc """
  One shift's conversation, where joining and sending are different questions.

  ## Readability admits, membership sends

  U6 keeps two predicates apart and this channel is where the difference is
  visible from outside. `join/3` asks
  `HospitalityComs.Rooms.fetch_shift_room_reader/2` — a roster period that
  *overlapped* the room's open window, intersected with an engagement active
  now. `handle_in("send", …)` asks
  `HospitalityComs.Rooms.send_shift_room_message/3`, which additionally wants
  the room to be open at this instant and the sender to be rostered at it.

  So somebody removed from the roster an hour ago joins, reads everything, and
  is refused when they send — which is KTD6b's non-retroactivity as a transport
  behaviour: no write can withdraw access that a period has already earned.

  ## The grace window closes writes on a channel that is already open (KTD5)

  This is the demo's flagship beat and the reason the instant is per inbound
  event. A client joins at 22:00, the room's `closes_at` passes at 23:30, and
  the send at 23:31 is refused `room_closed` — on the same channel process,
  with no rejoin, no broadcast and **no job having run**. An instant stamped at
  join would have authorised it.

  ## The refusals

  `:not_found` covers a room that does not exist, a room at a venue this person
  holds no engagement at, and a room they were never rostered on — identically,
  because the caller supplies the id and enumerating a venue's shift history one
  join at a time is the leak U6's review found and closed on the send path.
  `:room_closed` and `:not_rostered` are only ever said about a room inside the
  caller's own venues, where they tell them nothing their venue's published
  shift times do not.

  ## What this file no longer says twice

  Presence, the terminal push-and-stop, message rendering and the two
  crash-proofing clauses are `HospitalityComsWeb.RoomChannel`'s — see
  `HospitalityComsWeb.VenueRoomChannel`. What stays here is `join/3` and the
  send path, because readability and membership being different questions is
  the one thing this file exists to say.
  """

  use HospitalityComsWeb, :channel

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.PubSub
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.RoomChannel
  alias Phoenix.Socket

  @unreadable "this session cannot read that shift room"
  @closed "that shift room is closed to new messages"
  @not_rostered "this session is not on that shift's roster"

  @doc """
  Joins a shift room, if this session may read it at this instant.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  def join("shift_room:" <> shift_room_id, _payload, socket) do
    scope = ChannelAuth.person_scope(socket)

    scope
    |> Rooms.fetch_shift_room_reader(shift_room_id)
    |> admit(scope, shift_room_id, socket)
  end

  @spec admit(
          {:ok, Engagement.t()} | {:error, :not_found},
          PersonScope.t(),
          Ecto.UUID.t(),
          Socket.t()
        ) :: {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp admit({:ok, %Engagement{} = engagement}, scope, shift_room_id, socket) do
    :ok = PubSub.subscribe(scope, {:engagement, engagement.id})
    send(self(), :after_join)

    {:ok, %{shift_room_id: shift_room_id, engagement_id: engagement.id},
     assign(socket, engagement: engagement, shift_room_id: shift_room_id)}
  end

  defp admit({:error, :not_found}, _scope, _shift_room_id, _socket) do
    {:error, ErrorEnvelope.new(:unauthorized, @unreadable)}
  end

  @doc """
  Sends a message to the room, authorised at the instant it arrives.
  """
  @impl true
  @spec handle_in(String.t(), map(), Socket.t()) :: {:reply, RoomChannel.reply(), Socket.t()}
  def handle_in("send", %{"body" => body}, socket) when is_binary(body) do
    scope = ChannelAuth.person_scope(socket)

    scope
    |> Rooms.send_shift_room_message(socket.assigns.shift_room_id, body)
    |> sent(socket)
  end

  def handle_in("send", _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, "body is required")}, socket}
  end

  def handle_in(_event, _payload, socket), do: RoomChannel.unknown_event(socket)

  @spec sent(
          {:ok, RoomMessage.t()}
          | {:error, Rooms.refusal() | :not_rostered | Ecto.Changeset.t(RoomMessage.t())},
          Socket.t()
        ) :: {:reply, RoomChannel.reply(), Socket.t()}
  defp sent({:ok, %RoomMessage{} = message}, socket) do
    rendered = RoomChannel.rendered(message)
    broadcast!(socket, "message", rendered)
    {:reply, {:ok, rendered}, socket}
  end

  defp sent({:error, :room_closed}, socket) do
    {:reply, {:error, ErrorEnvelope.new(:gone, @closed)}, socket}
  end

  defp sent({:error, :not_rostered}, socket) do
    {:reply, {:error, ErrorEnvelope.new(:forbidden, @not_rostered)}, socket}
  end

  # `:not_found` and `:not_a_member` both mean the room is out of this session's
  # reach entirely, and both get the same answer the join would have given.
  defp sent({:error, refusal}, socket) when refusal in [:not_found, :not_a_member] do
    {:reply, {:error, ErrorEnvelope.new(:unauthorized, @unreadable)}, socket}
  end

  defp sent({:error, %Ecto.Changeset{} = changeset}, socket) do
    envelope =
      ErrorEnvelope.for_changeset(:unprocessable_entity, "the message was rejected", changeset)

    {:reply, {:error, envelope}, socket}
  end

  @doc """
  Tracks the joiner's presence, and stops the channel when its engagement ends.
  """
  @impl true
  @spec handle_info(term(), Socket.t()) ::
          {:noreply, Socket.t()} | {:stop, {:shutdown, :revoked}, Socket.t()}
  def handle_info(:after_join, socket), do: RoomChannel.joined(socket)

  def handle_info({:engagement_revoked, %{engagement_id: engagement_id} = revocation}, socket) do
    RoomChannel.closed(
      engagement_id == socket.assigns.engagement.id,
      revocation_closure(socket),
      revocation,
      socket
    )
  end

  def handle_info(_message, socket), do: RoomChannel.ignored(socket)

  @spec revocation_closure(Socket.t()) :: RoomChannel.closure()
  defp revocation_closure(socket) do
    %{
      event: "access_revoked",
      reason: :revoked,
      room: %{shift_room_id: socket.assigns.shift_room_id}
    }
  end
end
