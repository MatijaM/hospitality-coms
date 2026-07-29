defmodule HospitalityComsWeb.RoomController do
  @moduledoc """
  The three things a worker needs before a room channel is any use to them: the
  rooms they are in, the rooms they may read at a venue, and what was already
  said in one.

  ## Why these are HTTP and not channel events

  Two of the three are lists you need **before you have a room to ask through**.
  A venue-room list cannot live on `venue_room:<id>` without a chicken and an
  egg, and a shift-room list cannot live on `shift_room:<id>` for the same
  reason. The third could have been a `"history"` event and is here anyway, so
  that a client fetches a room's past once, on its own schedule, rather than
  making the join reply grow.

  None of them is a live stream. `HospitalityComsWeb.VenueRoomChannel` and
  `ShiftRoomChannel` are still the whole of the realtime surface, and nothing
  here duplicates an event either of them handles.

  ## The four routes, and the one that is deliberately not nested under a room

      GET /api/venue-rooms                         the venue rooms this person is in
      GET /api/venue-rooms/:venue_id/messages      that room's history
      GET /api/venues/:venue_id/shift-rooms        the shift rooms they may read there
      GET /api/shift-rooms/:id/messages            that room's history

  The shift-room list hangs off `/api/venues/:venue_id`, **not** off
  `/api/venue-rooms/:venue_id`, and that is KTD18 rather than taste. A suspended
  person is out of the venue room and still on their shift rosters — suspension
  governs the venue room alone. A path nested under the venue room would invite
  a membership gate in front of it, and that gate would quietly extend
  suspension to shift rooms. Nesting under the *venue* names the thing shift
  rooms actually belong to (`shift_rooms.venue_id`) and leaves the authorisation
  where the context put it: a roster period overlapping the room's open window,
  intersected with an engagement active now.

  There is no `GET /api/venues`, and a nested collection does not need its
  parent collection to be routable. A person's list of venues *is* the
  venue-room list, which is the first route.

  ## `?extent=all` is the whole of the paging vocabulary

  Absent, or `recent`, is `HospitalityComs.Rooms.recent_message_limit/0`
  messages. `all` is the room's whole history. **There is no `limit`
  parameter and there must not be one**: the bound belongs to
  `HospitalityComs.Rooms`, because a route passing a number leaves the unbounded
  read one forgetful caller away from production, which is how both history
  functions came to be unbounded in the first place.

  Any other value is `400` rather than a silent fall back to `recent`. A client
  sending a word this server does not know is a client bug, and swallowing it
  hides the bug at the only place that can see it.

  ## Every refusal is `404`, and that is AE1 on the transport

  `Rooms` answers `:not_a_member` for an ended engagement, a suspension in force
  and a venue that does not exist *identically*, and `:not_found` for a shift
  room that does not exist and one this person was never rostered on
  *identically*. Both become `404` with one sentence. A `403` would confirm the
  room exists, which is precisely the distinction the contexts decline to make.

  A malformed id in a path gets the same `404`. Handed to a context uncast it
  raises `Ecto.Query.CastError` and Phoenix renders `500`, so the status alone
  would tell a caller malformed from unknown — see `HospitalityComsWeb.EntityId`.

  ## Nothing rendered here names a person

  `render_message/1` is `HospitalityComsWeb.RoomChannel.rendered/1`, reused
  rather than respelled: attribution is the **engagement** (KTD15b), which is
  venue-local by construction, and a second spelling of a message shape is how
  the two come to disagree about which fields exist. `CLAUDE.md` records
  `Rooms.list_venue_room_members/2` handing out `person_id` as a live
  disclosure; this unit adds no second instance, and renders no engagement at
  all.

  ## The rate limiter is not extended to these routes

  `HospitalityComsWeb.LoginRateLimit` sits in front of `POST /api/log-in` alone
  because that is "the only endpoint an anonymous caller can use to write a row
  and send an email" — the router's own words. All four routes here require a
  live session and write nothing, and their cost is bounded by the bound this
  module's history reads apply. Considered, and deliberately not added.
  """

  use HospitalityComsWeb, :controller

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.MessagePage
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.VenueRoom
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComsWeb.EntityId
  alias HospitalityComsWeb.ErrorEnvelope
  alias HospitalityComsWeb.RoomChannel

  @no_room "no such room, or it is not one you can reach"
  @bad_extent ~s(extent must be "recent" or "all")

  @doc """
  The venue rooms this person is in at the request's instant.
  """
  @spec venue_rooms(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def venue_rooms(conn, _params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    json(conn, %{venue_rooms: Enum.map(Rooms.list_venue_rooms(scope), &render_venue_room/1)})
  end

  @doc """
  A venue room's messages, bounded unless `extent=all`.
  """
  @spec venue_room_messages(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def venue_room_messages(conn, %{"venue_id" => venue_id} = params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(venue_id),
         {:ok, extent} <- extent(params) do
      scope
      |> Rooms.list_venue_room_messages(id, extent)
      |> respond_with_page(conn)
    else
      :error -> not_found(conn)
      {:error, :bad_extent} -> bad_extent(conn)
    end
  end

  @doc """
  The shift rooms this person may read at one venue, earliest first.

  A venue they hold no engagement at answers `[]` rather than a refusal: the
  list's authorisation is the roster overlap, so an empty list for a venue with
  no rooms and for a venue that is not theirs are the same answer.
  """
  @spec shift_rooms(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def shift_rooms(conn, %{"venue_id" => venue_id}) do
    %PersonScope{} = scope = conn.assigns.current_scope

    case EntityId.cast(venue_id) do
      {:ok, id} ->
        rooms = Rooms.list_readable_shift_rooms(scope, id)
        json(conn, %{shift_rooms: Enum.map(rooms, &render_shift_room/1)})

      :error ->
        not_found(conn)
    end
  end

  @doc """
  A shift room's messages, bounded unless `extent=all`.
  """
  @spec shift_room_messages(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def shift_room_messages(conn, %{"shift_room_id" => shift_room_id} = params) do
    %PersonScope{} = scope = conn.assigns.current_scope

    with {:ok, id} <- EntityId.cast(shift_room_id),
         {:ok, extent} <- extent(params) do
      scope
      |> Rooms.list_shift_room_messages(id, extent)
      |> respond_with_page(conn)
    else
      :error -> not_found(conn)
      {:error, :bad_extent} -> bad_extent(conn)
    end
  end

  # `:not_a_member` and `:not_found` are one answer here. See the moduledoc.
  @spec respond_with_page(
          {:ok, MessagePage.t()} | {:error, :not_a_member | :not_found},
          Plug.Conn.t()
        ) :: Plug.Conn.t()
  defp respond_with_page({:ok, %MessagePage{} = page}, conn) do
    json(conn, %{
      messages: Enum.map(page.messages, &render_message/1),
      complete: page.complete
    })
  end

  defp respond_with_page({:error, _refusal}, conn), do: not_found(conn)

  # Enumerated rather than defaulted, so an unknown word is a refusal and not a
  # silently different answer.
  @spec extent(map()) :: {:ok, MessagePage.extent()} | {:error, :bad_extent}
  defp extent(%{"extent" => "all"}), do: {:ok, :all}
  defp extent(%{"extent" => "recent"}), do: {:ok, :recent}
  defp extent(%{"extent" => _other}), do: {:error, :bad_extent}
  defp extent(_params), do: {:ok, :recent}

  @spec render_venue_room(VenueRoom.t()) :: %{venue_id: Ecto.UUID.t(), name: String.t()}
  defp render_venue_room(%VenueRoom{} = room) do
    %{venue_id: room.venue_id, name: room.name}
  end

  # `shift_type_name` rather than `name`, because it is the type's and a `name`
  # key on a shift room would claim the room has one. A shift room has no
  # display name of its own — only two instants and a type — so the type's name
  # and the term together are the label, and the term is not optional: two
  # Tuesdays of one type are two rooms with one name.
  #
  # **The label is composed on the client**, not here. Formatting a shift time
  # means choosing a timezone, `venues` carries one and the worker's device
  # carries another, and the worker is the reader.
  #
  # `closes_at` ships as a fact and the client must not derive open/closed from
  # it: `HospitalityComs.Clock` is offsettable and the demo moves it, while a
  # browser's clock is real, so a client-side comparison answers wrongly during
  # exactly the demo the offset exists for.
  @spec render_shift_room(ShiftRoom.t()) :: %{
          shift_room_id: Ecto.UUID.t(),
          venue_id: Ecto.UUID.t(),
          shift_type_name: String.t(),
          starts_at: String.t(),
          ends_at: String.t(),
          closes_at: String.t()
        }
  defp render_shift_room(%ShiftRoom{shift_type: %ShiftType{} = shift_type} = room) do
    %{
      shift_room_id: room.id,
      venue_id: room.venue_id,
      shift_type_name: shift_type.name,
      starts_at: DateTime.to_iso8601(room.starts_at),
      ends_at: DateTime.to_iso8601(room.ends_at),
      closes_at: DateTime.to_iso8601(room.closes_at)
    }
  end

  # The channel's own shape, called rather than copied. A message has one key
  # set on this API whichever transport carried it.
  @spec render_message(RoomMessage.t()) :: RoomChannel.rendered()
  defp render_message(%RoomMessage{} = message), do: RoomChannel.rendered(message)

  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  defp not_found(conn), do: refuse(conn, :not_found, @no_room)

  @spec bad_extent(Plug.Conn.t()) :: Plug.Conn.t()
  defp bad_extent(conn), do: refuse(conn, :bad_request, @bad_extent)

  # The status atom is the envelope's code, so the two cannot drift apart —
  # `HospitalityComsWeb.SessionController`'s shape, for the same reason.
  @spec refuse(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> json(ErrorEnvelope.new(status, message))
  end
end
