defmodule HospitalityComsWeb.VenueRoomChannel do
  @moduledoc """
  One venue's standing conversation, and the place revocation is actually
  enforced.

  ## `join/3` is the enforcement point (KTD8)

  The revocation sequence has five arrows and four of them are best effort:

      commit → broadcast → push "access_revoked" → {:stop, {:shutdown, :revoked}}
             → client auto-rejoins → join/3 re-derives → {:error, unauthorized}

  The broadcast can be lost — `HospitalityComs.Engagements` logs a failed
  announcement and carries on, deliberately, because failing to end a term in
  order to report that nobody was told is the wrong trade. The push can race the
  socket closing. The stop can be beaten by a client that reconnects first. Only
  the last arrow is load-bearing, because it is a query against a term that has
  already closed, and it answers the same way whether or not anything else ran.

  So nothing about membership is cached on the socket. Every join asks
  `HospitalityComs.Rooms.fetch_venue_room_membership/2` again, which is U6's
  predicate, which is U5's `active_at/2` minus a suspension — derived, with no
  job having run.

  ## The instant is per event, not per join (KTD5)

  A channel process lives for hours. `HospitalityComsWeb.ChannelAuth
  .person_scope/1` reads the clock at the top of `join/3` and again at the top
  of every `handle_in/3`, so a send is authorised against the moment it was
  sent. An instant stamped at join would let a message land in a room whose
  engagement ended an hour earlier, which is the one thing this transport exists
  not to do.

  ## The refusal enumerates nothing

  `join/3` answers `unauthorized` for an ended engagement, a suspension in
  force, and a venue that does not exist, identically — the caller supplies the
  venue id, so a refusal that told them the venue was real would enumerate the
  application's venues one join at a time. That is AE1's
  not-found-rather-than-forbidden rule applied where the id comes from outside.

  ## What a client is told about the room's people

  Presence entries are keyed on `engagements.id` and carry the
  employer-authored role label, never a person id and never a name. See
  `HospitalityComsWeb.Presence`.
  """

  use HospitalityComsWeb, :channel

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.PubSub
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComsWeb.ChannelAuth
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.Presence
  alias Phoenix.Socket

  # One sentence for every way a join or a send can be refused about a room the
  # caller named. Saying more would say whether the venue exists.
  @refusal "this session is not in that venue's room"

  @typedoc "What a rendered message looks like on the wire. No person id, ever."
  @type rendered() :: %{
          id: Ecto.UUID.t(),
          body: String.t(),
          sent_at: String.t(),
          author_engagement_id: Ecto.UUID.t()
        }

  @doc """
  Joins a venue's room, if this session is in it at this instant.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  def join("venue_room:" <> venue_id, _payload, socket) do
    scope = ChannelAuth.person_scope(socket)

    scope
    |> Rooms.fetch_venue_room_membership(venue_id)
    |> admit(scope, venue_id, socket)
  end

  @spec admit(
          {:ok, Engagement.t()} | {:error, :not_a_member},
          PersonScope.t(),
          Ecto.UUID.t(),
          Socket.t()
        ) :: {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp admit({:ok, %Engagement{} = engagement}, scope, venue_id, socket) do
    # Per engagement, not per person and not per venue: KTD7's reasoning one
    # layer down. A per-person revocation topic would stop this channel when the
    # *other* venue's engagement ended.
    :ok = PubSub.subscribe(scope, {:engagement, engagement.id})
    send(self(), :after_join)

    {:ok, %{venue_id: venue_id, engagement_id: engagement.id},
     assign(socket, engagement: engagement, venue_id: venue_id)}
  end

  defp admit({:error, :not_a_member}, _scope, _venue_id, _socket) do
    {:error, ErrorEnvelope.new(:unauthorized, @refusal)}
  end

  @doc """
  Sends a message to the room, authorised at the instant it arrives.
  """
  @impl true
  @spec handle_in(String.t(), map(), Socket.t()) :: {:reply, term(), Socket.t()}
  def handle_in("send", %{"body" => body}, socket) when is_binary(body) do
    scope = ChannelAuth.person_scope(socket)

    scope
    |> Rooms.send_venue_room_message(socket.assigns.venue_id, body)
    |> sent(socket)
  end

  def handle_in("send", _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, "body is required")}, socket}
  end

  @spec sent(
          {:ok, RoomMessage.t()} | {:error, :not_a_member | Ecto.Changeset.t(RoomMessage.t())},
          Socket.t()
        ) :: {:reply, term(), Socket.t()}
  defp sent({:ok, %RoomMessage{} = message}, socket) do
    rendered = render(message)
    broadcast!(socket, "message", rendered)
    {:reply, {:ok, rendered}, socket}
  end

  defp sent({:error, :not_a_member}, socket) do
    {:reply, {:error, ErrorEnvelope.new(:unauthorized, @refusal)}, socket}
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
  def handle_info(:after_join, socket) do
    scope = ChannelAuth.person_scope(socket)
    {:ok, _ref} = Presence.track_engagement(socket, socket.assigns.engagement, scope.now)
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  def handle_info({:engagement_revoked, %{engagement_id: engagement_id} = revocation}, socket) do
    revoke(engagement_id == socket.assigns.engagement.id, revocation, socket)
  end

  # The nudge, not the revocation. No `Presence.untrack/2` call: the tracker
  # monitors this process, so the stop *is* the leave, and an explicit untrack
  # before it would only be a second way to say the same thing — one that would
  # go missing if the channel died for any other reason.
  @spec revoke(boolean(), map(), Socket.t()) ::
          {:noreply, Socket.t()} | {:stop, {:shutdown, :revoked}, Socket.t()}
  defp revoke(true, revocation, socket) do
    push(socket, "access_revoked", %{
      venue_id: socket.assigns.venue_id,
      engagement_id: revocation.engagement_id,
      at: DateTime.to_iso8601(revocation.at)
    })

    {:stop, {:shutdown, :revoked}, socket}
  end

  # Another engagement's revocation, which this channel is not about. It cannot
  # arrive today — the subscription is per engagement — and ignoring it is what
  # keeps that true rather than assumed.
  defp revoke(false, _revocation, socket), do: {:noreply, socket}

  @spec render(RoomMessage.t()) :: rendered()
  defp render(%RoomMessage{} = message) do
    %{
      id: message.id,
      body: message.body,
      sent_at: DateTime.to_iso8601(message.sent_at),
      author_engagement_id: message.author_engagement_id
    }
  end
end
