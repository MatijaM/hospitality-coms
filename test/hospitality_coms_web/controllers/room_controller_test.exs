defmodule HospitalityComsWeb.RoomControllerTest do
  @moduledoc """
  The four person-side reads, and the bound that is the only new logic among
  them.

  Three things are asserted here and they answer different questions.

  **That the bound reaches the transport.** Every history assertion is written
  against a room holding `recent_message_limit/0` **+ 1** messages, because a
  test asserting "fifty came back" against a fixture of twelve passes for the
  wrong reason and certifies nothing — the shape
  `docs/solutions/test-failures/tests-that-certify-nothing.md` catalogues. The
  page's *contents* are named as well as its length, because a bound that took
  the oldest fifty satisfies every count.

  **That no rendered shape names a person.** Each of the three shapes is
  asserted with an **exact key set** rather than by matching the keys it should
  have. An exact set is the only assertion that fails when a field is *added*,
  which is the direction `person_id` arrives from — `CLAUDE.md` records
  `Rooms.list_venue_room_members/2` handing out whole `Engagement` structs as a
  live disclosure, and this unit must not add a second instance while building a
  list surface.

  **That a refusal enumerates nothing.** A malformed id, another person's venue,
  a room that does not exist and a room this session may not reach are one
  answer: `404`, one sentence, and the envelope. The malformed case is the one
  worth having, because without `HospitalityComsWeb.EntityId` it is a `500` and
  the status alone tells a caller malformed from unknown (AE1).

  ## The controls

    * `extent=all` sits beside every bounded assertion, so a limit applied to
      both would fail the pair;
    * every `404` assertion has the same request with a good id answering `200`
      beside it, so a route that refused unconditionally would fail;
    * the `401` block has the authenticated form of each of the four beside it;
    * the suspended person is refused their venue room's history *next to* still
      listing that venue's shift rooms, which is KTD18 and its own control.

  ## Why this file is not sandboxed

  `HospitalityComs.EngagementsFixtures`' reason, sharpened by
  `HospitalityComs.ProfilesTest`'s: the thing under test reads a bridge written
  through `HospitalityComs.EmployerRepo` and a room read through
  `HospitalityComs.Repo`, so under the sandbox every list would come back empty
  and **every negative assertion in this file would pass for the wrong reason**.

  The clock is pinned for `HospitalityComsWeb.ChannelCase`'s reason: a request
  reads it through `HospitalityComsWeb.PersonAuth.fetch_person_scope/2`, and
  fixtures hanging off `EngagementsFixtures.fixed_instant/0` would otherwise be
  compared against whatever today is.
  """

  use ExUnit.Case, async: false

  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.RoomsFixtures
  import Phoenix.ConnTest

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Rooms
  alias HospitalityComsWeb.PersonAuth

  @endpoint HospitalityComsWeb.Endpoint

  @now ~U[2026-03-01 12:00:00.000000Z]
  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)
  @grace_minutes 30

  @message_keys ~w(id body sent_at author_engagement_id)
  @venue_room_keys ~w(venue_id name)
  @shift_room_keys ~w(shift_room_id venue_id shift_type_name starts_at ends_at closes_at)

  setup do
    real_connections()
    :ok = Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)

    {:ok, conn: build_conn()}
  end

  ## The venue-room list

  describe "GET /api/venue-rooms" do
    test "answers the rooms this person is in, by name", %{conn: conn} do
      # The sub-item's whole point. `VenueRoom` carries a name, and rendering it
      # is what stops every room list in the client being uuid prefixes.
      %{employer: employer, person: person, venue: venue} = engaged()

      body = json_get(conn, person, "/api/venue-rooms")

      assert %{"venue_rooms" => [room]} = body
      assert room["venue_id"] == employer.venue_id
      assert room["name"] == venue.name
      assert Map.keys(room) |> Enum.sort() == Enum.sort(@venue_room_keys)
    end

    test "leaves a suspended person's venue room out, and still lists that venue's shift rooms",
         %{conn: conn} do
      # KTD18 on the transport, with its own control. Suspension is the venue
      # room only: a route that gated the shift-room list on venue-room
      # membership would pass the first assertion and fail the second.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      {:ok, _suspension} = Rooms.suspend_venue_room(person_scope(person), employer.venue_id)

      assert %{"venue_rooms" => []} = json_get(conn, person, "/api/venue-rooms")

      assert %{"shift_rooms" => [listed]} =
               json_get(conn, person, "/api/venues/#{employer.venue_id}/shift-rooms")

      assert listed["shift_room_id"] == room.id
    end

    test "answers an empty list rather than a refusal when there are no rooms", %{conn: conn} do
      person = person_fixture(@now)

      assert %{"venue_rooms" => []} = json_get(conn, person, "/api/venue-rooms")
    end
  end

  ## The shift-room list

  describe "GET /api/venues/:venue_id/shift-rooms" do
    test "answers one venue's readable rooms with the shift type's name", %{conn: conn} do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      shift_type = shift_type_fixture(employer, @grace_minutes)
      room = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
      roster_entry_fixture(employer, room, engagement.id)

      body = json_get(conn, person, "/api/venues/#{employer.venue_id}/shift-rooms")

      assert %{"shift_rooms" => [listed]} = body
      assert listed["shift_room_id"] == room.id
      assert listed["venue_id"] == employer.venue_id
      assert listed["shift_type_name"] == shift_type.name
      assert listed["starts_at"] == DateTime.to_iso8601(room.starts_at)
      assert Map.keys(listed) |> Enum.sort() == Enum.sort(@shift_room_keys)
    end

    test "answers an empty list for a venue this person has nothing at", %{conn: conn} do
      # AE1 by construction. The control is the test above: an endpoint that
      # answered `[]` for every venue would pass this and fail that.
      %{person: person} = engaged()
      {stranger, _creation} = scoped_venue_fixture(@now)
      _room = shift_room(stranger)

      assert %{"shift_rooms" => []} =
               json_get(conn, person, "/api/venues/#{stranger.venue_id}/shift-rooms")
    end

    test "answers a malformed venue id with 404 rather than a crash", %{conn: conn} do
      %{employer: employer, person: person} = engaged()

      assert %{"error" => %{"code" => "not_found"}} =
               json_get(conn, person, "/api/venues/not-a-uuid/shift-rooms", 404)

      # The control: the same route with a well-formed id answers.
      assert %{"shift_rooms" => _rooms} =
               json_get(conn, person, "/api/venues/#{employer.venue_id}/shift-rooms")
    end

    test "answers sixteen raw bytes with 404 too", %{conn: conn} do
      # `Ecto.UUID.cast/1` alone encodes sixteen raw bytes into a valid-looking
      # id, so the byte-size half of `EntityId.cast/1` is what refuses this.
      %{person: person} = engaged()

      assert %{"error" => %{"code" => "not_found"}} =
               json_get(conn, person, "/api/venues/0123456789abcdef/shift-rooms", 404)
    end
  end

  ## Venue-room history

  describe "GET /api/venue-rooms/:venue_id/messages" do
    test "answers the most recent page, says it is not the whole history, and lifts it for all",
         %{conn: conn} do
      # The unit's central claim on the transport, with its two controls in one
      # body: the page must be the *newest* rows, and `extent=all` must not be
      # bounded.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      limit = Rooms.recent_message_limit()
      bodies = venue_room_messages_fixture(engagement, limit + 1, @now)
      path = "/api/venue-rooms/#{employer.venue_id}/messages"

      assert %{"messages" => page, "complete" => false} = json_get(conn, person, path)
      assert length(page) == limit

      read = Enum.map(page, & &1["body"])
      refute List.first(bodies) in read
      assert List.last(bodies) in read

      assert %{"messages" => whole, "complete" => true} =
               json_get(conn, person, path <> "?extent=all")

      assert Enum.map(whole, & &1["body"]) == bodies
    end

    test "renders a message with exactly the channel's key set and no person id", %{conn: conn} do
      # `RoomChannel.rendered/1` reused rather than respelled. The exact key set
      # is the assertion that fails when a field is *added*, which is the
      # direction `person_id` arrives from.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      venue_room_messages_fixture(engagement, 1, @now)

      assert %{"messages" => [message]} =
               json_get(conn, person, "/api/venue-rooms/#{employer.venue_id}/messages")

      assert Map.keys(message) |> Enum.sort() == Enum.sort(@message_keys)
      assert message["author_engagement_id"] == engagement.id
      refute Map.has_key?(message, "person_id")
    end

    test "answers extent=recent exactly as the default", %{conn: conn} do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      venue_room_messages_fixture(engagement, Rooms.recent_message_limit() + 1, @now)
      path = "/api/venue-rooms/#{employer.venue_id}/messages"

      assert json_get(conn, person, path) == json_get(conn, person, path <> "?extent=recent")
    end

    test "refuses an extent it does not know rather than falling back", %{conn: conn} do
      %{employer: employer, person: person} = engaged()
      path = "/api/venue-rooms/#{employer.venue_id}/messages"

      assert %{"error" => %{"code" => "bad_request", "message" => message}} =
               json_get(conn, person, path <> "?extent=sideways", 400)

      assert message =~ "recent"

      # The control: the same path with no extent answers.
      assert %{"messages" => []} = json_get(conn, person, path)
    end

    test "refuses another person's venue and a malformed id identically", %{conn: conn} do
      %{employer: employer, person: person} = engaged()
      {stranger, _creation} = scoped_venue_fixture(@now)

      mine = json_get(conn, person, "/api/venue-rooms/#{employer.venue_id}/messages")
      assert %{"messages" => [], "complete" => true} = mine

      theirs =
        json_get(conn, person, "/api/venue-rooms/#{stranger.venue_id}/messages", 404)

      malformed = json_get(conn, person, "/api/venue-rooms/nope/messages", 404)

      assert theirs == malformed
      assert %{"error" => %{"code" => "not_found"}} = theirs
    end
  end

  ## Shift-room history

  describe "GET /api/shift-rooms/:shift_room_id/messages" do
    test "bounds the page and lifts it for all", %{conn: conn} do
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      limit = Rooms.recent_message_limit()
      bodies = shift_room_messages_fixture(engagement, room, limit + 1, @shift_starts)
      path = "/api/shift-rooms/#{room.id}/messages"

      assert %{"messages" => page, "complete" => false} = json_get(conn, person, path)
      assert length(page) == limit
      refute List.first(bodies) in Enum.map(page, & &1["body"])

      assert %{"messages" => whole, "complete" => true} =
               json_get(conn, person, path <> "?extent=all")

      assert length(whole) == limit + 1
    end

    test "refuses a room this person was never rostered on", %{conn: conn} do
      # The control is the test above: the same route answers for a room this
      # person's roster overlapped.
      %{employer: employer} = engaged()
      room = shift_room(employer)
      %{person: stranger} = engaged_at(employer)

      assert %{"error" => %{"code" => "not_found"}} =
               json_get(conn, stranger, "/api/shift-rooms/#{room.id}/messages", 404)
    end
  end

  ## The session

  describe "authentication" do
    test "refuses all four routes without a bearer token", %{conn: conn} do
      # And answers all four with one, which is the control: a pipeline that
      # refused everything would satisfy the first half alone.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      room = shift_room(employer)
      roster_entry_fixture(employer, room, engagement.id)

      paths = [
        "/api/venue-rooms",
        "/api/venue-rooms/#{employer.venue_id}/messages",
        "/api/venues/#{employer.venue_id}/shift-rooms",
        "/api/shift-rooms/#{room.id}/messages"
      ]

      for path <- paths do
        assert %{"error" => %{"code" => "unauthorized"}} =
                 conn |> get(path) |> json_response(401)

        assert conn |> with_session(person) |> get(path) |> json_response(200)
      end
    end
  end

  ## Helpers

  defp json_get(conn, person, path, status \\ 200) do
    conn |> with_session(person) |> get(path) |> json_response(status)
  end

  defp with_session(conn, person) do
    token =
      person
      |> PersonScope.for_person(@now)
      |> Accounts.generate_person_session_token()
      |> PersonAuth.encode_token()

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp person_scope(person), do: PersonScope.for_person(person, @now)

  defp engaged do
    {employer, creation} = scoped_venue_fixture(@now)
    employer |> engaged_at() |> Map.merge(%{employer: employer, venue: creation.venue})
  end

  defp engaged_at(employer) do
    person = person_fixture(@now)

    engagement =
      engagement_fixture(employer, person_scope(person), %{
        starts_at: @now,
        ends_at: DateTime.add(@now, 90, :day),
        code_expires_at: DateTime.add(@now, 7, :day)
      })

    %{person: person, engagement: engagement}
  end

  defp shift_room(employer) do
    shift_type = shift_type_fixture(employer, @grace_minutes)
    shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
  end
end
