defmodule HospitalityComs.PeersTest do
  @moduledoc """
  The peer graph: a derived interval, a state machine, and an employer who is
  not in either.

  ## Why this file is not sandboxed

  For `HospitalityComs.EngagementsFixtures`' reason. Visibility is derived from
  engagements; an engagement needs an invitation written through
  `HospitalityComs.EmployerRepo` and a claim written through
  `HospitalityComs.Repo`, and under the sandbox those are two transactions that
  cannot see each other's rows. Everything here commits for real and is purged
  on a name prefix before and after each test.

  ## What the boundary assertions here are for

  `HospitalityComs.BoundaryTest` asserts the privilege bits and the
  classification. What it cannot assert is the *behaviour* those buy, because
  populating the peer graph needs a person and a venue visible to the same
  connection — which is exactly the split that made U5's bridge tests live here
  rather than there. So "an employer-scoped session cannot resolve a
  conversation between two of its own staff" is asserted in this file, three
  ways, against a conversation that actually exists.
  """

  use ExUnit.Case, async: false

  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.PeersFixtures

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.EmployerRepo.ZoneViolationError
  alias HospitalityComs.Engagements
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.Conversation
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Peers.Records
  alias HospitalityComs.Peers.Visibility
  alias HospitalityComs.Repo
  alias HospitalityComs.Zones

  @now ~U[2026-03-01 12:00:00.000000Z]

  # A month-long term, which is what `co_rostered/2` gives both people by
  # default.
  @term_ends DateTime.add(@now, 30, :day)

  @tail_days 30

  # The builders that begin or shape a *read*. `Ecto.Query.Builder.Filter`,
  # `.Select` and `.Update` are deliberately absent: they are the `where`,
  # `RETURNING` and `SET` of a write statement, and banning them would make the
  # rule something to work around.
  @read_builders [
    Ecto.Query.Builder,
    Ecto.Query.Builder.From,
    Ecto.Query.Builder.Join,
    Ecto.Query.Builder.Lock,
    Ecto.Query.Builder.OrderBy,
    Ecto.Query.Builder.Distinct,
    Ecto.Query.Builder.GroupBy,
    Ecto.Query.Builder.Preload
  ]

  @peers_namespace "Elixir.HospitalityComs.Peers."

  setup do
    real_connections()
  end

  describe "visibility" do
    test "exists between two people engaged at one venue over overlapping terms" do
      %{first: first, second: second} = co_rostered(@now)

      assert Peers.visible?(first, second.person.id)
      assert Peers.visible?(second, first.person.id)
    end

    test "does not exist between people at two different venues" do
      # The control for the whole of this describe block: a predicate answering
      # `false` for everything satisfies every negative assertion below on its
      # own, and the test above is what stops that.
      %{first: first} = co_rostered(@now)
      %{first: elsewhere} = co_rostered(@now)

      refute Peers.visible?(first, elsewhere.person.id)
      refute Peers.visible?(elsewhere, first.person.id)
    end

    test "does not exist between people at one venue whose terms do not overlap" do
      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: DateTime.add(@now, 10, :day)},
          second: %{
            starts_at: DateTime.add(@now, 10, :day),
            ends_at: DateTime.add(@now, 20, :day)
          }
        })

      # Half-open, so terms that abut share no instant and are not concurrent.
      # Asked well inside the tail of both, so the refusal is about the overlap
      # rather than about the thirty days.
      refute Peers.visible?(person_at(first, DateTime.add(@now, 15, :day)), second.person.id)
    end

    test "is not what `connected?/2` answers, and the difference outlives the tail" do
      # U9's `HospitalityComs.Profiles.fetch_peer_profile/2` needs "is this a
      # peer" to mean *visible or connected*, so the second half is a predicate
      # of its own. It takes no instant, because a connection has no term: it is
      # live until one of them ends it, which is R13's "permanent" and what makes
      # the plan's payoff moment reachable.
      #
      # Asserted against the same pair at two instants, so the two predicates
      # are seen to disagree rather than merely to exist.
      %{first: first, second: second} = co_rostered(@now)

      refute Peers.connected?(first, second.person.id)

      connection = connection_fixture(first, second)

      assert Peers.connected?(first, second.person.id)
      assert Peers.connected?(second, first.person.id)

      lapsed = person_at(first, DateTime.add(@now, 90, :day))
      refute Peers.visible?(lapsed, second.person.id)
      assert Peers.connected?(lapsed, second.person.id)

      {:ok, _closed} = Peers.disconnect(first, connection.id)

      refute Peers.connected?(first, second.person.id)
      refute Peers.connected?(second, first.person.id)
    end

    test "and `connected?/2` answers false for an id that names nobody, and for oneself" do
      # The control the predicate above needs, for the reason `visible?/2` has
      # one: an answer that discloses nothing about which ids are real.
      %{first: first} = co_rostered(@now)

      refute Peers.connected?(first, Ecto.UUID.generate())
      refute Peers.connected?(first, first.person.id)
    end

    test "begins at the later of the two starts and not before" do
      later = DateTime.add(@now, 5, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: @term_ends},
          second: %{starts_at: later, ends_at: @term_ends}
        })

      refute Peers.visible?(person_at(first, DateTime.add(later, -1, :second)), second.person.id)
      assert Peers.visible?(person_at(first, later), second.person.id)
    end

    test "persists twenty-nine days after the engagements end and has lapsed at thirty-one" do
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      assert Peers.visible?(person_at(first, DateTime.add(ends_at, 29, :day)), second.person.id)
      refute Peers.visible?(person_at(first, DateTime.add(ends_at, 31, :day)), second.person.id)
    end

    test "lapses at exactly thirty days, which is the half-open upper bound" do
      # The two assertions above bracket the boundary; this is the boundary. A
      # tail implemented with `>=` passes both of them and fails this.
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      lapse = DateTime.add(ends_at, @tail_days, :day)

      assert Peers.visible?(person_at(first, DateTime.add(lapse, -1, :second)), second.person.id)
      refute Peers.visible?(person_at(first, lapse), second.person.id)
    end

    test "keys its tail on the first engagement to end, not the last" do
      # The plan's wording, and a real decision rather than a detail: somebody
      # who left in January stops being visible to a colleague who is still
      # employed there. Keying on the last would keep a whole venue's staff
      # visible for as long as any one of them stayed.
      first_ends = DateTime.add(@now, 10, :day)
      second_ends = DateTime.add(@now, 300, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: first_ends},
          second: %{starts_at: @now, ends_at: second_ends}
        })

      asked_at = DateTime.add(first_ends, @tail_days + 1, :day)

      # Well inside the second engagement, and well past the first's tail.
      assert DateTime.compare(asked_at, second_ends) == :lt
      refute Peers.visible?(person_at(first, asked_at), second.person.id)
      refute Peers.visible?(person_at(second, asked_at), first.person.id)
    end

    test "is not created by an engagement that was ended before it started" do
      # U5's widening produces `ends_at == starts_at` — the empty range, active
      # at no instant. An empty interval overlaps nothing, and the endpoint
      # form of the overlap test without its emptiness clauses says otherwise.
      opens_at = DateTime.add(@now, 5, :day)

      %{employer: employer, first: first, second: second, second_engagement: engagement} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: @term_ends},
          second: %{starts_at: opens_at, ends_at: @term_ends}
        })

      assert {:ok, ended} = Engagements.end_engagement(employer, engagement.id)
      assert ended.ends_at == ended.starts_at

      refute Peers.visible?(person_at(first, opens_at), second.person.id)
      refute Peers.visible?(person_at(first, DateTime.add(opens_at, 1, :day)), second.person.id)

      # And from the emptied engagement's own side, which is a different clause
      # of the predicate rather than the same one restated. `co_engagements/1`
      # tests each term for emptiness separately, and `own` is always the
      # asking person's — so asking only from `first` binds the empty term to
      # `peer` every time and leaves `own.starts_at < own.ends_at` unexercised.
      # Dropping just that clause passes every assertion above.
      refute Peers.visible?(person_at(second, opens_at), first.person.id)
      refute Peers.visible?(person_at(second, DateTime.add(opens_at, 1, :day)), first.person.id)
    end

    test "comes from each stint separately, so a stale one grants nothing" do
      # Two overlapping pairs of engagements at one venue are two intervals and
      # are not merged: the union of two intervals is not an interval, and
      # merging them would make the gap between the stints disappear.
      old_ends = DateTime.add(@now, 10, :day)
      new_starts = DateTime.add(@now, 200, :day)
      new_ends = DateTime.add(@now, 260, :day)

      %{employer: employer, first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: old_ends},
          second: %{starts_at: @now, ends_at: old_ends}
        })

      engage(employer, first, %{starts_at: new_starts, ends_at: new_ends}, @now)
      engage(employer, second, %{starts_at: new_starts, ends_at: new_ends}, @now)

      # Between the two stints: the first has run its tail out and the second
      # has not opened.
      between = DateTime.add(old_ends, @tail_days + 1, :day)
      assert DateTime.compare(between, new_starts) == :lt
      refute Peers.visible?(person_at(first, between), second.person.id)

      # And inside the second, which is what says the fixture built two.
      assert Peers.visible?(person_at(first, new_starts), second.person.id)
    end

    test "lists the shared venue and the counterpart's employer-authored label" do
      %{venue_id: venue_id, first: first, second: second} =
        co_rostered(@now, %{second: %{role_label: "Head Chef"}})

      assert [%Visibility{} = peer] = Peers.list_visible_peers(first)

      assert peer.person_id == second.person.id
      assert peer.venue_id == venue_id
      assert peer.venue_name =~ venue_prefix()
      assert peer.role_label == "Head Chef"
      # Second precision, because the engagement bounds these are derived from
      # are `:utc_datetime` like everything else in the schema.
      assert peer.visible_from == DateTime.truncate(@now, :second)

      assert peer.visible_until ==
               @term_ends |> DateTime.truncate(:second) |> DateTime.add(@tail_days, :day)
    end

    test "discloses no email address in the peer list" do
      # A negative assertion with the test above as its control: a projection
      # that returned nothing at all would satisfy this alone. `people.email` is
      # the only other identifying column there is, and a peer list is not the
      # place to hand it out.
      %{first: first, second: second} = co_rostered(@now)

      assert [%Visibility{} = peer] = Peers.list_visible_peers(first)

      refute peer |> Map.from_struct() |> Map.values() |> Enum.member?(second.person.email)
      refute :email in (peer |> Map.from_struct() |> Map.keys())
    end

    test "gives one entry per venue when the same pair worked at two of them" do
      %{first: first, second: second} = co_rostered(@now)
      {elsewhere, _creation} = scoped_venue_fixture(@now)

      engage(elsewhere, first, %{}, @now)
      engage(elsewhere, second, %{}, @now)

      assert [one, two] = Peers.list_visible_peers(first)
      assert one.person_id == second.person.id
      assert two.person_id == second.person.id
      assert MapSet.new([one.venue_id, two.venue_id]) |> MapSet.size() == 2
    end

    test "gives one entry per venue when the same pair worked two stints at one" do
      # The list is one entry per counterpart per venue, and two stints at one
      # venue are one entry rather than two. Before this it returned one row per
      # overlapping *pair of engagements*, so a client keying on `person_id`
      # got the same person twice with two `visible_until` values and possibly
      # two role labels.
      #
      # Merging is safe here and only here: every interval in the list contains
      # the asking instant, so their union is an interval and no gap is lost.
      # The predicate `visible?/2` rests on is untouched and still ranges over
      # every pair.
      old_ends = DateTime.add(@now, 10, :day)
      new_starts = DateTime.add(@now, 20, :day)
      new_ends = DateTime.add(@now, 50, :day)

      %{employer: employer, first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: old_ends},
          second: %{starts_at: @now, ends_at: old_ends}
        })

      engage(employer, first, %{starts_at: new_starts, ends_at: new_ends}, @now)

      engage(
        employer,
        second,
        %{starts_at: new_starts, ends_at: new_ends, role_label: "Head Chef"},
        @now
      )

      # Inside the older stint's tail and inside the newer stint, so both
      # intervals are live and the query returns two rows to fold.
      asked_at = DateTime.add(@now, 25, :day)

      assert [%Visibility{} = peer] = Peers.list_visible_peers(person_at(first, asked_at))
      assert peer.person_id == second.person.id

      # The union: it opened when the first stint made them concurrent and runs
      # to thirty days past the end of the second.
      assert peer.visible_from == DateTime.truncate(@now, :second)

      assert peer.visible_until ==
               new_ends |> DateTime.truncate(:second) |> DateTime.add(@tail_days, :day)

      # And the label is the one on the stint that runs longest, which is the
      # counterpart's current role rather than whichever row sorted first.
      assert peer.role_label == "Head Chef"
    end

    test "agrees with the rendered interval over a matrix of term pairs and instants" do
      # The control for every assertion above, and the one thing that would
      # catch the SQL predicate and the struct drifting apart. It is the same
      # manoeuvre `HospitalityComs.RoomsTest` makes against the generated
      # `open_period` column: two spellings of one rule, compared rather than
      # described.
      #
      # It compares against `Visibility.visible_at?/2` — the *shipped* Elixir
      # spelling of the whole predicate — and not against a rule restated here.
      # It used to call `covers?/2` and restate the overlap half in this file,
      # which made half the matrix a comparison of the SQL against its own
      # test's idea of it. The "gapped" shape below is the case that exposed it:
      # two terms separated by less than the thirty-day tail produce endpoints
      # whose derived interval contains the instant, so `covers?/2` alone says
      # visible and the SQL says nothing of the kind.
      own = {@now, DateTime.add(@now, 10, :day)}

      shapes = [
        {"identical", {@now, DateTime.add(@now, 10, :day)}},
        {"partial", {DateTime.add(@now, 5, :day), DateTime.add(@now, 20, :day)}},
        {"abutting after", {DateTime.add(@now, 10, :day), DateTime.add(@now, 20, :day)}},
        {"abutting before", {DateTime.add(@now, -20, :day), @now}},
        {"contained", {DateTime.add(@now, 2, :day), DateTime.add(@now, 4, :day)}},
        {"gapped after", {DateTime.add(@now, 12, :day), DateTime.add(@now, 20, :day)}},
        {"gapped before", {DateTime.add(@now, -20, :day), DateTime.add(@now, -2, :day)}}
      ]

      instants =
        Enum.map(
          [-1, 0, 3, 10, 11, 39, 40, 41, 60],
          &DateTime.add(@now, &1, :day)
        )

      {employer, _creation} = scoped_venue_fixture(@now)
      viewer = person_scope_fixture(@now)
      engage(employer, viewer, %{starts_at: elem(own, 0), ends_at: elem(own, 1)}, @now)

      counterparts =
        Enum.map(shapes, fn {name, {starts_at, ends_at}} ->
          person = person_scope_fixture(@now)
          engage(employer, person, %{starts_at: starts_at, ends_at: ends_at}, @now)
          {name, {starts_at, ends_at}, person}
        end)

      for {name, term, person} <- counterparts, instant <- instants do
        expected = expected_visibility(own, term, instant)
        actual = Peers.visible?(person_at(viewer, instant), person.person.id)

        assert actual == expected,
               "#{name} at #{instant}: SQL said #{actual}, the struct said #{expected}"
      end
    end
  end

  describe "requesting a connection" do
    test "creates a pending request both parties can see" do
      %{first: first, second: second} = co_rostered(@now)

      assert {:ok, %ConnectionRequest{} = request} =
               Peers.request_connection(first, second.person.id)

      assert request.requester_id == first.person.id
      assert request.addressee_id == second.person.id
      assert request.state == :pending

      assert [outgoing] = Peers.list_outgoing_requests(first)
      assert outgoing.id == request.id
      assert outgoing.state == :pending

      assert [incoming] = Peers.list_incoming_requests(second)
      assert incoming.id == request.id
      assert incoming.state == :pending
    end

    test "refuses somebody this person is not co-rostered with" do
      %{first: first} = co_rostered(@now)
      %{first: stranger} = co_rostered(@now)

      assert {:error, :visible, :not_visible, _changes} =
               Peers.request_connection(first, stranger.person.id)
    end

    test "gives an id that names nobody the identical refusal" do
      # AE1: the refusal enumerates nothing. A caller cannot tell a real person
      # they cannot see from an id that is not a person at all.
      %{first: first} = co_rostered(@now)

      assert {:error, :visible, :not_visible, _changes} =
               Peers.request_connection(first, Ecto.UUID.generate())
    end

    test "refuses a request to oneself" do
      %{first: first} = co_rostered(@now)

      assert {:error, :visible, :not_visible, _changes} =
               Peers.request_connection(first, first.person.id)
    end

    test "refuses a second request while one is outstanding" do
      %{first: first, second: second} = co_rostered(@now)
      request_fixture(first, second)

      assert {:error, :permitted, :already_requested, _changes} =
               Peers.request_connection(first, second.person.id)

      # And from the other side: an outstanding approach is the pair's, not the
      # requester's.
      assert {:error, :permitted, :already_requested, _changes} =
               Peers.request_connection(second, first.person.id)
    end

    test "refuses a request between two people who are already connected" do
      %{first: first, second: second} = co_rostered(@now)
      connection_fixture(first, second)

      assert {:error, :permitted, :already_connected, _changes} =
               Peers.request_connection(first, second.person.id)
    end

    test "supersedes the pair's previous row rather than leaving two current" do
      %{first: first, second: second} = co_rostered(@now)
      declined = request_fixture(first, second)
      {:ok, _declined} = Peers.decline_request(second, declined.id)

      assert {:ok, fresh} = Peers.request_connection(second, first.person.id)

      assert Repo.get!(ConnectionRequest, declined.id).superseded_at != nil
      assert Repo.get!(ConnectionRequest, fresh.id).superseded_at == nil
      assert current_requests(first.person.id, second.person.id) == 1
    end

    test "reads the same state through fetch_request/2 as through the lists" do
      # Four places derive a request's state and they have to agree, because
      # "the pair's state is one row" is only true if every reader picks the
      # same row. They agreed about `:lapsed` and disagreed about *superseded*:
      # `fetch_request/2` did not filter `superseded_at IS NULL`, so a row that
      # `accept_request/2` and `decline_request/2` both answer `:not_found` for
      # came back reporting a state anyway.
      %{first: first, second: second} = co_rostered(@now)
      declined = request_fixture(first, second)
      {:ok, _declined} = Peers.decline_request(second, declined.id)
      {:ok, fresh} = Peers.request_connection(second, first.person.id)

      assert {:ok, %ConnectionRequest{state: :pending, id: fetched}} =
               Peers.fetch_request(first, fresh.id)

      assert [%ConnectionRequest{state: :pending, id: listed}] =
               Peers.list_outgoing_requests(second)

      assert fetched == listed

      # The superseded row is in neither, and the writes agree.
      assert {:error, :not_found} = Peers.fetch_request(first, declined.id)
      assert Peers.list_outgoing_requests(first) == []
      assert {:error, :not_found} = Peers.decline_request(second, declined.id)
    end
  end

  describe "a lapsed request" do
    test "reports :lapsed to the requester once visibility has gone" do
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      request_fixture(first, second)

      lapsed_at = DateTime.add(ends_at, @tail_days + 1, :day)

      assert [%ConnectionRequest{state: :lapsed}] =
               Peers.list_outgoing_requests(person_at(first, lapsed_at))
    end

    test "cannot be accepted" do
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      request = request_fixture(first, second)
      lapsed_at = DateTime.add(ends_at, @tail_days + 1, :day)

      assert {:error, :visible, :lapsed, _changes} =
               Peers.accept_request(person_at(second, lapsed_at), request.id)

      # And the answer rolled back with it, so the request is outstanding again.
      assert Repo.get!(ConnectionRequest, request.id).accepted_at == nil
    end

    test "can still be declined, because an addressee may always say no" do
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      request = request_fixture(first, second)
      lapsed_at = DateTime.add(ends_at, @tail_days + 1, :day)

      assert {:ok, declined} = Peers.decline_request(person_at(second, lapsed_at), request.id)
      assert declined.state == :declined
    end

    test "reports :pending again once the pair is co-rostered afresh" do
      # The consequence of deriving the state rather than storing it, stated so
      # that it is a decision rather than a discovery. Nothing was destroyed
      # when visibility went, so nothing has to be undestroyed when it returns;
      # a stored `expired_at` would have needed a job to visit every outstanding
      # request whenever any engagement moved.
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      request_fixture(first, second)

      lapsed_at = DateTime.add(ends_at, @tail_days + 1, :day)

      assert [%ConnectionRequest{state: :lapsed}] =
               Peers.list_outgoing_requests(person_at(first, lapsed_at))

      {elsewhere, _creation} = scoped_venue_fixture(lapsed_at)
      engage(elsewhere, first, %{}, lapsed_at)
      engage(elsewhere, second, %{}, lapsed_at)

      assert [%ConnectionRequest{state: :pending}] =
               Peers.list_outgoing_requests(person_at(first, lapsed_at))
    end
  end

  describe "declining" do
    test "blocks the requester and leaves the decliner free to ask" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert {:ok, declined} = Peers.decline_request(second, request.id)
      assert declined.blocked_initiator_id == first.person.id
      assert declined.state == :declined
    end

    test "stops the declined requester re-sending" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)
      {:ok, _declined} = Peers.decline_request(second, request.id)

      assert {:error, :permitted, :blocked, _changes} =
               Peers.request_connection(first, second.person.id)
    end

    test "leaves the declining party able to initiate themselves" do
      # KTD19 read forwards, and the control for the assertion above: a rule
      # that blocked both parties would satisfy it.
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)
      {:ok, _declined} = Peers.decline_request(second, request.id)

      assert {:ok, fresh} = Peers.request_connection(second, first.person.id)
      assert fresh.requester_id == second.person.id
      assert fresh.state == :pending
    end

    test "survives the pair being co-rostered again at a different venue" do
      # The block is a column on the request row rather than a rule over
      # employment, and this is the whole of what that buys.
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      request = request_fixture(first, second)
      {:ok, _declined} = Peers.decline_request(second, request.id)

      much_later = DateTime.add(ends_at, 200, :day)
      {elsewhere, _creation} = scoped_venue_fixture(much_later)
      engage(elsewhere, first, %{}, much_later)
      engage(elsewhere, second, %{}, much_later)

      later_first = person_at(first, much_later)
      later_second = person_at(second, much_later)

      # Visible again — which is what makes the refusal below about the block
      # rather than about the tail having run out.
      assert Peers.visible?(later_first, second.person.id)

      assert {:error, :permitted, :blocked, _changes} =
               Peers.request_connection(later_first, second.person.id)

      assert {:ok, %ConnectionRequest{}} =
               Peers.request_connection(later_second, first.person.id)
    end

    test "is refused by Postgres when the block is left unwritten" do
      # `connection_requests_decline_blocks_requester` is what makes KTD19's
      # decline half a property of the schema rather than of one function, and
      # it did not. A CHECK is satisfied by NULL and `NULL = requester_id` is
      # NULL, so `declined_at IS NULL OR blocked_initiator_id = requester_id`
      # *passed* for a declined row with no block on it — which is the one row
      # the constraint exists to refuse. The invariant rested entirely on
      # `decline_request/2` writing both columns in one statement.
      #
      # Written through `Repo` rather than the context on purpose: the context
      # is the tier this is meant to be independent of.
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert_raise Postgrex.Error,
                   ~r/connection_requests_decline_blocks_requester/,
                   fn ->
                     request.id
                     |> Records.request_by_id()
                     |> Repo.update_all(set: [declined_at: DateTime.truncate(@now, :second)])
                   end

      # The control: the same write with the block on it is accepted, so the
      # refusal above is about the NULL and not about the column being
      # unwritable.
      assert {1, _rows} =
               request.id
               |> Records.request_by_id()
               |> Repo.update_all(
                 set: [
                   declined_at: DateTime.truncate(@now, :second),
                   blocked_initiator_id: first.person.id
                 ]
               )
    end

    test "refuses a request addressed to somebody else, one already answered, and nothing" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert {:error, :not_found} = Peers.decline_request(first, request.id)
      assert {:error, :not_found} = Peers.decline_request(second, Ecto.UUID.generate())

      assert {:ok, _declined} = Peers.decline_request(second, request.id)
      assert {:error, :not_found} = Peers.decline_request(second, request.id)
    end
  end

  describe "accepting" do
    test "creates a connection both parties can read" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert {:ok, %Connection{} = connection} = Peers.accept_request(second, request.id)
      assert connection.request_id == request.id

      assert [%Conversation{} = theirs] = Peers.list_conversations(first)
      assert theirs.connection_id == connection.id
      assert theirs.peer_id == second.person.id
      assert theirs.open?

      assert [%Conversation{} = mine] = Peers.list_conversations(second)
      assert mine.connection_id == connection.id
      assert mine.peer_id == first.person.id
      assert mine.open?
    end

    test "stores the pair in one order whichever way round the request went" do
      # What makes "one live connection per pair" expressible as a unique index.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert connection.person_a_id < connection.person_b_id

      assert MapSet.new([connection.person_a_id, connection.person_b_id]) ==
               MapSet.new([first.person.id, second.person.id])
    end

    test "refuses a request addressed to somebody else, one this person sent, and nothing" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert {:error, :answer, :not_found, _changes} = Peers.accept_request(first, request.id)

      assert {:error, :answer, :not_found, _changes} =
               Peers.accept_request(second, Ecto.UUID.generate())
    end

    test "refuses a second acceptance of the same request" do
      %{first: first, second: second} = co_rostered(@now)
      request = request_fixture(first, second)

      assert {:ok, %Connection{}} = Peers.accept_request(second, request.id)
      assert {:error, :answer, :not_found, _changes} = Peers.accept_request(second, request.id)
    end
  end

  describe "a connection" do
    test "survives both engagements ending, and still carries messages" do
      # R13's "permanent", and the plan's payoff moment from the peer side:
      # visibility gates discovery and gates nothing about a conversation that
      # already exists.
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      connection = connection_fixture(first, second)

      long_after = DateTime.add(ends_at, 400, :day)
      later_first = person_at(first, long_after)
      later_second = person_at(second, long_after)

      refute Peers.visible?(later_first, second.person.id)
      assert [%Conversation{open?: true}] = Peers.list_conversations(later_first)

      assert {:ok, %PeerMessage{}} =
               Peers.send_message(later_first, connection.id, "still here")

      assert {:ok, [%PeerMessage{body: "still here"}]} =
               Peers.list_messages(later_second, connection.id)
    end

    test "carries both parties' messages, oldest first" do
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      {:ok, _one} = Peers.send_message(first, connection.id, "one")

      {:ok, _two} =
        Peers.send_message(
          person_at(second, DateTime.add(@now, 1, :minute)),
          connection.id,
          "two"
        )

      {:ok, _three} =
        Peers.send_message(
          person_at(first, DateTime.add(@now, 2, :minute)),
          connection.id,
          "three"
        )

      assert {:ok, messages} = Peers.list_messages(second, connection.id)
      assert Enum.map(messages, & &1.body) == ["one", "two", "three"]
    end

    test "refuses a message from somebody who is not a party to it" do
      %{first: first, second: second} = co_rostered(@now)
      %{first: outsider} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert {:error, :not_found} = Peers.send_message(outsider, connection.id, "hello")
      assert {:error, :not_found} = Peers.list_messages(outsider, connection.id)
      assert {:error, :not_found} = Peers.fetch_conversation(outsider, connection.id)
      assert {:error, :not_found} = Peers.send_message(first, Ecto.UUID.generate(), "hello")
    end

    test "refuses an empty body and an over-long one as changeset errors" do
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert {:error, %Ecto.Changeset{} = blank} =
               Peers.send_message(first, connection.id, "   ")

      assert "can't be blank" in errors_on(blank).body

      too_long = String.duplicate("x", PeerMessage.max_body_length() + 1)

      assert {:error, %Ecto.Changeset{} = long} =
               Peers.send_message(first, connection.id, too_long)

      refute Enum.empty?(errors_on(long).body)
    end
  end

  describe "disconnecting" do
    test "closes the conversation for both, from either side" do
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert {:ok, closed} = Peers.disconnect(first, connection.id)
      assert closed.disconnected_by_id == first.person.id

      assert [%Conversation{open?: false}] = Peers.list_conversations(first)
      assert [%Conversation{open?: false}] = Peers.list_conversations(second)

      assert {:error, :disconnected} = Peers.send_message(first, connection.id, "again")
      assert {:error, :disconnected} = Peers.send_message(second, connection.id, "again")
    end

    test "closes it identically when the other party is the one who ends it" do
      # Unilateral in both directions. Without this the assertion above is
      # satisfied by a rule that only lets the requester disconnect.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert {:ok, closed} = Peers.disconnect(second, connection.id)
      assert closed.disconnected_by_id == second.person.id

      assert [%Conversation{open?: false}] = Peers.list_conversations(first)
      assert {:error, :disconnected} = Peers.send_message(first, connection.id, "again")
    end

    test "leaves each party their own messages and only their own" do
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      {:ok, _mine} = Peers.send_message(first, connection.id, "mine")
      {:ok, _yours} = Peers.send_message(second, connection.id, "yours")

      {:ok, _closed} = Peers.disconnect(first, connection.id)

      assert {:ok, [%PeerMessage{body: "mine"}]} = Peers.list_messages(first, connection.id)
      assert {:ok, [%PeerMessage{body: "yours"}]} = Peers.list_messages(second, connection.id)
    end

    test "deletes nothing, so both messages are still rows" do
      # The control for the assertion above: a `list_messages/2` that returned
      # `[]` after a disconnect would satisfy "only their own", and so would one
      # that destroyed the other person's words. Deletion is
      # `HospitalityComs.Lifecycle`'s alone (KTD21).
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      {:ok, _mine} = Peers.send_message(first, connection.id, "mine")
      {:ok, _yours} = Peers.send_message(second, connection.id, "yours")
      {:ok, _closed} = Peers.disconnect(first, connection.id)

      assert message_count(connection.id) == 2
    end

    test "blocks the counterpart of whoever disconnected, and not the disconnector" do
      # KTD19's disconnect half. Disconnection is the origin document's only
      # stated remedy for harm in a peer conversation, so the party who used it
      # keeps the initiative and the party it was used against does not.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      {:ok, _closed} = Peers.disconnect(first, connection.id)

      assert Repo.get!(ConnectionRequest, connection.request_id).blocked_initiator_id ==
               second.person.id

      assert {:error, :permitted, :blocked, _changes} =
               Peers.request_connection(second, first.person.id)
    end

    test "leaves the disconnector able to ask again, and acceptance reconnects them" do
      # "Without fresh acceptance", read forwards. The blocked party cannot
      # initiate and is connectable again the moment the other party asks.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)
      {:ok, _closed} = Peers.disconnect(first, connection.id)

      assert {:ok, fresh} = Peers.request_connection(first, second.person.id)
      assert {:ok, %Connection{} = reconnected} = Peers.accept_request(second, fresh.id)

      refute reconnected.id == connection.id

      # Both conversations are listed, the closed one included, because each
      # party still reads their own messages in it. Compared as a set: the two
      # rows share `connected_at` under a pinned clock, so the list's
      # `(connected_at, id)` order has nothing meaningful to say between them.
      assert %{reconnected.id => true, connection.id => false} ==
               Map.new(Peers.list_conversations(first), &{&1.connection_id, &1.open?})
    end

    test "stops consulting the old block once a fresh acceptance has happened" do
      # The current-row rule. Blocks are read off the pair's one current row, so
      # a fresh acceptance replaces the verdict rather than accumulating beside
      # it — which is what stops a pair who each refused the other once being
      # permanently unreachable to both.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)
      {:ok, _closed} = Peers.disconnect(first, connection.id)

      fresh = request_fixture(first, second)
      {:ok, reconnected} = Peers.accept_request(second, fresh.id)
      {:ok, _closed_again} = Peers.disconnect(second, reconnected.id)

      # The second disconnect was `second`'s, so now `first` is the blocked one
      # and `second` is free — the opposite of the first round.
      assert {:error, :permitted, :blocked, _changes} =
               Peers.request_connection(first, second.person.id)

      assert {:ok, %ConnectionRequest{}} = Peers.request_connection(second, first.person.id)
    end

    test "refuses a second disconnect and one by somebody who is not a party" do
      %{first: first, second: second} = co_rostered(@now)
      %{first: outsider} = co_rostered(@now)
      connection = connection_fixture(first, second)

      assert {:error, :close, :not_found, _changes} = Peers.disconnect(outsider, connection.id)

      assert {:error, :close, :not_found, _changes} =
               Peers.disconnect(first, Ecto.UUID.generate())

      assert {:ok, _closed} = Peers.disconnect(first, connection.id)

      assert {:error, :close, :already_disconnected, _changes} =
               Peers.disconnect(second, connection.id)
    end
  end

  describe "a person holding no engagements at all" do
    test "still reads and writes the conversations they already have" do
      # The demo's payoff, from the peer side. Nothing in a conversation
      # consults an engagement, which is what makes this true rather than
      # nearly true.
      ends_at = DateTime.add(@now, 10, :day)

      %{first: first, second: second} =
        co_rostered(@now, %{
          first: %{starts_at: @now, ends_at: ends_at},
          second: %{starts_at: @now, ends_at: ends_at}
        })

      connection = connection_fixture(first, second)

      after_everything = DateTime.add(ends_at, 500, :day)
      unemployed = person_at(first, after_everything)

      assert Engagements.list_person_engagements(unemployed) == []
      assert Peers.list_visible_peers(unemployed) == []
      assert [%Conversation{open?: true}] = Peers.list_conversations(unemployed)
      assert {:ok, %PeerMessage{}} = Peers.send_message(unemployed, connection.id, "hello")
    end
  end

  describe "an employer-scoped session" do
    test "cannot compose a query that reaches a peer conversation" do
      # The backstop, which arrives before Postgres is asked and names the
      # table. Against a conversation that actually exists, which is the half
      # `HospitalityComs.BoundaryTest` cannot assert.
      %{employer: employer, first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)
      {:ok, _message} = Peers.send_message(first, connection.id, "not for you")

      assert_raise ZoneViolationError, ~r/peer_messages/, fn ->
        EmployerRepo.scoped_transaction(employer, fn _scope ->
          {:ok, EmployerRepo.all(PeerMessage)}
        end)
      end

      assert_raise ZoneViolationError, ~r/peer_connections/, fn ->
        EmployerRepo.scoped_transaction(employer, fn _scope ->
          {:ok, EmployerRepo.all(Connection)}
        end)
      end

      assert_raise ZoneViolationError, ~r/connection_requests/, fn ->
        EmployerRepo.scoped_transaction(employer, fn _scope ->
          {:ok, EmployerRepo.all(ConnectionRequest)}
        end)
      end
    end

    test "is refused by Postgres too, where the backstop cannot see" do
      # Raw SQL goes to `Ecto.Adapters.SQL` without `prepare_query/3`, so the
      # backstop never sees it. This is the tier that answers when it does not:
      # the grants, which are the only tier whose violation is an error rather
      # than a leak.
      %{first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)
      {:ok, _message} = Peers.send_message(first, connection.id, "not for you")

      for table <- ~w(connection_requests peer_connections peer_messages) do
        assert_raise Postgrex.Error, ~r/permission denied for table #{table}/, fn ->
          EmployerRepo.query!("SELECT count(*) FROM #{table}", [])
        end
      end
    end

    test "is refused by every function in the context, by function clause" do
      # The scope split, which is the refusal being available at compile-shaped
      # cost rather than as a runtime check somebody has to remember to write.
      %{employer: employer, first: first, second: second} = co_rostered(@now)
      connection = connection_fixture(first, second)

      # Laundered through a map fetch, exactly as
      # `HospitalityComs.BoundaryTest`'s `scope/1` is and for the same reason:
      # handed the struct literally, the type checker sees the refusal at the
      # *call site* and warns. That is a good warning and a bad test — a scope
      # built at run time from a session carries no such proof, and it is the
      # run-time refusal the boundary rests on.
      wrong = dynamic(employer)
      anonymous = dynamic(PersonScope.for_person(nil, @now))

      Enum.each([wrong, anonymous], fn scope ->
        assert_raise FunctionClauseError, fn -> Peers.list_conversations(scope) end
        assert_raise FunctionClauseError, fn -> Peers.list_visible_peers(scope) end
        assert_raise FunctionClauseError, fn -> Peers.list_incoming_requests(scope) end
        assert_raise FunctionClauseError, fn -> Peers.list_outgoing_requests(scope) end
        assert_raise FunctionClauseError, fn -> Peers.visible?(scope, second.person.id) end
        assert_raise FunctionClauseError, fn -> Peers.fetch_request(scope, connection.id) end

        assert_raise FunctionClauseError, fn ->
          Peers.request_connection(scope, second.person.id)
        end

        assert_raise FunctionClauseError, fn -> Peers.accept_request(scope, connection.id) end
        assert_raise FunctionClauseError, fn -> Peers.decline_request(scope, connection.id) end
        assert_raise FunctionClauseError, fn -> Peers.list_messages(scope, connection.id) end
        assert_raise FunctionClauseError, fn -> Peers.fetch_conversation(scope, connection.id) end
        assert_raise FunctionClauseError, fn -> Peers.disconnect(scope, connection.id) end
        assert_raise FunctionClauseError, fn -> Peers.send_message(scope, connection.id, "x") end
      end)

      # The control. Without it every assertion above is satisfied by a context
      # that refuses everything, which is not the same guarantee at all.
      assert %EmployerScope{} = employer
      assert Peers.list_conversations(first) != []
      assert Peers.visible?(first, second.person.id)
    end

    test "holds no privilege on any peer table, with a control that says so" do
      # The sweep `HospitalityComs.BoundaryTest` runs, pointed here, and the
      # grant that would make it answer. Not sandboxed, so the grant is revoked
      # in the same test rather than rolled back — which is also what proves the
      # revoke reaches the object it names.
      assert Zones.privileges(Repo, peer_tables()) == []

      Repo.query!("GRANT SELECT (body) ON peer_messages TO employer_role")

      try do
        assert {"peer_messages", "SELECT"} in Zones.employer_privileges(Repo)
      after
        Repo.query!("REVOKE ALL PRIVILEGES ON TABLE peer_messages FROM employer_role")
      end

      assert Zones.privileges(Repo, peer_tables()) == []
    end
  end

  describe "the rule that Records owns every query" do
    # Structural, from the compiled `imports` chunk, the way
    # `HospitalityComs.Accounts.PersonZoneTest` reads a module's repo calls out
    # of the BEAM rather than out of a grep. It exists because the rule was
    # already broken and nothing noticed: `disconnect/2` built
    # `from(request in ConnectionRequest, where: …)` inline, which is a query
    # over a schema at a call site — the exact thing `AGENTS.md` says belongs in
    # the owning module.
    #
    # A whole-namespace sweep, so a new `HospitalityComs.Peers.*` module is
    # covered on the day it is written rather than on the day somebody adds it
    # to a list.

    test "is a fact about the compiled modules, not a convention" do
      # The builders that *begin* or *shape* a read. `Ecto.Query.Builder.From`
      # is the one that matters most — it is what `from(x in Schema)` compiles
      # to, and it cannot appear outside `Records` without a query having been
      # built somewhere else.
      offenders =
        Enum.filter(peer_modules(), fn module ->
          module != Records and
            module |> query_builders() |> Enum.any?(&(&1 in @read_builders))
        end)

      assert offenders == []
    end

    test "leaves the context the three builders a write statement needs" do
      # Not a loophole and worth naming, because a check that banned every
      # `Ecto.Query` call from the context would have to be worked around
      # rather than obeyed. `HospitalityComs.Peers` composes `where` onto a
      # conditional `update_all`, `select` for its `RETURNING`, and `update` for
      # its `SET` — three parts of a *write*, each applied to a query `Records`
      # handed it. None of them can name a schema.
      builders = query_builders(Peers)

      assert Enum.sort(builders) ==
               Enum.sort([
                 Ecto.Query.Builder.Filter,
                 Ecto.Query.Builder.Select,
                 Ecto.Query.Builder.Update
               ])
    end

    test "reads a chunk that actually says something, which is the control" do
      # Without this the assertions above pass against a namespace sweep that
      # returned nothing, or against an `imports` chunk that stopped being
      # readable. `Records` is the module that must contain `from`.
      modules = peer_modules()

      assert Peers in modules
      assert Records in modules
      assert Visibility in modules
      refute HospitalityComs.PeersFixtures in modules

      assert Ecto.Query.Builder in query_builders(Records)
      assert Ecto.Query.Builder.From in query_builders(Records)
    end

    test "leaves the channel building no query at all" do
      # The other half of "the channel calls the context; the context calls
      # Records". A transport that composed a query would be authorising in the
      # web layer.
      assert query_builders(HospitalityComsWeb.PeerChannel) == []
    end
  end

  ## Helpers

  defp peer_modules do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)

    Enum.filter(modules, fn module ->
      name = Atom.to_string(module)

      name == "Elixir.HospitalityComs.Peers" or String.starts_with?(name, @peers_namespace)
    end)
  end

  defp query_builders(module) do
    {:ok, {^module, [imports: imports]}} =
      module |> :code.which() |> :beam_lib.chunks([:imports])

    imports
    |> Enum.map(fn {called, _function, _arity} -> called end)
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Ecto.Query.Builder"))
  end

  defp peer_tables, do: ~w(connection_requests peer_connections peer_messages)

  # A scope the type checker cannot see the shape of, which is the shape a real
  # caller's scope has. See the call site.
  defp dynamic(scope), do: Map.fetch!(%{scope: scope}, :scope)

  # The Elixir spelling of the interval, used only to say what the SQL predicate
  # should have answered. Every clause of it comes from `HospitalityComs.Peers
  # .Visibility`, so the matrix compares the *shipped* Elixir rule against the
  # *shipped* query and not against a third spelling that lives in this file.
  defp expected_visibility({own_from, own_to}, {peer_from, peer_to}, instant) do
    Visibility.visible_at?(
      %{
        person_id: Ecto.UUID.generate(),
        venue_id: Ecto.UUID.generate(),
        venue_name: "irrelevant",
        role_label: "irrelevant",
        own_starts_at: own_from,
        own_ends_at: own_to,
        peer_starts_at: peer_from,
        peer_ends_at: peer_to
      },
      instant
    )
  end

  defp current_requests(person_id, other_person_id) do
    person_id |> Records.current_request(other_person_id) |> Repo.aggregate(:count)
  end

  defp message_count(connection_id) do
    connection_id |> Records.messages_of() |> Repo.aggregate(:count)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
