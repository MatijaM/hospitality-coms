defmodule HospitalityComsWeb.ShiftRoomChannelTest do
  @moduledoc """
  Where joining and sending are different questions, and the clock answers both.

  U6 keeps readability and membership apart: readability is a roster period that
  *overlapped* the room's open window, membership is a roster period containing
  this instant in a room that is open at it. This file is where the difference
  becomes visible from outside a context — somebody taken off the roster an hour
  ago joins, reads everything, and is refused when they send.

  The grace window is the other half, and it is the demo's flagship beat. A
  channel joined before `closes_at` has its send refused after it **with no job
  having run and no rejoin in between**, because
  `HospitalityComsWeb.ChannelAuth.person_scope/1` reads the clock on every
  inbound event (KTD5). Every test that crosses a boundary here asserts the send
  succeeding on the near side first, so a send path that refused everything
  would fail the pair.
  """

  use HospitalityComsWeb.ChannelCase

  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rosters
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()

  @opens DateTime.add(@now, 1, :hour)
  @during DateTime.add(@now, 4, :hour)
  @ends DateTime.add(@now, 9, :hour)
  @grace_minutes 30
  @closes DateTime.add(@ends, @grace_minutes, :minute)
  @after_close DateTime.add(@closes, 1, :minute)

  @unreadable %{code: "unauthorized", message: "this session cannot read that shift room"}

  describe "joining a shift room" do
    test "succeeds for a roster period that overlaps the room's open window" do
      %{room: room, engagement: engagement, socket: socket} = rostered()

      assert {:ok, reply, _channel} = subscribe_and_join(socket, topic(room), %{})
      assert reply == %{shift_room_id: room.id, engagement_id: engagement.id}
    end

    test "is refused for somebody who was never on the roster" do
      # KTD14's scope. An engagement at the venue is not enough: a day-one hire
      # does not get to read the venue's whole shift history.
      %{room: room, employer: employer} = rostered()
      newcomer = person_scope_fixture(@now)

      engagement_fixture(employer, newcomer, %{
        starts_at: @now,
        ends_at: DateTime.add(@now, 30, :day)
      })

      assert {:error, refusal} = join(person_socket(newcomer), topic(room), %{})
      assert refusal.error == @unreadable
    end

    test "is refused for a room at a venue this session holds no engagement at" do
      # `:not_found` and "you were never rostered" are the same answer, so the
      # refusal enumerates no venue's shift history (AE1).
      %{socket: socket} = rostered()

      other = venue_fixture(@now)
      other_employer = employer_scope_fixture(other, @now)
      other_type = shift_type_fixture(other_employer, @grace_minutes)
      other_room = shift_room_fixture(other_employer, other_type, @opens, @ends)

      assert {:error, refusal} = join(socket, topic(other_room), %{})
      assert refusal.error == @unreadable
    end

    test "gives a topic suffix that is not a uuid the identical refusal" do
      # A malformed id and an unknown one answer the same, so the refusal still
      # enumerates nothing (AE1). It used to raise `Ecto.Query.CastError`.
      %{socket: socket} = rostered()

      for suffix <- ["", "nope", "not-a-uuid", String.duplicate("x", 36)] do
        assert {:error, refusal} = join(socket, "shift_room:" <> suffix, %{})
        assert refusal.error == @unreadable
      end
    end

    test "still succeeds after the person is taken off the roster" do
      # KTD6b as a transport behaviour. Removal closes a period; the part that
      # already overlapped the room's window is untouchable, so readability
      # survives for ever.
      %{room: room, employer: employer, engagement: engagement, socket: socket} = rostered()

      at(@during)

      assert {:ok, _entry} =
               Rosters.remove_from_roster(
                 employer_at(employer, @during),
                 room.id,
                 engagement.id
               )

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, topic(room), %{})
    end
  end

  describe "sending to a shift room" do
    test "is accepted while the room is open" do
      %{room: room, engagement: engagement, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      ref = push(channel, "send", %{"body" => "double sat on section 2"})

      assert_reply ref, :ok, sent
      assert sent.author_engagement_id == engagement.id
      assert_broadcast "message", broadcast
      assert broadcast.id == sent.id
    end

    test "is refused at exactly closes_at, on a channel joined before it" do
      # The flagship beat. Half-open: the instant a room closes belongs to the
      # closed side, and the channel that was accepting messages a moment ago is
      # the same process.
      %{room: room, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      accepted = push(channel, "send", %{"body" => "inside the window"})
      assert_reply accepted, :ok, _sent

      at(@closes)

      refused = push(channel, "send", %{"body" => "at the boundary"})
      assert_reply refused, :error, refusal
      assert refusal.error.code == "gone"
    end

    test "is refused after the grace window, and the room stays joinable" do
      # Grace closes writes. It does not close reads, and nothing closes reads.
      %{room: room, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      at(@after_close)

      refused = push(channel, "send", %{"body" => "too late"})
      assert_reply refused, :error, refusal
      assert refusal.error.code == "gone"

      assert {:ok, _reply, _rejoined} = subscribe_and_join(socket, topic(room), %{})
    end

    test "is refused as not_rostered once the person is taken off the roster" do
      # The control for readability surviving removal: they can still join, and
      # this is what they cannot do. Membership and readability are different
      # predicates and the transport shows both.
      %{room: room, employer: employer, engagement: engagement, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      accepted = push(channel, "send", %{"body" => "still on the roster"})
      assert_reply accepted, :ok, _sent

      assert {:ok, _entry} =
               Rosters.remove_from_roster(
                 employer_at(employer, @during),
                 room.id,
                 engagement.id
               )

      refused = push(channel, "send", %{"body" => "and now I am not"})
      assert_reply refused, :error, refusal
      assert refusal.error.code == "forbidden"
    end

    test "answers an event it does not handle rather than crashing on it" do
      %{room: room, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      ref = push(channel, "delete_everything", %{})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"

      assert Process.alive?(channel.channel_pid)
    end

    test "refuses a payload with no body" do
      # The same shape `HospitalityComsWeb.VenueRoomChannel` answers with, and
      # it was the untested half of the pair.
      %{room: room, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      ref = push(channel, "send", %{})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "bad_request"
    end

    test "reports a rejected body as a per-field failure" do
      # `ErrorEnvelope.for_changeset/3` was extracted for three call sites and
      # this is the one that had no test through it.
      %{room: room, socket: socket} = rostered()

      at(@during)
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      ref =
        push(channel, "send", %{
          "body" => String.duplicate("x", RoomMessage.max_body_length() + 1)
        })

      assert_reply ref, :error, refusal
      assert refusal.error.code == "unprocessable_entity"
      assert [_message] = refusal.error.fields.body
    end

    test "is refused before the room opens" do
      # A room that has not opened is as closed as one that has shut, which is
      # the same half-open convention read from the other end.
      %{room: room, socket: socket} = rostered()
      {:ok, _reply, channel} = subscribe_and_join(socket, topic(room), %{})

      ref = push(channel, "send", %{"body" => "an hour early"})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "gone"
    end
  end

  ## Fixtures

  defp topic(room), do: "shift_room:" <> room.id

  defp rostered do
    creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: @now,
        ends_at: DateTime.add(@now, 30, :day)
      })

    shift_type = shift_type_fixture(employer, @grace_minutes)
    room = shift_room_fixture(employer, shift_type, @opens, @ends)
    roster_entry_fixture(employer, room, engagement.id)

    %{
      employer: employer,
      person: person,
      engagement: engagement,
      room: room,
      socket: person_socket(person)
    }
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person.person, @now)))
    socket
  end
end
