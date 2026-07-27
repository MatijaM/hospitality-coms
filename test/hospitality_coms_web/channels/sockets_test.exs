defmodule HospitalityComsWeb.SocketsTest do
  @moduledoc """
  Two socket modules, two routing tables, and one id per session.

  ## What KTD9 actually claims

  That an employer session cannot reach a peer conversation *through the
  transport*, and that the refusal happens in Phoenix's own dispatch rather than
  in a `join/3` somebody had to remember to guard. The claim is about the
  absence of a routing entry, so it is asserted twice: against
  `__channel__/1`, which is the table itself, and against a join attempt, which
  is what a client does.

  It is also asserted **with a control**. A socket module with an empty routing
  table refuses every topic, which would satisfy "the employer socket refuses
  the peer topic" while meaning nothing at all. So the same topic is joined on
  `HospitalityComsWeb.PersonSocket` in the same file and has to work.

  ## What KTD7 actually claims

  That the id is the session. Two sessions for one person must therefore produce
  two ids, and the id must be the same string
  `HospitalityComsWeb.PersonAuth.disconnect_sessions/1` broadcasts `"disconnect"`
  to — otherwise logging out is a no-op against an open socket, silently. Both
  are asserted directly on `id/1` rather than only through behaviour, because
  the behaviour they protect is a *non*-event: the Venue A session staying up.
  """

  use HospitalityComsWeb.ChannelCase

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComsWeb.EmployerSocket
  alias HospitalityComsWeb.PersonAuth
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()

  describe "connecting a person socket" do
    test "authenticates the token the transport carried" do
      person = person_fixture(@now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
      assert socket.assigns.person.id == person.id
    end

    test "names the socket after the session, not the person (KTD7)" do
      # The digest, base64url, behind `session:`. Not the token: a socket id is
      # a PubSub topic, and a topic crosses distributed Erlang on every
      # broadcast and shows up in telemetry.
      person = person_fixture(@now)
      raw = Accounts.generate_person_session_token(person, @now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(PersonAuth.encode_token(raw)))

      assert socket.id ==
               "session:" <>
                 PersonAuth.encode_token(PersonToken.hash_token(raw))
    end

    test "gives two sessions of one person two different ids" do
      # KTD7's whole content. A per-person id would make the two sockets one,
      # so ending the Venue B engagement — or logging one browser out — would
      # take the other down, which origin R7 and AE1 both forbid.
      person = person_fixture(@now)

      assert {:ok, first} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
      assert {:ok, second} = connect(PersonSocket, %{}, auth(session_token(person, @now)))

      assert first.id != second.id
      assert first.assigns.person.id == second.assigns.person.id
    end

    test "names the topic log-out already broadcasts disconnect to" do
      # Two spellings that drifted would leave `disconnect_sessions/1`
      # broadcasting into the void and an ended session holding a live socket.
      person = person_fixture(@now)
      raw = Accounts.generate_person_session_token(person, @now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(PersonAuth.encode_token(raw)))
      assert socket.id == PersonAuth.session_topic(PersonToken.hash_token(raw))
    end

    test "refuses a missing, malformed, or unknown token identically" do
      # One answer for all three. A socket that told them apart would be an
      # oracle for which tokens exist.
      unknown = PersonAuth.encode_token(:crypto.strong_rand_bytes(32))

      assert :error = connect(PersonSocket, %{}, connect_info: %{})
      assert :error = connect(PersonSocket, %{}, auth(""))
      assert :error = connect(PersonSocket, %{}, auth("not base64url!!"))
      assert :error = connect(PersonSocket, %{}, auth(unknown))
    end

    test "refuses a token whose row has expired" do
      # The instant reaches the token query, which is what makes this derived
      # rather than a job's responsibility.
      person = person_fixture(@now)
      long_ago = DateTime.add(@now, -PersonToken.session_validity_in_days() - 1, :day)

      assert :error = connect(PersonSocket, %{}, auth(session_token(person, long_ago)))
    end

    test "refuses a token whose row has been deleted" do
      # The revocation U2 built and U7 inherits: the row is the session.
      person = person_fixture(@now)
      raw = Accounts.generate_person_session_token(person, @now)
      encoded = PersonAuth.encode_token(raw)

      assert {:ok, _socket} = connect(PersonSocket, %{}, auth(encoded))
      assert {:ok, _ended} = Accounts.delete_person_session_token(raw)
      assert :error = connect(PersonSocket, %{}, auth(encoded))
    end
  end

  describe "connecting an employer socket" do
    test "authenticates the same credential" do
      # There is no separate employer login. A manager's authority derives from
      # a grant and `engagements.grant_id` records that they hold one, so the
      # credential is the person's session and the venue arrives on the topic.
      person = person_fixture(@now)

      assert {:ok, socket} = connect(EmployerSocket, %{}, auth(session_token(person, @now)))
      assert socket.assigns.person.id == person.id
    end

    test "gives the same session the same id as the person socket" do
      # So that logging out disconnects both transports of that session, and
      # neither transport of any other.
      person = person_fixture(@now)
      token = session_token(person, @now)

      assert {:ok, worker} = connect(PersonSocket, %{}, auth(token))
      assert {:ok, manager} = connect(EmployerSocket, %{}, auth(token))

      assert worker.id == manager.id
    end

    test "does not refuse a person holding no grant anywhere" do
      # Deliberate, and the reason is KTD8: connect authenticates, join
      # authorises. The venue is not known at connect, so the question cannot be
      # asked here — and the joins all fail, which is the same outcome arrived
      # at where the venue is known.
      person = person_fixture(@now)

      assert {:ok, _socket} = connect(EmployerSocket, %{}, auth(session_token(person, @now)))
    end
  end

  describe "the employer socket's routing table (KTD9)" do
    test "has no peer topic in it at all" do
      # The table itself, not a behaviour. This is the assertion that cannot be
      # satisfied by an authorization check somebody added inside a join.
      assert EmployerSocket.__channel__("peer") == nil
      assert {HospitalityComsWeb.PeerChannel, _opts} = PersonSocket.__channel__("peer")
    end

    test "has no room topic in it either" do
      # Room conversation is worker-facing: `employer_role` holds no privilege
      # at all on `room_messages` (U6), and a manager reads their venue's room
      # through their own engagement on the person socket. It follows that no
      # room's presence is observable from an employer session (KTD18).
      venue_id = Ecto.UUID.generate()
      room_id = Ecto.UUID.generate()

      assert EmployerSocket.__channel__("venue_room:" <> venue_id) == nil
      assert EmployerSocket.__channel__("shift_room:" <> room_id) == nil

      assert {HospitalityComsWeb.VenueRoomChannel, _venue_opts} =
               PersonSocket.__channel__("venue_room:" <> venue_id)

      assert {HospitalityComsWeb.ShiftRoomChannel, _shift_opts} =
               PersonSocket.__channel__("shift_room:" <> room_id)
    end

    test "refuses a join to a peer topic as an unmatched topic" do
      # What a client sees. The dispatch has no entry, so nothing in
      # `HospitalityComsWeb` runs — no scope is built and no query is issued.
      person = person_fixture(@now)
      {:ok, socket} = connect(EmployerSocket, %{}, auth(session_token(person, @now)))

      assert_raise RuntimeError, ~r/no channel found for topic "peer"/, fn ->
        subscribe_and_join(socket, "peer", %{})
      end
    end

    test "routes only the employer venue topic" do
      %{venue: venue, grant: grant} = creation = venue_fixture(@now)
      employer = employer_scope_fixture(creation, @now)
      manager = person_scope_fixture(@now)
      engagement_fixture(employer, manager, %{grant_id: grant.id})

      {:ok, socket} = connect(EmployerSocket, %{}, auth(session_token(manager.person, @now)))

      assert {:ok, reply, _channel} =
               subscribe_and_join(socket, "employer_venue:" <> venue.id, %{})

      assert reply == %{venue_id: venue.id, grant_id: grant.id}
    end
  end

  describe "the person socket's routing table" do
    test "joins the multiplexed peer topic (KTD10)" do
      # The control for both employer-socket refusals above, and the assertion
      # that peer conversations have one channel rather than one each.
      person = person_fixture(@now)
      {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))

      assert {:ok, reply, _channel} = subscribe_and_join(socket, "peer", %{})
      assert reply == %{person_id: person.id}
    end

    test "has no employer venue topic" do
      # The partition is two-way at the transport as well as in
      # `HospitalityComs.PubSub`.
      assert PersonSocket.__channel__("employer_venue:" <> Ecto.UUID.generate()) == nil
    end
  end
end
