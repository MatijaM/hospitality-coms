defmodule HospitalityComsWeb.RevocationTest do
  @moduledoc """
  The refused rejoin, which is the only part of revocation that is a guarantee.

  ## Four nudges and one guarantee

  The sequence the plan draws has five arrows:

      commit → broadcast → push "access_revoked" → {:stop, {:shutdown, :revoked}}
             → client auto-rejoins → join/3 re-derives → {:error, unauthorized}

  Every arrow before the last can fail without the guarantee failing. The
  broadcast can be lost — `HospitalityComs.Engagements` logs it and carries on,
  because failing to end a term in order to report that nobody was told is the
  wrong trade. The push can race the socket closing. The stop can be beaten by a
  client that reconnects first, and the JS client auto-rejoins on `phx_error`
  regardless. Only `join/3` re-deriving is load-bearing, because it is a query
  against a term that has already closed and it answers the same way whether or
  not anything else ran.

  **So this file's central test asserts the rejoin.** Not that the process died
  — that is the nudge, and a transport with no re-derivation in it at all would
  pass an assertion about a dead process. The rejoin is a fresh `join/3` on the
  same `%Phoenix.Socket{}` `connect/3` returned, which is exactly what the JS
  client sends over the wire when its channel errors, and it is asserted next to
  the join that succeeded a moment earlier so it cannot pass for want of a
  working transport.

  ## Trapping exits

  `Phoenix.ChannelTest` links each channel to the test process, so a channel
  stopping with `{:shutdown, :revoked}` would take the test with it. Tests here
  trap exits and assert on the `{:EXIT, pid, {:shutdown, :revoked}}` message,
  which is a stronger assertion than "it is no longer alive" — it names the
  reason.
  """

  use HospitalityComsWeb.ChannelCase
  use Oban.Testing, repo: HospitalityComs.Repo

  alias HospitalityComs.Engagements
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Rooms
  alias HospitalityComs.Workers.EngagementSweeper
  alias HospitalityComs.Workers.ExpireEngagement
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @term_ends DateTime.add(@now, 30, :day)

  @opens DateTime.add(@now, 1, :hour)
  @ends DateTime.add(@now, 9, :hour)

  @refused %{code: "unauthorized", message: "this session is not in that venue's room"}

  describe "ending an engagement" do
    test "pushes a terminal event and stops that venue's room channel" do
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, employer: employer, engagement: engagement} = world.a

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})
      channel_pid = channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)

      assert_push "access_revoked", revoked
      assert revoked.venue_id == venue.id
      assert revoked.engagement_id == engagement.id
      assert_receive {:EXIT, ^channel_pid, {:shutdown, :revoked}}
    end

    test "stops that venue's shift room channel in the same breath" do
      # "The person's channels for that venue", plural. Every channel subscribes
      # to its own engagement's revocation topic, so one broadcast reaches all
      # of them and no channel needs to know about the others.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, employer: employer, engagement: engagement} = world.a
      room = shift_room(employer, engagement)

      {:ok, _venue_reply, venue_channel} =
        subscribe_and_join(world.socket, venue_topic(venue), %{})

      {:ok, _shift_reply, shift_channel} =
        subscribe_and_join(world.socket, shift_topic(room), %{})

      venue_pid = venue_channel.channel_pid
      shift_pid = shift_channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)

      assert_receive {:EXIT, ^venue_pid, {:shutdown, :revoked}}
      assert_receive {:EXIT, ^shift_pid, {:shutdown, :revoked}}
    end

    test "refuses the client's automatic rejoin afterwards" do
      # **The guarantee**, and it deliberately asserts nothing about the stop.
      # Two assertions: the join that worked, so the transport is not simply
      # broken, and then a *new* `join/3` on the same authenticated socket —
      # which is exactly what the JS client sends on `phx_error` — being refused.
      #
      # Delete the `{:stop, …}` from the channel and this test still passes,
      # because it never looked at the process. Delete the re-derivation from
      # `join/3` and this is the test that fails. Both were measured by making
      # the edits; the stop is asserted separately, above, as the nudge it is.
      #
      # Exits are still trapped: the channel does stop, and it is linked to this
      # process by `Phoenix.ChannelTest`.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, employer: employer, engagement: engagement} = world.a

      assert {:ok, _reply, _channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)

      assert {:error, refusal} = join(world.socket, venue_topic(venue), %{})
      assert refusal.error == @refused
    end

    test "leaves the same socket able to join the other venue's room" do
      # The refusal above is a re-derivation about *that venue*, not a socket
      # that has become useless. Without this, a `join/3` that refused
      # everything once anything had been revoked would pass the test above.
      Process.flag(:trap_exit, true)
      world = two_venues()

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(world.a.venue), %{})
      channel_pid = channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(world.a.employer, world.a.engagement.id)
      assert_receive {:EXIT, ^channel_pid, {:shutdown, :revoked}}

      assert {:error, _refusal} = join(world.socket, venue_topic(world.a.venue), %{})

      assert {:ok, _b_reply, _b} =
               subscribe_and_join(world.socket, venue_topic(world.b.venue), %{})
    end
  end

  describe "ending an engagement at one venue" do
    test "leaves the other venue's channel joined" do
      # R4 and AE1 over the transport, and the reason KTD7 makes the socket id
      # per session: one socket, two venues, and one of them ending.
      Process.flag(:trap_exit, true)
      world = two_venues()

      {:ok, _a_reply, a_channel} =
        subscribe_and_join(world.socket, venue_topic(world.a.venue), %{})

      {:ok, _b_reply, b_channel} =
        subscribe_and_join(world.socket, venue_topic(world.b.venue), %{})

      a_pid = a_channel.channel_pid
      b_pid = b_channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(world.b.employer, world.b.engagement.id)

      assert_receive {:EXIT, ^b_pid, {:shutdown, :revoked}}
      refute_receive {:EXIT, ^a_pid, _reason}
      assert Process.alive?(a_pid)
    end

    test "leaves the other venue's channel functional, not merely alive" do
      # "Joined" is not the claim; "still works" is. A channel that was alive
      # and could no longer send would satisfy the test above.
      Process.flag(:trap_exit, true)
      world = two_venues()

      {:ok, _a_reply, a_channel} =
        subscribe_and_join(world.socket, venue_topic(world.a.venue), %{})

      {:ok, _b_reply, b_channel} =
        subscribe_and_join(world.socket, venue_topic(world.b.venue), %{})

      b_pid = b_channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(world.b.employer, world.b.engagement.id)
      assert_receive {:EXIT, ^b_pid, {:shutdown, :revoked}}

      ref = push(a_channel, "send", %{"body" => "venue A is unaffected"})
      assert_reply ref, :ok, sent
      assert sent.author_engagement_id == world.a.engagement.id
    end

    test "leaves the other venue's room rejoinable" do
      Process.flag(:trap_exit, true)
      world = two_venues()

      {:ok, _b_reply, b_channel} =
        subscribe_and_join(world.socket, venue_topic(world.b.venue), %{})

      b_pid = b_channel.channel_pid

      assert {:ok, _ended} = Engagements.end_engagement(world.b.employer, world.b.engagement.id)
      assert_receive {:EXIT, ^b_pid, {:shutdown, :revoked}}

      assert {:ok, _reply, _rejoined} = join(world.socket, venue_topic(world.a.venue), %{})
    end
  end

  describe "erasing the person a channel is open for" do
    # CLAUDE.md names U10 as "the one to watch" for the residue a per-join
    # session derivation leaves: a channel authenticates its session at join and
    # authorises per inbound event (KTD5), so a token deleted mid-session leaves
    # that channel able to send until it next joins — unless
    # `PersonAuth.disconnect_sessions/1` reached it, which erasure has no way to
    # do from a context.
    #
    # The decision U10 took is that the teardown is not what makes the channel
    # powerless. Erasure ends every engagement in the same transaction, so the
    # *authorisation* half fails on the very next event, on the same process,
    # with nothing having rejoined. These two tests are that decision rather
    # than a description of it.

    test "refuses the next send on a channel that is still joined" do
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue} = world.a

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})

      # The control, first: the same channel sending successfully, so what
      # follows is about the erasure rather than about a broken transport.
      ref = push(channel, "send", %{"body" => "before"})
      assert_reply ref, :ok, _sent

      assert {:ok, _erasure} = Lifecycle.erase_person(world.person)

      ref = push(channel, "send", %{"body" => "after"})
      assert_reply ref, :error, refusal
      assert refusal.error.code == "unauthorized"
    end

    test "and refuses the rejoin, at every venue at once" do
      # Unlike ending one engagement, erasure crosses venues — which is why it
      # runs as the application's own role and why no employer session can do
      # it. The second venue is the control: after `end_engagement/2` the same
      # socket can still join venue B, and after an erasure it cannot.
      Process.flag(:trap_exit, true)
      world = two_venues()

      assert {:ok, _reply, _channel} =
               subscribe_and_join(world.socket, venue_topic(world.b.venue), %{})

      assert {:ok, _erasure} = Lifecycle.erase_person(world.person)

      assert {:error, refusal} = join(world.socket, venue_topic(world.a.venue), %{})
      assert refusal.error == @refused

      assert {:error, refusal} = join(world.socket, venue_topic(world.b.venue), %{})
      assert refusal.error == @refused
    end
  end

  describe "a change that rolls back" do
    test "produces no revocation broadcast at all" do
      # KTD8's ordering. The write commits first and the announcement fires only
      # on `{:ok, _}`, because a broadcast inside the transaction disconnects
      # clients for a change that may never have happened.
      %{venue: venue, employer: employer, engagement: engagement, socket: socket} = sole_manager()

      :ok = Engagements.subscribe(engagement.id)
      {:ok, _reply, _channel} = subscribe_and_join(socket, venue_topic(venue), %{})

      assert {:error, :last_grant_holder} = Engagements.end_engagement(employer, engagement.id)

      refute_receive {:engagement_revoked, _revocation}
      refute_receive %Phoenix.Socket.Message{event: "access_revoked"}
    end

    test "leaves the channel joined and still sending" do
      # The control. A channel that had already stopped would produce no
      # broadcast either, so "no broadcast" on its own says nothing.
      %{venue: venue, employer: employer, engagement: engagement, socket: socket} = sole_manager()

      {:ok, _reply, channel} = subscribe_and_join(socket, venue_topic(venue), %{})

      assert {:error, :last_grant_holder} = Engagements.end_engagement(employer, engagement.id)

      assert Process.alive?(channel.channel_pid)

      ref = push(channel, "send", %{"body" => "the refusal changed nothing"})
      assert_reply ref, :ok, _sent
    end
  end

  describe "suspending a venue room" do
    test "pushes a terminal event and stops that venue's room channel" do
      # KTD18's opt-out reaching a channel that is already open. Without it the
      # person keeps receiving the room's messages and keeps appearing in
      # presence until they happen to rejoin — which contradicts
      # `Rooms.suspend_venue_room/2`'s own doc, and which matters most when the
      # session that opted out is a different device from the one still joined.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, engagement: engagement} = world.a

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})
      channel_pid = channel.channel_pid

      assert {:ok, _suspension} = Rooms.suspend_venue_room(world.person, venue.id)

      assert_push "access_suspended", suspended
      assert suspended.venue_id == venue.id
      assert suspended.engagement_id == engagement.id
      assert_receive {:EXIT, ^channel_pid, {:shutdown, :suspended}}
    end

    test "leaves that venue's shift room channel alone" do
      # KTD18 confines suspension to the venue room. The nudge arrives on the
      # shift room's channel too, because the topic is per engagement, and
      # ignoring it there is the decision rather than the fall-through: a person
      # who opts out of the standing conversation is still on the roster.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, employer: employer, engagement: engagement} = world.a
      room = shift_room(employer, engagement)

      {:ok, _venue_reply, venue_channel} =
        subscribe_and_join(world.socket, venue_topic(venue), %{})

      {:ok, _shift_reply, shift_channel} =
        subscribe_and_join(world.socket, shift_topic(room), %{})

      venue_pid = venue_channel.channel_pid
      shift_pid = shift_channel.channel_pid

      assert {:ok, _suspension} = Rooms.suspend_venue_room(world.person, venue.id)

      assert_receive {:EXIT, ^venue_pid, {:shutdown, :suspended}}
      refute_receive {:EXIT, ^shift_pid, _reason}
      assert Process.alive?(shift_pid)

      assert {:ok, _rejoined, _channel} = join(world.socket, shift_topic(room), %{})
    end

    test "leaves the other venue's room channel joined" do
      # The suspension is per engagement, so it says nothing about the venue the
      # person did not opt out of. Without this, a nudge broadcast per person
      # would pass the test above.
      Process.flag(:trap_exit, true)
      world = two_venues()

      {:ok, _a_reply, a_channel} =
        subscribe_and_join(world.socket, venue_topic(world.a.venue), %{})

      {:ok, _b_reply, b_channel} =
        subscribe_and_join(world.socket, venue_topic(world.b.venue), %{})

      a_pid = a_channel.channel_pid
      b_pid = b_channel.channel_pid

      assert {:ok, _suspension} = Rooms.suspend_venue_room(world.person, world.b.venue.id)

      assert_receive {:EXIT, ^b_pid, {:shutdown, :suspended}}
      refute_receive {:EXIT, ^a_pid, _reason}
      assert Process.alive?(a_pid)
    end

    test "refuses the rejoin that follows, and admits it again after a resume" do
      # The guarantee behind the nudge, and its control. `join/3` re-derives
      # membership, which is U6's predicate minus a suspension — so the refusal
      # holds whether or not any broadcast arrived, and lifting the suspension
      # lifts it.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue} = world.a

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})
      channel_pid = channel.channel_pid

      assert {:ok, _suspension} = Rooms.suspend_venue_room(world.person, venue.id)
      assert_receive {:EXIT, ^channel_pid, {:shutdown, :suspended}}

      assert {:error, refusal} = join(world.socket, venue_topic(venue), %{})
      assert refusal.error == @refused

      assert {:ok, _resumed} = Rooms.resume_venue_room(world.person, venue.id)
      assert {:ok, _rejoined, _rejoined_channel} = join(world.socket, venue_topic(venue), %{})
    end

    test "a suspension that writes nothing announces nothing" do
      # The after-commit ordering `Engagements.announce/1` already has, applied
      # here: a nudge for a write that did not happen would close a channel
      # whose access never ended. The first suspension broadcasting is asserted
      # above, so this is not "the topic is silent" passing for want of a
      # working broadcast.
      world = two_venues()
      %{venue: venue, engagement: engagement} = world.a

      assert {:ok, _suspension} = Rooms.suspend_venue_room(world.person, venue.id)

      :ok = Engagements.subscribe(engagement.id)

      assert {:error, :already_suspended} = Rooms.suspend_venue_room(world.person, venue.id)
      refute_receive {:venue_room_suspended, _notice}
    end
  end

  describe "a subscriber that missed the announcement" do
    test "is reached by the sweeper's, which is what bounds every lost nudge" do
      # **The bound**, and the reason U7's review item about `join/3` reading
      # membership before it subscribes is recorded rather than fixed. A
      # revocation committing in that window broadcasts to nobody — but the
      # subscription exists a statement later, so the *next* thing that
      # announces the same expiry reaches it.
      #
      # This models that window at the level it happens: subscribe after the
      # broadcast, then let the backstop run. `EngagementSweeper` finds the
      # closed term inside its 24h lookback and inserts the same
      # `ExpireEngagement` changeset the claim would have — and because
      # `end_engagement/2` rewrote `ends_at`, which is one of the job's
      # uniqueness args, that insert does not collide with the job scheduled for
      # the original bound.
      #
      # Every test above already asserts that a channel subscribed to this topic
      # stops when this message arrives, so the chain is complete: worst case is
      # one sweep interval, not for ever.
      world = two_venues()
      %{venue: venue, employer: employer, engagement: engagement} = world.a
      engagement_id = engagement.id

      assert {:ok, ended} = Engagements.end_engagement(employer, engagement.id)

      :ok = Engagements.subscribe(engagement.id)
      refute_receive {:engagement_revoked, _missed}

      assert {:ok, %{swept: swept, enqueued: enqueued}} = perform_job(EngagementSweeper, %{})
      assert swept >= 1
      assert enqueued >= 1

      assert perform_job(ExpireEngagement, %{
               "engagement_id" => engagement.id,
               "venue_id" => venue.id,
               "ends_at" => DateTime.to_iso8601(ended.ends_at)
             }) == {:ok, :revoked}

      assert_receive {:engagement_revoked, %{engagement_id: ^engagement_id}}
    end
  end

  describe "an unmatched message on the engagement topic" do
    test "leaves every channel joined under that engagement alive" do
      # The engagement topic is shared by every channel that engagement opened,
      # so a message no clause matches does not crash one channel — it crashes
      # all of them at once, and `handle_info/2` being exported is what stops
      # Phoenix falling back to warn-and-ignore. The blast radius is why this is
      # asserted across two channels rather than one.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, employer: employer, engagement: engagement} = world.a
      room = shift_room(employer, engagement)

      {:ok, _venue_reply, venue_channel} =
        subscribe_and_join(world.socket, venue_topic(venue), %{})

      {:ok, _shift_reply, shift_channel} =
        subscribe_and_join(world.socket, shift_topic(room), %{})

      venue_pid = venue_channel.channel_pid
      shift_pid = shift_channel.channel_pid

      :ok =
        Phoenix.PubSub.broadcast(
          HospitalityComs.PubSub,
          Engagements.topic(engagement.id),
          {:something_a_later_unit_broadcasts, %{engagement_id: engagement.id}}
        )

      refute_receive {:EXIT, ^venue_pid, _venue_reason}
      refute_receive {:EXIT, ^shift_pid, _shift_reason}
      assert Process.alive?(venue_pid)
      assert Process.alive?(shift_pid)
    end

    test "leaves them functional, not merely alive" do
      # The control. A channel that had stopped answering would still be alive
      # for as long as the assertion above looks at it.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, engagement: engagement} = world.a

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})

      :ok =
        Phoenix.PubSub.broadcast(
          HospitalityComs.PubSub,
          Engagements.topic(engagement.id),
          :a_bare_atom_nobody_planned_for
        )

      ref = push(channel, "send", %{"body" => "the channel is still here"})
      assert_reply ref, :ok, _sent
    end
  end

  describe "a revocation naming a different engagement" do
    test "does not stop this channel" do
      # It cannot arrive today, because the subscription is per engagement.
      # Asserting it keeps that a property of the channel rather than an
      # assumption about the topic it happens to be subscribed to.
      Process.flag(:trap_exit, true)
      world = two_venues()
      %{venue: venue, engagement: engagement} = world.a

      {:ok, _reply, channel} = subscribe_and_join(world.socket, venue_topic(venue), %{})
      channel_pid = channel.channel_pid

      :ok =
        Phoenix.PubSub.broadcast(
          HospitalityComs.PubSub,
          Engagements.topic(engagement.id),
          {:engagement_revoked,
           %{engagement_id: Ecto.UUID.generate(), venue_id: venue.id, at: @now}}
        )

      refute_receive {:EXIT, ^channel_pid, _reason}
      refute_receive %Phoenix.Socket.Message{event: "access_revoked"}
      assert Process.alive?(channel_pid)
    end
  end

  ## Fixtures

  defp venue_topic(venue), do: "venue_room:" <> venue.id
  defp shift_topic(room), do: "shift_room:" <> room.id

  # One person, two employers, one socket. The shape origin R7 and AE1 are
  # about, and the reason the socket id is per session rather than per person.
  defp two_venues do
    person = person_scope_fixture(@now)

    %{
      a: venue_with_engagement(person),
      b: venue_with_engagement(person),
      person: person,
      socket: person_socket(person)
    }
  end

  defp venue_with_engagement(person) do
    creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)

    engagement =
      engagement_fixture(employer, person, %{starts_at: @now, ends_at: @term_ends})

    %{venue: creation.venue, employer: employer, engagement: engagement}
  end

  # An engagement holding the venue's only live grant, which `end_engagement/2`
  # refuses to close (R22, KTD17) — and the refusal rolls the transaction back,
  # which is what makes it the rolled-back change this file needs.
  defp sole_manager do
    %{venue: venue, grant: grant} = creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: @now,
        ends_at: @term_ends,
        grant_id: grant.id
      })

    %{venue: venue, employer: employer, engagement: engagement, socket: person_socket(person)}
  end

  defp shift_room(employer, engagement) do
    shift_type = shift_type_fixture(employer, 30)
    room = shift_room_fixture(employer, shift_type, @opens, @ends)
    roster_entry_fixture(employer, room, engagement.id)
    room
  end

  defp person_socket(person) do
    {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person.person, @now)))
    socket
  end
end
