defmodule HospitalityComsWeb.PresenceTest do
  @moduledoc """
  What presence says, and the two things it must never say.

  ## It must not name a person

  KTD2 keeps `person_id` off every employer-zone row and KTD15b makes
  attribution the engagement. A presence entry is not a row, but it fans out to
  every member of the room and across distributed Erlang, so it gets the same
  rule: the key is `engagements.id` — which is the `author_engagement_id` a
  message already carries, venue-local by construction — and the meta carries
  the employer-authored role label and nothing else.

  ## It must not recover a suspension (KTD18)

  U6 closed a leak by *widening*: the venue room's roll is the venue's active
  engagements, unfiltered by suspension, so that reading two lists and
  subtracting cannot recover who has opted out. Presence is narrower than the
  roll by construction — a suspended person cannot join, so they are absent —
  and it could therefore be that subtraction by another route.

  What stops it is not a filter. It is that presence lives on person-socket
  topics only, `HospitalityComsWeb.EmployerSocket` routes no room topic at all,
  and `HospitalityComs.PubSub.subscribe/2` refuses an employer scope handed one.
  The test below asserts the suspended person is absent from presence *and*
  present on the roll in the same breath, which is U6's control shape: a
  presence implementation that hid everybody would fail it.

  ## The leave is the tracker's, not ours

  There is no `untrack` call anywhere in this unit. The proof is not that we
  looked: it is that a channel process **killed outright**, which runs no code
  of ours at all, still produces a leave. That is the tracker's monitor, and it
  is why a revoked channel needs nothing beyond `{:stop, …}`.
  """

  use HospitalityComsWeb.ChannelCase

  alias HospitalityComs.Engagements
  alias HospitalityComs.Rooms
  alias HospitalityComsWeb.PersonSocket
  alias HospitalityComsWeb.Presence

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @term_ends DateTime.add(@now, 30, :day)

  describe "tracking" do
    test "keys the entry on the engagement and never on the person" do
      %{venue: venue, people: [worker | _rest]} = venue_with(2)

      {:ok, _reply, channel} = subscribe_and_join(worker.socket, topic(venue), %{})

      assert_push "presence_state", _state
      presences = Presence.list(channel)

      assert Map.keys(presences) == [worker.engagement.id]
      refute Map.has_key?(presences, worker.person.person.id)

      assert [%{role_label: label}] = presences[worker.engagement.id].metas
      assert label == worker.engagement.role_label
    end

    test "carries the person's id in no meta of any entry" do
      # The stronger form: not merely "the key is not the person id" but "the
      # person id is nowhere in the value".
      %{venue: venue, people: [worker | _rest]} = venue_with(2)

      {:ok, _reply, channel} = subscribe_and_join(worker.socket, topic(venue), %{})
      assert_push "presence_state", _state

      metas = channel |> Presence.list() |> Enum.flat_map(fn {_key, %{metas: m}} -> m end)

      refute Enum.any?(metas, &(worker.person.person.id in Map.values(&1)))
    end
  end

  describe "a revoked channel" do
    test "emits a leave when it stops, with no untrack anywhere" do
      Process.flag(:trap_exit, true)
      %{venue: venue, employer: employer, people: [leaving, staying]} = venue_with(2)

      {:ok, _staying_reply, _staying_channel} =
        subscribe_and_join(staying.socket, topic(venue), %{})

      {:ok, _leaving_reply, leaving_channel} =
        subscribe_and_join(leaving.socket, topic(venue), %{})

      leaving_pid = leaving_channel.channel_pid
      assert_broadcast "presence_diff", %{joins: joins}

      assert Map.has_key?(joins, leaving.engagement.id) or
               Map.has_key?(joins, staying.engagement.id)

      assert {:ok, _ended} = Engagements.end_engagement(employer, leaving.engagement.id)
      assert_receive {:EXIT, ^leaving_pid, {:shutdown, :revoked}}

      assert_leave(leaving.engagement.id)
    end

    test "would emit the same leave if it were killed outright" do
      # The evidence that the leave is the tracker's monitor rather than
      # anything the channel does on its way out. A killed process runs no code,
      # so a leave arriving here cannot have come from an `untrack` call.
      Process.flag(:trap_exit, true)
      %{venue: venue, people: [leaving, staying]} = venue_with(2)

      {:ok, _staying_reply, _staying} = subscribe_and_join(staying.socket, topic(venue), %{})
      {:ok, _leaving_reply, channel} = subscribe_and_join(leaving.socket, topic(venue), %{})

      Process.exit(channel.channel_pid, :kill)

      assert_leave(leaving.engagement.id)
    end
  end

  describe "a suspension" do
    test "is absent from presence and present on the room's roll" do
      # KTD18's control shape, at the transport. The person who opted out cannot
      # join, so they are not in presence — and they are still on the roll, which
      # is the set an employer session can already read. Subtracting the two
      # recovers nothing, because the roll did not change.
      %{venue: venue, employer: employer, people: [watcher, opted_out]} = venue_with(2)

      assert {:ok, _suspension} = Rooms.suspend_venue_room(opted_out.person, venue.id)

      {:ok, _reply, channel} = subscribe_and_join(watcher.socket, topic(venue), %{})
      assert_push "presence_state", _state

      refute Map.has_key?(Presence.list(channel), opted_out.engagement.id)

      assert {:ok, roll} = Rooms.list_venue_room_members(watcher.person, venue.id)
      assert opted_out.engagement.id in Enum.map(roll, & &1.id)

      # And the same set the employer already has, so the two lists agree and
      # there is nothing to subtract.
      assert {:ok, listed} = Engagements.list_engagements(employer)
      assert Enum.sort(Enum.map(listed, & &1.id)) == Enum.sort(Enum.map(roll, & &1.id))
    end
  end

  describe "the employer transport" do
    test "carries no presence on the topic it does route" do
      # `EmployerSocket` routes `employer_venue:*` and nothing else, and nothing
      # tracks anything there. The room topics it does not route are asserted in
      # `HospitalityComsWeb.SocketsTest`.
      %{venue: venue, people: [worker | _rest]} = venue_with(2)

      {:ok, _reply, _channel} = subscribe_and_join(worker.socket, topic(venue), %{})
      assert_push "presence_state", _state

      assert Presence.list("employer_venue:" <> venue.id) == %{}
    end
  end

  describe "presence fetchers" do
    test "are drained rather than left running past the test" do
      # `Phoenix.Presence` invokes `fetch/2` from a process of its own. Ours does
      # no database work — see `HospitalityComsWeb.Presence` — so it cannot raise
      # an owner-exited error today; a fetcher outliving its owner is still the
      # shape that starts failing the moment somebody adds a preload, so it is
      # asserted rather than assumed.
      %{venue: venue, people: [worker | _rest]} = venue_with(2)

      {:ok, _reply, channel} = subscribe_and_join(worker.socket, topic(venue), %{})
      assert_push "presence_state", _state
      _listed = Presence.list(channel)

      assert drained_fetchers?()
      assert Presence.fetchers_pids() == []
    end
  end

  ## Fixtures

  defp topic(venue), do: "venue_room:" <> venue.id

  defp assert_leave(engagement_id) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{leaves: %{^engagement_id => _metas}}
                   },
                   2_000
  end

  defp venue_with(count) do
    creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)

    people =
      Enum.map(1..count, fn _index ->
        person = person_scope_fixture(@now)

        engagement =
          engagement_fixture(employer, person, %{starts_at: @now, ends_at: @term_ends})

        %{person: person, engagement: engagement, socket: person_socket(person)}
      end)

    %{venue: creation.venue, employer: employer, people: people}
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person.person, @now)))
    socket
  end
end
