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
  alias HospitalityComs.Peers
  alias HospitalityComs.Venues
  alias HospitalityComsWeb.EmployerSocket
  alias HospitalityComsWeb.PersonAuth
  alias HospitalityComsWeb.PersonSocket

  @now HospitalityComs.EngagementsFixtures.fixed_instant()
  @term_ends DateTime.add(@now, 30, :day)
  @opens DateTime.add(@now, 1, :hour)
  @closes DateTime.add(@now, 9, :hour)

  @refused_room %{code: "unauthorized", message: "this session is not in that venue's room"}

  describe "connecting a person socket" do
    test "authenticates the token the transport carried" do
      person = person_fixture(@now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
      assert socket.assigns.person_id == person.id
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
      assert first.assigns.person_id == second.assigns.person_id
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
      assert socket.assigns.person_id == person.id
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

  describe "a socket whose session has ended" do
    test "is refused at join after the token row is deleted, with no disconnect broadcast" do
      # **The hole U7's review found.** `connect/3` authenticated once and the
      # socket carried the person for ever; the credential was never derived
      # again. Log-out happened to work, because `disconnect_sessions/1`
      # broadcasts to the socket's id — so the guarantee rested on a *nudge*,
      # and any deletion that skipped that path left a socket joining channels
      # against a session that no longer exists.
      #
      # `Accounts.delete_person_session_token/1` is that path: it deletes the
      # row and returns it, and it is the controller that broadcasts. Nothing
      # broadcasts here.
      %{venue: venue, socket: socket, raw_token: raw} = engaged()

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, venue_topic(venue), %{})

      assert {:ok, _deleted} = Accounts.delete_person_session_token(raw)

      assert {:error, refusal} = join(socket, venue_topic(venue), %{})
      assert refusal.error == @refused_room
    end

    test "is refused at join once the token's own horizon passes" do
      # The case no broadcast covers at all: nothing fires when a token simply
      # ages out, so a socket connected on day 1 kept joining channels on day
      # 20 — past the 14-day horizon `PersonToken.session_validity_in_days/0`
      # names. The engagement runs 30 days, so what refuses this is the session
      # and not the membership.
      %{venue: venue, socket: socket} = engaged()

      assert {:ok, _reply, _channel} = subscribe_and_join(socket, venue_topic(venue), %{})

      at(DateTime.add(@now, PersonToken.session_validity_in_days() + 1, :day))

      assert {:error, refusal} = join(socket, venue_topic(venue), %{})
      assert refusal.error == @refused_room
    end

    test "is refused on every topic the two sockets route" do
      # One socket, four channels, one credential. A re-derivation on the venue
      # room alone would leave three ways in.
      %{venue: venue, room: room, socket: socket, employer_socket: employer, raw_token: raw} =
        engaged_manager()

      assert {:ok, _venue, _a} = subscribe_and_join(socket, venue_topic(venue), %{})
      assert {:ok, _shift, _b} = subscribe_and_join(socket, shift_topic(room), %{})
      assert {:ok, _peer, _c} = subscribe_and_join(socket, peer_topic(socket), %{})
      assert {:ok, _emp, _d} = subscribe_and_join(employer, employer_topic(venue), %{})

      assert {:ok, _deleted} = Accounts.delete_person_session_token(raw)

      assert {:error, _venue_refusal} = join(socket, venue_topic(venue), %{})
      assert {:error, _shift_refusal} = join(socket, shift_topic(room), %{})
      assert {:error, _peer_refusal} = join(socket, peer_topic(socket), %{})
      assert {:error, _employer_refusal} = join(employer, employer_topic(venue), %{})
    end

    test "still joins while the token row is live, which is the control" do
      # Every refusal above passes against a `join/3` that refused everything.
      %{venue: venue, room: room, socket: socket, employer_socket: employer} = engaged_manager()

      assert {:ok, _venue, _a} = subscribe_and_join(socket, venue_topic(venue), %{})
      assert {:ok, _shift, _b} = subscribe_and_join(socket, shift_topic(room), %{})
      assert {:ok, _peer, _c} = subscribe_and_join(socket, peer_topic(socket), %{})
      assert {:ok, _emp, _d} = subscribe_and_join(employer, employer_topic(venue), %{})
    end
  end

  describe "what a connected socket carries" do
    test "is the person's id and the session's digest, and no person record" do
      # A channel crash report is `inspect/1` of the socket, so anything in
      # assigns is in the logs. The socket used to carry the whole `%Person{}`,
      # email included, and items 4, 5 and 6 of U7's review were three reachable
      # ways to get one printed.
      person = person_fixture(@now)
      raw = Accounts.generate_person_session_token(person, @now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(PersonAuth.encode_token(raw)))

      assert socket.assigns.person_id == person.id
      assert socket.assigns.token_digest == PersonToken.hash_token(raw)
      refute Map.has_key?(socket.assigns, :person)
    end

    test "prints no email when the whole socket is inspected" do
      # The assertion in the shape the failure took: a crash report is the
      # inspected socket, and the leak was that the address was in it.
      person = person_fixture(@now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))
      refute socket |> inspect(limit: :infinity) |> String.contains?(person.email)
    end

    test "carries the digest and never the token the client holds" do
      # U2 hashed session tokens at rest precisely so that a leak yields
      # digests. Putting the raw token on the socket to re-derive with would
      # have handed it back.
      person = person_fixture(@now)
      raw = Accounts.generate_person_session_token(person, @now)

      assert {:ok, socket} = connect(PersonSocket, %{}, auth(PersonAuth.encode_token(raw)))

      refute socket |> inspect(limit: :infinity) |> String.contains?(inspect(raw))
      refute raw in Map.values(socket.assigns)
    end
  end

  describe "the employer socket's routing table (KTD9)" do
    test "has no peer topic in it at all" do
      # The table itself, not a behaviour. This is the assertion that cannot be
      # satisfied by an authorization check somebody added inside a join.
      person_id = Ecto.UUID.generate()

      assert EmployerSocket.__channel__("peer:" <> person_id) == nil
      assert EmployerSocket.__channel__("peer") == nil

      assert {HospitalityComsWeb.PeerChannel, _opts} =
               PersonSocket.__channel__("peer:" <> person_id)
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

      topic = "peer:" <> person.id

      assert_raise RuntimeError, ~r/no channel found for topic "peer:/, fn ->
        subscribe_and_join(socket, topic, %{})
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

      assert {:ok, reply, channel} = subscribe_and_join(socket, "peer:" <> person.id, %{})
      assert reply == %{person_id: person.id}

      # The suffix is the person, so the channel's own Phoenix topic is the
      # topic `HospitalityComs.Peers` announces on — which is what makes a
      # `broadcast/3` from that channel reach one person rather than the whole
      # cluster. An exact `"peer"` topic put every peer channel in one group.
      assert channel.topic == Peers.topic(person.id)
    end

    test "refuses a peer topic naming somebody else, and a suffix that is not an id" do
      # The routing table can only say "a peer topic"; which person's it is has
      # to be decided at the join, and this is that decision. Both refusals are
      # the same one, so a caller cannot learn from the answer whether the id
      # they named is a real person.
      person = person_fixture(@now)
      {:ok, socket} = connect(PersonSocket, %{}, auth(session_token(person, @now)))

      assert {:error, somebody_else} =
               join(socket, "peer:" <> Ecto.UUID.generate(), %{})

      assert {:error, malformed} = join(socket, "peer:not-a-uuid", %{})

      assert somebody_else.error.code == "unauthorized"
      assert somebody_else.error == malformed.error

      # The control: the same socket joins its own.
      assert {:ok, _reply, _channel} =
               subscribe_and_join(socket, "peer:" <> person.id, %{})
    end

    test "has no employer venue topic" do
      # The partition is two-way at the transport as well as in
      # `HospitalityComs.PubSub`.
      assert PersonSocket.__channel__("employer_venue:" <> Ecto.UUID.generate()) == nil
    end
  end

  ## Fixtures

  # The peer topic names the person the socket authenticated as, so it is
  # derived from the socket rather than passed in — a literal here would be a
  # second place the suffix rule is written.
  defp peer_topic(socket), do: Peers.topic(socket.assigns.person_id)

  defp venue_topic(venue), do: "venue_room:" <> venue.id
  defp shift_topic(room), do: "shift_room:" <> room.id
  defp employer_topic(venue), do: "employer_venue:" <> venue.id

  # A worker at one venue, on a socket built from a token the test still holds
  # the raw bytes of — so it can delete the row the way a caller that skips
  # `disconnect_sessions/1` would.
  defp engaged do
    creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{starts_at: @now, ends_at: @term_ends})

    raw = Accounts.generate_person_session_token(person.person, @now)
    {:ok, socket} = connect(PersonSocket, %{}, auth(PersonAuth.encode_token(raw)))

    %{
      venue: creation.venue,
      employer: employer,
      person: person,
      engagement: engagement,
      raw_token: raw,
      socket: socket
    }
  end

  # The same person holding a grant as well, so all four topics are reachable
  # from one credential.
  defp engaged_manager do
    %{venue: venue, grant: founding} = creation = venue_fixture(@now)
    employer = employer_scope_fixture(creation, @now)
    person = person_scope_fixture(@now)

    {:ok, held} = Venues.issue_grant(employer)

    engagement =
      engagement_fixture(employer, person, %{
        starts_at: @now,
        ends_at: @term_ends,
        grant_id: held.id
      })

    shift_type = shift_type_fixture(employer, 30)
    room = shift_room_fixture(employer, shift_type, @opens, @closes)
    roster_entry_fixture(employer, room, engagement.id)

    raw = Accounts.generate_person_session_token(person.person, @now)
    {:ok, socket} = connect(PersonSocket, %{}, auth(PersonAuth.encode_token(raw)))
    {:ok, employer_socket} = connect(EmployerSocket, %{}, auth(PersonAuth.encode_token(raw)))

    %{
      venue: venue,
      founding_grant: founding,
      grant: held,
      room: room,
      engagement: engagement,
      raw_token: raw,
      socket: socket,
      employer_socket: employer_socket
    }
  end
end
