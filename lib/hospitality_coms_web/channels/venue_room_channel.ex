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

  ## The window between the read and the subscription, and why it is left open

  `join/3` reads membership and *then* subscribes, because the topic is derived
  from the engagement the read returns. A revocation committing in between
  broadcasts to nobody: this channel is admitted and never hears about it. The
  window is the gap between two adjacent statements.

  It is recorded rather than closed, and the reasons are in this order.

  **A same-instant reread would close nothing.** `end_engagement/2` stamps
  `ends_at` at the *employer's* instant, and the only way this join saw the
  engagement as active is that its own instant precedes it. Asking the same
  question at the same instant gets the same answer. Closing the window needs a
  second `Clock.now()` inside one join, which is in direct tension with KTD5 —
  one instant per unit of work is the rule most of this design rests on, and
  spending it here buys a sub-millisecond window.

  **The residue is bounded at one sweep interval, not for ever.**
  `HospitalityComs.Workers.EngagementSweeper` finds the closed term inside its
  24h lookback and enqueues the same announcement; the channel *is* subscribed
  by then, so the second announcement is the one it hears.
  `end_engagement/2` rewrites `ends_at`, which is one of
  `HospitalityComs.Workers.ExpireEngagement`'s uniqueness args, so that insert
  does not collide with the job scheduled for the original bound.
  `HospitalityComsWeb.RevocationTest` asserts that chain end to end.

  **And it cannot be tested deterministically.** A fix for a race between two
  adjacent statements, with no test that fails without it, is one refactor from
  being removed by somebody who cannot see what it was for.

  The one thing the sweeper does not bound is a suspension nudge lost the same
  way, because nothing sweeps suspensions. That leaks to the person who opted
  out and to nobody else, and they can close it themselves by resuming and
  suspending again.

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

  ## What this file no longer says twice

  The after-join presence track, the terminal push-and-stop, the wire rendering
  of a message, and the two clauses that stop a channel crashing on an event or
  a message it was not written for are all
  `HospitalityComsWeb.RoomChannel`'s. This channel and
  `HospitalityComsWeb.ShiftRoomChannel` differ in exactly one value there — the
  key a payload names the room by — and it is passed as `t:RoomChannel.closure/0`'s
  `:room` rather than written out in both files. What stays here is `join/3`
  and the send path, which are where the two channels differ in substance.
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

  # One sentence for every way a join or a send can be refused about a room the
  # caller named. Saying more would say whether the venue exists.
  @refusal "this session is not in that venue's room"

  @doc """
  Joins a venue's room, if this session is in it at this instant.
  """
  @impl true
  @spec join(String.t(), map(), Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  def join("venue_room:" <> suffix, _payload, socket) do
    suffix |> ChannelAuth.topic_id() |> resolve(socket)
  end

  # A suffix that is not a uuid answers exactly what an unknown venue answers.
  # Telling them apart would say that the caller's input was *shaped* wrong,
  # which is one bit more than AE1 permits about an id the caller supplied — and
  # before this it did not even do that: it raised `Ecto.Query.CastError` out of
  # `join/3` and the transport reported a crash.
  @spec resolve({:ok, Ecto.UUID.t()} | :error, Socket.t()) ::
          {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp resolve(:error, _socket), do: refuse()

  defp resolve({:ok, venue_id}, socket) do
    socket |> ChannelAuth.join_scope() |> authorize(venue_id, socket)
  end

  # The session is derived again here, not taken from the socket: a token
  # deleted or expired since `connect/3` refuses the join with the same sentence
  # an ended engagement gets, so the socket cannot outlive its credential.
  @spec authorize(
          {:ok, PersonScope.t()} | {:error, :no_session},
          Ecto.UUID.t(),
          Socket.t()
        ) :: {:ok, map(), Socket.t()} | {:error, ErrorEnvelope.t()}
  defp authorize({:error, :no_session}, _venue_id, _socket), do: refuse()

  defp authorize({:ok, scope}, venue_id, socket) do
    scope
    |> Rooms.fetch_venue_room_membership(venue_id)
    |> admit(scope, venue_id, socket)
  end

  @spec refuse() :: {:error, ErrorEnvelope.t()}
  defp refuse, do: {:error, ErrorEnvelope.new(:unauthorized, @refusal)}

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

  defp admit({:error, :not_a_member}, _scope, _venue_id, _socket), do: refuse()

  @doc """
  Sends a message to the room, authorised at the instant it arrives.
  """
  @impl true
  @spec handle_in(String.t(), map(), Socket.t()) :: {:reply, RoomChannel.reply(), Socket.t()}
  def handle_in("send", %{"body" => body}, socket) when is_binary(body) do
    scope = ChannelAuth.person_scope(socket)

    scope
    |> Rooms.send_venue_room_message(socket.assigns.venue_id, body)
    |> sent(socket)
  end

  def handle_in("send", _payload, socket) do
    {:reply, {:error, ErrorEnvelope.new(:bad_request, "body is required")}, socket}
  end

  def handle_in(_event, _payload, socket), do: RoomChannel.unknown_event(socket)

  @spec sent(
          {:ok, RoomMessage.t()}
          | {:error, :not_a_member | :room_closed | Ecto.Changeset.t(RoomMessage.t())},
          Socket.t()
        ) :: {:reply, RoomChannel.reply(), Socket.t()}
  defp sent({:ok, %RoomMessage{} = message}, socket) do
    rendered = RoomChannel.rendered(message)
    broadcast!(socket, "message", rendered)
    {:reply, {:ok, rendered}, socket}
  end

  # A venue that has been closed and a session that is not in its room get the
  # same sentence, for AE1's reason one layer up: which of the two it is says
  # whether that venue is still trading, and a session already refused has no
  # claim on the answer.
  defp sent({:error, refusal}, socket) when refusal in [:not_a_member, :room_closed] do
    {:reply, {:error, ErrorEnvelope.new(:unauthorized, @refusal)}, socket}
  end

  defp sent({:error, %Ecto.Changeset{} = changeset}, socket) do
    envelope =
      ErrorEnvelope.for_changeset(:unprocessable_entity, "the message was rejected", changeset)

    {:reply, {:error, envelope}, socket}
  end

  @doc """
  Tracks the joiner's presence, and stops the channel when its access ends.

  Two ways it ends, and they are told apart on the wire because they mean
  opposite things to whoever is reading the client: `"access_revoked"` is the
  employer closing a term, `"access_suspended"` is this person opting out of
  this room (KTD18) — possibly from another device, which is why the channel
  hears about it at all.
  """
  @impl true
  @spec handle_info(term(), Socket.t()) ::
          {:noreply, Socket.t()} | {:stop, {:shutdown, :revoked | :suspended}, Socket.t()}
  def handle_info(:after_join, socket), do: RoomChannel.joined(socket)

  def handle_info({:engagement_revoked, %{engagement_id: engagement_id} = revocation}, socket) do
    RoomChannel.closed(
      engagement_id == socket.assigns.engagement.id,
      revocation_closure(socket),
      revocation,
      socket
    )
  end

  def handle_info({:venue_room_suspended, %{engagement_id: engagement_id} = notice}, socket) do
    RoomChannel.closed(
      engagement_id == socket.assigns.engagement.id,
      suspension_closure(socket),
      notice,
      socket
    )
  end

  def handle_info(_message, socket), do: RoomChannel.ignored(socket)

  @spec revocation_closure(Socket.t()) :: RoomChannel.closure()
  defp revocation_closure(socket) do
    %{
      event: "access_revoked",
      reason: :revoked,
      room: %{venue_id: socket.assigns.venue_id}
    }
  end

  @spec suspension_closure(Socket.t()) :: RoomChannel.closure()
  defp suspension_closure(socket) do
    %{
      event: "access_suspended",
      reason: :suspended,
      room: %{venue_id: socket.assigns.venue_id}
    }
  end
end
