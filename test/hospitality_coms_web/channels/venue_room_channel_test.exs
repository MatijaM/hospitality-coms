defmodule HospitalityComsWeb.VenueRoomChannelTest do
  @moduledoc """
  Join authorization and send authorization, each derived at its own instant.

  Two properties are asserted here and they are different properties.

  **`join/3` re-derives.** Nothing about membership rides on the socket, so a
  join is exactly as good as the engagement is at the instant it is made. That
  is KTD8 and it is what makes the refused rejoin in
  `HospitalityComsWeb.RevocationTest` possible at all.

  **The instant is per inbound event.** A channel joined at noon and still
  joined at midnight authorises its sends against midnight, because
  `HospitalityComsWeb.ChannelAuth.person_scope/1` reads the clock each time. The
  test that proves it moves the *clock* rather than writing anything: the send
  that was accepted before the advance is refused after it, with no job having
  run, no rejoin, and no row changed.

  Every refusal in this file is the same envelope with the same message,
  deliberately. The caller supplies the venue id, so an answer that
  distinguished "your engagement ended" from "no such venue" would enumerate the
  application's venues one join at a time (AE1).
  """

  use HospitalityComsWeb.ChannelCase

  # `only:` because `Ecto.Query.join/3` and `Phoenix.ChannelTest.join/3` are
  # both in scope here, and the one this file wants is the channel's.
  import Ecto.Query, only: [from: 2]

  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @an_hour_on DateTime.add(@now, 1, :hour)
  @two_hours_on DateTime.add(@now, 2, :hour)

  # The reply payload a channel refusal carries is the raw map, not JSON, so
  # the keys are atoms. One constant for every refusal in the file, because
  # every refusal has to be the same string: telling them apart is the
  # enumeration AE1 forbids.
  @refused %{code: "unauthorized", message: "this session is not in that venue's room"}

  describe "joining a venue room" do
    test "succeeds for an engagement active at this instant" do
      %{venue: venue, engagement: engagement, socket: socket} = engaged()

      assert {:ok, reply, _channel} = subscribe_and_join(socket, topic(venue), %{})
      assert reply == %{venue_id: venue.id, engagement_id: engagement.id}
    end

    test "is refused once the engagement has ended" do
      # KTD8. The socket is the same one that joined a moment ago; what changed
      # is the answer the database gives.
      # The channel is linked to the test process by `Phoenix.ChannelTest`, and
      # ending the engagement stops it with `{:shutdown, :revoked}` — which
      # would take the test down with it. Trapping turns that into a message.
      Process.flag(:trap_exit, true)

      %{venue: venue, employer: employer, engagement: engagement, socket: socket} = engaged()

      assert {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})
      channel_pid = channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)
      assert_receive {:EXIT, ^channel_pid, {:shutdown, :revoked}}

      assert {:error, refusal} = join(socket, topic(venue), %{})
      assert refusal.error == @refused
    end

    test "is refused with no write at all, once the term's upper bound passes" do
      # The same refusal reached by moving the clock rather than by ending
      # anything. Nothing ran: `oban_jobs` is empty and the row is untouched.
      %{venue: venue, engagement: engagement, socket: socket} = engaged(ends_at: @an_hour_on)

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, topic(venue), %{})

      at(@two_hours_on)

      assert {:error, refusal} = join(socket, topic(venue), %{})
      assert refusal.error == @refused

      # Nothing ran and nothing was written: the claim's expiry job is still
      # sitting where it was inserted, and the term is the one the invitation
      # offered.
      assert Repo.all(from job in Oban.Job, select: job.state) == ["scheduled"]

      assert Repo.get!(Engagement, engagement.id).ends_at ==
               DateTime.truncate(@an_hour_on, :second)
    end

    test "gives a venue this session was never engaged at the identical refusal" do
      # AE1's not-found-rather-than-forbidden rule, at the one place a caller
      # supplies the id. The two refusals have to be the same string, not merely
      # the same status.
      %{socket: socket} = engaged()
      %{venue: other_venue} = venue_fixture(@now)

      assert {:error, refusal} = join(socket, topic(other_venue), %{})
      assert refusal.error == @refused
    end

    test "is refused while the person has suspended the room" do
      # KTD18 reaching the transport. Suspension closes the suspended person's
      # own access and nothing else.
      %{venue: venue, person: person, socket: socket} = engaged()

      assert {:ok, _suspension} = Rooms.suspend_venue_room(person, venue.id)
      assert {:error, refusal} = join(socket, topic(venue), %{})
      assert refusal.error == @refused
    end

    test "succeeds again after the person resumes" do
      # The control for the test above: a join that refused everybody would
      # satisfy it.
      %{venue: venue, person: person, socket: socket} = engaged()

      assert {:ok, _suspension} = Rooms.suspend_venue_room(person, venue.id)
      assert {:ok, _resumed} = Rooms.resume_venue_room(person, venue.id)

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, topic(venue), %{})
    end
  end

  describe "sending to a venue room" do
    test "writes the message and broadcasts it to the room" do
      %{venue: venue, engagement: engagement, socket: socket} = engaged()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      ref = push(channel, "send", %{"body" => "behind on tables 4 and 7"})

      assert_reply ref, :ok, sent
      assert sent.body == "behind on tables 4 and 7"
      assert sent.author_engagement_id == engagement.id
      assert_broadcast "message", broadcast
      assert broadcast.id == sent.id

      assert [%RoomMessage{body: "behind on tables 4 and 7"}] = Repo.all(RoomMessage)
    end

    test "carries no person id on the wire" do
      # KTD2 and KTD15b at the transport. Attribution is the engagement, which
      # is venue-local by construction and is what a message row already holds.
      %{venue: venue, person: person, socket: socket} = engaged()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      ref = push(channel, "send", %{"body" => "on my way"})

      assert_reply ref, :ok, sent
      refute Map.has_key?(sent, :person_id)
      refute person.person.id in Map.values(sent)
    end

    test "is refused after the term's upper bound passes, on a channel joined before it" do
      # KTD5's flagship claim: the unit of work is the inbound event, not the
      # join. An instant stamped at join would have accepted this, and nothing
      # about the room changed except what time it is.
      %{venue: venue, socket: socket} = engaged(ends_at: @an_hour_on)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      accepted = push(channel, "send", %{"body" => "still here"})
      assert_reply accepted, :ok, _sent

      at(@two_hours_on)

      refused = push(channel, "send", %{"body" => "and now I am not"})
      assert_reply refused, :error, refusal
      assert refusal.error == @refused
    end

    test "is unreachable once the person suspends the room: the channel is gone" do
      # This test used to push after suspending and assert a refused reply. U7's
      # review closed the hole that made that reachable — suspension broadcast
      # nothing, so the channel stayed open and the person kept *receiving* the
      # room until they happened to rejoin. The channel now stops, so there is
      # no send to refuse.
      #
      # The refusal itself is not lost and is not asserted here, because the
      # broadcast that stops the channel is best effort: what has to hold when
      # it goes missing is `Rooms.send_venue_room_message/3` refusing a
      # suspended sender at the instant of the send, and that is asserted in
      # `HospitalityComs.RoomsTest` where no nudge can reach it.
      Process.flag(:trap_exit, true)
      %{venue: venue, person: person, socket: socket} = engaged()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})
      channel_pid = channel.channel_pid

      assert {:ok, _suspension} = Rooms.suspend_venue_room(person, venue.id)

      assert_push "access_suspended", suspended
      assert suspended.venue_id == venue.id
      assert_receive {:EXIT, ^channel_pid, {:shutdown, :suspended}}
    end

    test "refuses a payload with no body" do
      %{venue: venue, socket: socket} = engaged()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      ref = push(channel, "send", %{})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"
    end

    test "answers an event it does not handle rather than crashing on it" do
      # `handle_in/3` is dispatched unconditionally by
      # `Phoenix.Channel.Server`, so a channel with no terminal clause crashes
      # on every event it was not written for — which a client reaches by
      # sending one word.
      %{venue: venue, socket: socket} = engaged()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      ref = push(channel, "delete_everything", %{})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"

      assert Process.alive?(channel.channel_pid)
    end

    test "reports a rejected body as a per-field failure" do
      # The envelope's `fields` key is present only when the failure attaches to
      # an input, which is `HospitalityComsWeb.ErrorEnvelope`'s contract and the
      # one U12 is written against.
      %{venue: venue, socket: socket} = engaged()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(venue), %{})

      ref =
        push(channel, "send", %{
          "body" => String.duplicate("x", RoomMessage.max_body_length() + 1)
        })

      assert_reply ref, :error, refusal
      assert refusal.error.code == "unprocessable_entity"
      assert [_message] = refusal.error.fields.body
    end
  end

  ## Fixtures

  defp topic(venue), do: "venue_room:" <> venue.id

  defp engaged(opts \\ []) do
    creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: @now,
        ends_at: Keyword.get(opts, :ends_at, DateTime.add(@now, 30, :day))
      })

    %{
      venue: creation.venue,
      employer: employer,
      person: person,
      engagement: engagement,
      socket: person_socket(person)
    }
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person.person, @now)))
    socket
  end
end
