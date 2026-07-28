defmodule HospitalityComs.LifecycleTest do
  @moduledoc """
  Erasure, venue closure, and the rule that only this context deletes.

  ## What erasure is, and the two ways of getting it wrong

  It **pseudonymises** (KTD15). Every referencing table forces a choice between
  `CASCADE`, which destroys records the design commits to keeping, and
  `SET NULL`, which drops an engagement out of the overlap exclusion constraint
  entirely — so neither is taken and the person row stays, with `erased_at` set
  and `email` nulled in the same write.

  The first way to be wrong is to delete too much, and the second is to delete
  too little. Both are asserted, side by side, because either alone reads as
  coverage:

    * too much — `connection_requests` survives (it is the counterpart's block
      record, KTD19, and `peer_connections.request_id` is `NOT NULL ON DELETE
      RESTRICT`), the disclosure ledger survives from both sides, another
      person's Oban jobs survive, the survivor's own peer messages survive, and
      no `room_messages` row is touched at all;
    * too little — every token is gone, every engagement is ended, every live
      connection is disconnected, the erased party's peer messages are gone,
      their declared entries are gone, their retained copies are gone and stay
      gone, and their scheduled jobs are gone.

  ## Why the disclosure ledger is *kept*, which is the counter-intuitive half

  A disclosure row only ever narrows what an audience sees. Deleting one
  therefore **discloses more**, and peer visibility runs for thirty days past an
  engagement's end — so an erasure that tidied the ledger away would re-reveal,
  to every peer, exactly the entries the worker had hidden, at the moment they
  asked for erasure. That is asserted rather than described.

  ## Why this file is not sandboxed

  `EngagementsFixtures.real_connections/0`, for U5's reason: a venue is written
  through `HospitalityComs.EmployerRepo` and the person zone through
  `HospitalityComs.Repo`, and under the sandbox those are two transactions that
  cannot see each other's rows.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: HospitalityComs.Repo

  import Ecto.Query
  import HospitalityComs.EngagementsFixtures

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Lifecycle.Records
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.PeersFixtures
  alias HospitalityComs.Profiles
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.RoomsFixtures
  alias HospitalityComs.Rosters
  alias HospitalityComs.Venues.Venue
  alias HospitalityComs.Workers.ExpireEngagement

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_month DateTime.add(@now, 30, :day)
  @after_the_end DateTime.add(@in_a_month, 1, :hour)
  @started DateTime.add(@now, -10, :day)

  # A shift inside `populated/0`'s venue, so `shift_rooms`, `roster_entries` and
  # a shift-room message all exist.
  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)
  @during_shift DateTime.add(@now, 2, :hour)

  # Every module that may not delete is read out of the application, so a
  # context added by a later unit is covered on the day it compiles.
  @repos [HospitalityComs.Repo, HospitalityComs.EmployerRepo]
  @delete_functions [:delete, :delete!, :delete_all]

  # The receivers the source sweep treats as deletion. An alias whose last
  # segment is one of these, or a bare variable — which is what `repo` is inside
  # an `Ecto.Multi.run/3` callback, and the form the `imports` chunk cannot see.
  # `Map.delete/2` and `Process.delete/1` are aliases that are not on this list.
  @delete_receivers [:Repo, :EmployerRepo, :Multi]

  # `oban_peers` is Oban's leadership table and nothing writes it under
  # `testing: :manual`, so it is the one base table `populated/0` cannot reach.
  # Named rather than skipped silently: it is also the one table a future
  # carve-out could hide in.
  @unpopulatable ["oban_peers"]

  setup do
    real_connections()
  end

  ## Ending every engagement

  describe "erasure and the engagements the person holds" do
    test "ends a live engagement in the same transaction" do
      %{person: person, engagement: engagement} = engaged()

      assert {:ok, erasure} = Lifecycle.erase_person(person_at(person, @now))
      assert erasure.engagements_ended == 1

      assert %Engagement{ends_at: ends_at} = Repo.get!(Engagement, engagement.id)
      assert DateTime.compare(ends_at, @now) == :eq
      refute Engagements.active?(Repo.get!(Engagement, engagement.id), @now)
    end

    test "leaves a term that had already closed exactly where it was" do
      # The control for the test above: an ending update with no condition on
      # `ends_at` satisfies that one and rewrites this engagement's upper bound
      # to the erasure instant, moving a term that closed a month ago.
      %{person: person, engagement: engagement} = engaged()

      later = DateTime.add(@in_a_month, 1, :day)

      assert {:ok, _erasure} = Lifecycle.erase_person(person_at(person, later))
      assert %Engagement{ends_at: ends_at} = Repo.get!(Engagement, engagement.id)
      assert DateTime.compare(ends_at, engagement.ends_at) == :eq
    end

    test "closes a term that has not started at its own opening, freeing the dates" do
      # `end_engagement/2`'s rule, reached from the erasure side: the empty
      # range is active at no instant and overlaps nothing, so the person's
      # dates are free rather than reserved for a term nobody will work. A
      # closure at the erasure instant would be `ends_at < starts_at`, which the
      # generated range refuses outright.
      %{employer: employer, person: person} = future_engagement()

      assert {:ok, erasure} = Lifecycle.erase_person(person_at(person, @now))
      assert erasure.engagements_ended == 1

      assert [%Engagement{starts_at: starts_at, ends_at: ends_at}] =
               Repo.all(from(e in Engagement, where: e.venue_id == ^employer.venue_id))

      assert DateTime.compare(ends_at, starts_at) == :eq
    end

    test "reduces every engagement's label, including one whose term is over" do
      %{employer: employer, person: person, engagement: engagement} = engaged()

      past =
        PeersFixtures.engage(
          employer,
          person,
          %{
            role_label: "Head Chef",
            starts_at: DateTime.add(@now, -400, :day),
            ends_at: DateTime.add(@now, -300, :day)
          },
          @now
        )

      assert {:ok, erasure} = Lifecycle.erase_person(person_at(person, @now))
      assert erasure.labels_reduced == 2

      for id <- [engagement.id, past.id] do
        assert %Engagement{role_label: label} = Repo.get!(Engagement, id)
        assert label == Lifecycle.erased_label()
      end
    end
  end

  ## The person row

  describe "erasure and the person row" do
    test "leaves the row present, pseudonymised, with erased_at set" do
      %{person: person} = engaged()

      assert {:ok, %{person: erased}} = Lifecycle.erase_person(person_at(person, @now))

      assert %Person{email: nil, erased_at: %DateTime{} = at} = Repo.get!(Person, erased.id)
      assert DateTime.compare(at, @now) == :eq
    end

    test "changes those two columns and leaves every other one alone" do
      # KTD15's whole claim is that the row *stays*, and the test above is a
      # pattern match on two fields of a five-column table — so `confirmed_at`,
      # `inserted_at` and `id` were unconstrained. Measured: a `pseudonymise/2`
      # that also nulled `confirmed_at` passed eighty-eight tests. This is the
      # `Map.keys/1` control U9 wrote for `VisibleEntry`, pointed at the row
      # erasure is about.
      %{person: person} = engaged()

      # Confirmed by hand rather than through a magic link, because a null
      # `confirmed_at` before and after would make the mutation above invisible
      # again for exactly the reason the count comparison was: nothing changed.
      confirm(person.person.id)

      later = DateTime.add(@now, 1, :hour)
      before = person_row(person.person.id)

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, later))

      erased = person_row(person.person.id)
      changed = for {field, value} <- before, Map.fetch!(erased, field) != value, do: field

      assert Enum.sort(changed) == [:email, :erased_at, :updated_at]
      assert erased.email == nil
      assert %DateTime{} = erased.confirmed_at
    end

    test "lets two erased people coexist on the partial unique index" do
      %{person: first} = engaged()
      %{person: second} = engaged()

      assert {:ok, _} = Lifecycle.erase_person(person_at(first, @now))
      assert {:ok, _} = Lifecycle.erase_person(person_at(second, @now))

      erased =
        Repo.all(
          from(p in Person,
            where: p.id in ^[first.person.id, second.person.id],
            select: p.email
          )
        )

      assert erased == [nil, nil]
    end

    test "deletes every token, so the session no longer authenticates" do
      %{person: person} = engaged()
      token = Accounts.generate_person_session_token(person.person, @now)

      assert {%Person{}, _at} = Accounts.get_person_by_session_token(token, @now)

      assert {:ok, %{tokens: tokens}} = Lifecycle.erase_person(person_at(person, @now))
      assert length(tokens) == 1

      assert Accounts.get_person_by_session_token(token, @now) == nil
      assert Repo.all(from(t in PersonToken, where: t.person_id == ^person.person.id)) == []
    end

    test "refuses a second erasure" do
      %{person: person} = engaged()

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))
      assert {:error, :already_erased} = Lifecycle.erase_person(person_at(person, @now))
    end

    test "erases a person holding nothing at all" do
      person = person_scope_fixture(@now)

      assert {:ok, erasure} = Lifecycle.erase_person(person)
      assert erasure.engagements_ended == 0
      assert erasure.peer_messages_deleted == 0
      assert erasure.jobs_cancelled == 0
      assert %Person{erased_at: %DateTime{}} = Repo.get!(Person, person.person.id)
    end
  end

  ## KTD17's exemption

  describe "erasing a venue's sole grant-holder" do
    test "succeeds and leaves the venue orphaned" do
      %{employer: employer, person: manager} = managed_venue()

      assert {:ok, _erasure} = Lifecycle.erase_person(person_at(manager, @now))

      assert Enum.map(Lifecycle.orphaned_venues(@now), & &1.id) == [employer.venue_id]

      assert {:error, :no_grant} =
               Engagements.fetch_grant_holding_engagement(
                 person_at(manager, @now),
                 employer.venue_id
               )
    end

    test "and a venue whose manager is untouched is not listed" do
      # The control: an orphan list that returned every venue satisfies the test
      # above on its own.
      %{employer: employer} = managed_venue()

      refute employer.venue_id in Enum.map(Lifecycle.orphaned_venues(@now), & &1.id)
    end

    test "and a venue whose only grant was revoked is not orphaned either" do
      # "Holding an authority" means a grant that is *live*. A venue with no
      # live grant has no authority for anybody to be the last holder of, so it
      # is not the state an operator re-seeds — it is a venue that was closed
      # down. `EmployerGrant.live_at/2` is reused so "live" cannot come to mean
      # two things.
      %{employer: employer, person: manager, grant: grant} = managed_venue()

      revoke_grant(grant.id, @now)

      assert {:ok, _erasure} = Lifecycle.erase_person(person_at(manager, @now))
      refute employer.venue_id in Enum.map(Lifecycle.orphaned_venues(@now), & &1.id)
    end

    test "and a venue that was closed is not orphaned either" do
      # `close_venue/2` leaves the grant live — it starts a retention clock, it
      # does not revoke anybody — so a venue that was deliberately wound up
      # satisfied every other clause here and was handed to an operator as
      # something to re-seed. The docstring already drew the line the other way:
      # "a venue that was wound up rather than one that needs a manager".
      %{employer: employer, person: manager} = managed_venue()

      assert {:ok, _} = Lifecycle.close_venue(employer.venue_id, @now)
      assert {:ok, _erasure} = Lifecycle.erase_person(person_at(manager, @now))

      refute employer.venue_id in Enum.map(Lifecycle.orphaned_venues(@now), & &1.id)
    end
  end

  ## KTD15b

  describe "erasure and room messages" do
    test "leaves them readable under a non-identifying label" do
      %{employer: employer, person: person} = engaged()
      colleague = person_scope_fixture(@now)
      _other = PeersFixtures.engage(employer, colleague, %{}, @now)

      {:ok, message} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "handover")

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))

      assert {:ok, messages} =
               Rooms.list_venue_room_messages(person_at(colleague, @now), employer.venue_id)

      assert Enum.map(messages, & &1.id) == [message.id]
      assert [%RoomMessage{body: "handover", author_engagement_id: author}] = messages

      assert %Engagement{role_label: label} = Repo.get!(Engagement, author)
      assert label == Lifecycle.erased_label()
    end

    test "writes to no attested_entries row either, which is the portable record" do
      # The other half of "delete too much", and the one nothing asserted.
      # Measured: an `erase_person/1` with a `Multi.run` deleting every attested
      # entry of the erased person's engagements passed `lifecycle_test.exs`,
      # `profiles_test.exs` and `revocation_test.exs` alike — 121 tests, no
      # failures. The recorded disclosure that a peer keeps seeing these entries
      # for thirty days is only true if the rows survive at all.
      #
      # Field for field, in `venue_messages/1`'s shape one table over: a rewrite
      # of the rows would satisfy a count.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      before = attested_entries(employer.venue_id)
      assert [%AttestedEntry{engagement_id: attested}] = before
      assert attested == engagement.id

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))
      assert attested_entries(employer.venue_id) == before
    end

    test "writes to no room_messages row at all" do
      # KTD15b's claim is that erasure reduces a number of rows proportional to
      # *engagements* rather than to messages. A rewrite of the message rows
      # would satisfy the test above and break the claim, so the rows are
      # compared field by field across the erasure.
      %{employer: employer, person: person} = engaged()

      {:ok, _} = Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "one")
      {:ok, _} = Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "two")

      before = venue_messages(employer.venue_id)

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))
      assert venue_messages(employer.venue_id) == before
    end
  end

  ## R15 and KTD19, driven without a scope

  describe "erasure and a peer conversation" do
    test "leaves the survivor their own messages and deletes the erased party's" do
      %{first: first, second: second, connection: connection} = conversation()

      assert {:ok, erasure} = Lifecycle.erase_person(person_at(first, @now))
      assert erasure.peer_messages_deleted == 1

      assert {:ok, survivors} = Peers.list_messages(person_at(second, @now), connection.id)
      assert Enum.map(survivors, & &1.body) == ["from the survivor"]
    end

    test "disconnects the connection and blocks the counterpart" do
      # Hazard 1: `Peers.disconnect/2` accepts only a live `PersonScope` acting
      # for itself, and an erasure has none to hand it. The remedy semantics
      # stay in `Peers` — this asserts they arrived.
      %{first: first, second: second, connection: connection} = conversation()

      assert {:ok, %{connections: [%Connection{id: id}]}} =
               Lifecycle.erase_person(person_at(first, @now))

      assert id == connection.id

      assert %Connection{disconnected_at: %DateTime{}, disconnected_by_id: by} =
               Repo.get!(Connection, connection.id)

      assert by == first.person.id

      assert %ConnectionRequest{blocked_initiator_id: blocked} =
               Repo.get!(ConnectionRequest, connection.request_id)

      assert blocked == second.person.id
    end

    test "leaves the connection_requests row, which is what keeps the block real" do
      # Hazard 2, from the side that makes it unreachable.
      # `Peers.block_counterpart/4` matched `{1, _}` on an update of this row,
      # and `peer_connections.request_id` is `NOT NULL ON DELETE RESTRICT`, so an
      # erasure that deleted requests would turn that into a `MatchError` that
      # crashed the transaction. Erasure keeps them, deliberately: the row *is*
      # KTD19's block.
      %{first: first, connection: connection} = conversation()

      assert {:ok, _} = Lifecycle.erase_person(person_at(first, @now))
      assert %ConnectionRequest{} = Repo.get(ConnectionRequest, connection.request_id)
    end
  end

  ## Scheduled work

  describe "erasure and scheduled jobs" do
    test "deletes that person's scheduled expiry jobs" do
      %{person: person, engagement: engagement} = engaged()

      assert scheduled_for(engagement.id) != []

      assert {:ok, %{jobs_cancelled: cancelled}} = Lifecycle.erase_person(person_at(person, @now))
      assert cancelled == 1
      assert scheduled_for(engagement.id) == []
    end

    test "and leaves another person's alone" do
      # The control: a `delete_all` with no filter satisfies the test above.
      %{person: person} = engaged()
      %{engagement: other} = engaged()

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))
      assert scheduled_for(other.id) != []
    end
  end

  ## U9's two obstacles

  describe "erasure and the profile" do
    test "deletes the person's declared entries" do
      %{person: person} = engaged()

      {:ok, entry} =
        Profiles.declare_entry(person_at(person, @now), %{
          role_label: "Barback",
          organisation_name: "The Anchor",
          starts_at: DateTime.add(@now, -400, :day),
          ends_at: DateTime.add(@now, -300, :day)
        })

      assert {:ok, %{declared_entries_deleted: 1}} =
               Lifecycle.erase_person(person_at(person, @now))

      assert Repo.get(DeclaredEntry, entry.id) == nil
    end

    test "keeps the disclosure ledger, as subject and as audience" do
      # The control for the test above, and the counter-intuitive half of the
      # unit. A disclosure row only ever *narrows* what an audience sees, so
      # deleting one discloses more — and peer visibility runs for thirty days
      # past an engagement's end, so an erasure that tidied the ledger away
      # would re-reveal, to every peer, exactly the entries the worker had
      # hidden. The audience half belongs to somebody else besides.
      %{employer: employer, person: person, engagement: engagement} = engaged()
      peer = person_scope_fixture(@now)
      peer_engagement = PeersFixtures.engage(employer, peer, %{}, @now)

      {:ok, own} =
        Profiles.set_disclosure(
          person_at(person, @now),
          engagement.id,
          {:person, peer.person.id},
          false
        )

      {:ok, theirs} =
        Profiles.set_disclosure(
          person_at(peer, @now),
          peer_engagement.id,
          {:person, person.person.id},
          false
        )

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))

      assert Repo.get(Disclosure, own.id)
      assert Repo.get(Disclosure, theirs.id)
    end

    test "withdraws the rows that hand an entry over, and only those" do
      # The claim above holds for `disclosed = false` and is backwards for
      # `true`: `Profiles.Records`'s peer rule reads a `true` row as an override
      # that beats the computed concurrency default, so keeping one leaves an
      # erased person affirmatively disclosing an entry for the thirty-day tail
      # with no session left to take it back. The old test wrote only `false`
      # rows, which is exactly the value the argument works for.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      hidden_from = person_scope_fixture(@now)
      shown_to = person_scope_fixture(@now)
      theirs_engagement = PeersFixtures.engage(employer, hidden_from, %{}, @now)
      PeersFixtures.engage(employer, shown_to, %{}, @now)

      {:ok, narrowing} = hide(person, engagement.id, hidden_from)
      {:ok, widening} = show(person, engagement.id, shown_to)
      {:ok, somebody_elses} = show(hidden_from, theirs_engagement.id, person)

      assert {:ok, %{disclosures_withdrawn: 1}} =
               Lifecycle.erase_person(person_at(person, @now))

      assert Repo.get(Disclosure, narrowing.id)
      assert Repo.get(Disclosure, widening.id) == nil

      # The audience half, from the `true` side: a row naming the erased person
      # as the audience is somebody else's decision about their own entries, and
      # a sweep keyed on `disclosed = true` alone would take it.
      assert Repo.get(Disclosure, somebody_elses.id)
    end

    test "so the peer it had been handed to stops seeing that entry" do
      # The behavioural half, and the reason a row-level assertion is not
      # enough. The worker holds two concurrent engagements, so the peer's
      # default conceals the *other* venue's entry — that is U9's concurrency
      # rule reached through the peer door — and the `true` row is what hands it
      # over. Measured before the fix: the peer saw two venues, erasure left it
      # at two, and deleting the row by hand dropped it to one.
      %{first: worker, second: peer} = PeersFixtures.co_rostered(@started)
      {elsewhere, _creation} = scoped_venue_fixture(@started)
      concurrent = PeersFixtures.engage(elsewhere, worker, %{}, @started)

      assert {:ok, %{attested_entries: [_one]}} =
               Profiles.fetch_peer_profile(person_at(peer, @now), worker.person.id)

      {:ok, _widening} = show(worker, concurrent.id, peer)

      assert {:ok, %{attested_entries: [_, _]}} =
               Profiles.fetch_peer_profile(person_at(peer, @now), worker.person.id)

      assert {:ok, %{disclosures_withdrawn: 1}} = Lifecycle.erase_person(person_at(worker, @now))

      assert {:ok, %{attested_entries: [_one]}} =
               Profiles.fetch_peer_profile(person_at(peer, @now), worker.person.id)
    end
  end

  ## The retained copy, from the suppression side

  describe "erasure and retained own-message copies" do
    test "deletes the copies that already existed" do
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      # The copy was taken with the message, so the announcement writes nothing
      # and only dates it. Read positively first: an erasure asserted against an
      # archive that never existed is the vacuous shape this file avoids
      # everywhere else.
      assert {:ok, %{written: 0, stamped: 1}} =
               Lifecycle.retain_own_messages(engagement.id, @after_the_end)

      assert length(Lifecycle.list_retained_messages(person_at(person, @after_the_end))) == 1

      assert {:ok, %{retained_copies_deleted: 1}} =
               Lifecycle.erase_person(person_at(person, @after_the_end))

      assert Lifecycle.list_retained_messages(person_at(person, @after_the_end)) == []
    end

    test "are not taken for an erased person, on the send path either" do
      # The invariant is "no retained copy of an erased person exists or will
      # exist", and erasure is not the only writer any more: a message written
      # after it would otherwise mint one. An erased person cannot send at all —
      # every term is closed — so this drives the archive write directly, which
      # is the same call the send's own `Ecto.Multi` makes.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, message} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))

      assert {:ok, 0} =
               Repo.transaction(fn ->
                 {:ok, written} = Lifecycle.retain_message(Repo, message, engagement)
                 written
               end)

      assert Repo.all(from(c in RetainedMessageCopy, where: c.person_id == ^person.person.id)) ==
               []
    end

    test "parks the archive behind a concurrent erasure rather than writing past it" do
      # The check and the insert were two unsynchronised statements. An erasure
      # committing between them left copies its own `delete_all` had already run
      # past, and nothing blocked: the copy's foreign key takes `FOR KEY SHARE`,
      # which does not conflict with the `FOR NO KEY UPDATE` erasure takes on
      # the engagement. `FOR SHARE` on the *person* row is the remedy, because
      # `erase_person/1`'s first step is `FOR UPDATE` on it.
      #
      # The barrier is that same `FOR UPDATE`, held by hand — the whole of what
      # erasure holds for the length of its transaction. Blocking is asserted by
      # the archive not finishing while it is held: with the lock removed the
      # call returns in single-digit milliseconds, so the margin is three orders
      # of magnitude rather than a guess.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      holder = hold_person(person.person.id)

      archiver =
        Task.async(fn ->
          with_connections(fn -> Lifecycle.retain_own_messages(engagement.id, @after_the_end) end)
        end)

      try do
        refute Task.yield(archiver, 750)
      after
        release_person(holder)
      end

      assert {:ok, %{written: 0, stamped: 1}} = Task.await(archiver, 5_000)
    end

    test "suppresses creation afterwards, however many times the announcement runs" do
      # The issue's "suppresses retained-copy creation for the engagements being
      # ended". It is derived from `people.erased_at` rather than stored,
      # because erasure is irreversible and a derived answer cannot fall out of
      # step with the row it is about.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      assert {:ok, _} = Lifecycle.erase_person(person_at(person, @now))

      assert {:ok, %{written: 0, stamped: 0}} =
               Lifecycle.retain_own_messages(engagement.id, @after_the_end)

      assert {:ok, _} =
               perform_job(ExpireEngagement, %{
                 "engagement_id" => engagement.id,
                 "venue_id" => employer.venue_id,
                 "ends_at" => DateTime.to_iso8601(@in_a_month)
               })

      assert Repo.all(from(c in RetainedMessageCopy, where: c.person_id == ^person.person.id)) ==
               []
    end
  end

  ## Venue closure

  describe "closing a venue" do
    test "is refused a second time and stamps nothing on the second call" do
      # "Stamps nothing" used to be inferred from the `:error` tuple, and the
      # first assertion was `%Venue{closed_at: %DateTime{}}` — a shape rather
      # than a value. Both columns are read back after the refusal and compared
      # to what the *first* call wrote, because the second call passes a
      # different instant and that is exactly what a partial failure would leave
      # behind.
      %{employer: employer, person: person} = engaged()

      {:ok, message} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      assert {:ok, %{messages_stamped: 1}} = Lifecycle.close_venue(employer.venue_id, @now)

      assert %Venue{closed_at: %DateTime{} = closed_at} = Repo.get!(Venue, employer.venue_id)
      assert DateTime.compare(closed_at, @now) == :eq

      assert %RoomMessage{delete_after: %DateTime{} = due} = Repo.get!(RoomMessage, message.id)
      assert DateTime.compare(due, Lifecycle.history_deadline(@now)) == :eq

      assert {:error, :already_closed} = Lifecycle.close_venue(employer.venue_id, @after_the_end)

      assert %Venue{closed_at: ^closed_at} = Repo.get!(Venue, employer.venue_id)
      assert %RoomMessage{delete_after: ^due} = Repo.get!(RoomMessage, message.id)
    end

    test "shuts the room, so nothing can be written that no deadline could reach" do
      # A2. Closure stamps the rows that exist when it runs and then refuses to
      # run again, and `delete_after < instant` never matches a null — so every
      # venue-room message written from the closure instant onward was retained
      # for ever, and "closing a venue destroys, on a clock, the conversation
      # history of everybody who ever worked there" was false. Measured before
      # the fix: closed on day ten, sent on day eleven, swept ten years later,
      # survivor `["after closure"]`.
      %{employer: employer, person: person} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "while open")

      closed_at = DateTime.add(@now, 10, :day)
      assert {:ok, %{messages_stamped: 1}} = Lifecycle.close_venue(employer.venue_id, closed_at)

      later = DateTime.add(@now, 11, :day)

      assert {:error, :room_closed} =
               Rooms.send_venue_room_message(
                 person_at(person, later),
                 employer.venue_id,
                 "after closure"
               )

      # Reading is untouched, which is the control on the gate being about the
      # write: the history is there for thirty days and a clock is what closure
      # put on it, not a wall.
      assert {:ok, [_one]} =
               Rooms.list_venue_room_messages(person_at(person, later), employer.venue_id)

      assert {:ok, run} = Lifecycle.sweep(DateTime.add(@now, 3650, :day))
      assert run.venue_room_messages == 1
      assert venue_messages(employer.venue_id) == []
    end

    test "parks a send that is racing it rather than letting one commit behind it" do
      # A2's pure-race form, which needs no post-closure trading at all: a send
      # whose snapshot predates the closure passes `closed_at IS NULL` under
      # `READ COMMITTED` and inserts a row the stamping statement has already
      # run past. Unlocked, it commits in single-digit milliseconds and the
      # message is retained for ever.
      #
      # The barrier is the closure's own `UPDATE venues`, held by hand. `FOR
      # SHARE` conflicts with the `FOR NO KEY UPDATE` it takes, so the send
      # parks and then re-evaluates against the committed row — the manoeuvre
      # `Peers.send_message/3` uses against a racing disconnect.
      %{employer: employer, person: person} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "while open")

      holder = hold_closing_venue(employer.venue_id)

      sender =
        Task.async(fn ->
          with_connections(fn ->
            Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "racing")
          end)
        end)

      try do
        refute Task.yield(sender, 750)
      after
        release_holder(holder)
      end

      assert {:error, :room_closed} = Task.await(sender, 5_000)
      assert Enum.map(venue_messages(employer.venue_id), & &1.body) == ["while open"]
    end

    test "is :not_found for an id that names nothing" do
      assert {:error, :not_found} = Lifecycle.close_venue(Ecto.UUID.generate(), @now)
    end
  end

  ## KTD21

  describe "the rule that only Lifecycle deletes" do
    # Structural, out of the compiled `imports` chunk, the way
    # `profiles_test.exs` reads query builders and `person_zone_test.exs` reads
    # repo calls. A whole-application sweep over the modules compiled from
    # `lib/`, so a context added by a later unit is covered on the day it is
    # written rather than on the day somebody remembers this file.

    test "is a fact about the compiled modules, with one enumerated exemption" do
      offenders =
        Enum.filter(library_modules(), fn module ->
          module != Lifecycle and deletes?(module)
        end)

      # `HospitalityComs.Accounts` deletes `people_tokens` and nothing else:
      # magic-link redemption claims the link, log-out ends the session, an
      # email change expires every token. That is credential expiry rather than
      # record destruction, and moving it here would route log-out through a
      # module about retention. The exemption is enumerated rather than
      # described, because a sweep with a silent carve-out grows carve-outs; the
      # test below is what bounds it.
      assert offenders == [Accounts]
    end

    test "reads a chunk that actually says something, which is the control" do
      modules = library_modules()

      assert Lifecycle in modules
      assert Engagements in modules
      assert HospitalityComsWeb.PersonAuth in modules
      refute HospitalityComs.EngagementsFixtures in modules

      assert deletes?(Lifecycle)
    end

    test "bounds the exemption: Accounts reaches people_tokens and no other table" do
      # The bound is a count per table across a log-out, and **an empty table
      # compares zero to zero**. Measured on the fixture this used to run on:
      # fourteen of the twenty-three base tables were empty, both of the tables
      # U10 introduces among them, and planting four `Repo.delete_all` calls into
      # `Accounts.delete_person_session_token/1` produced twenty-eight passes and
      # no failures. So the fixture populates every table first and the emptiness
      # check below is what stops it going vacuous again.
      %{person: person} = populated()
      token = Accounts.generate_person_session_token(person.person, @now)

      before = table_counts()
      assert unpopulated(before) == @unpopulatable

      assert {:ok, [_deleted]} = Accounts.delete_person_session_token(token)
      after_log_out = table_counts()

      changed =
        before
        |> Enum.reject(fn {table, count} -> Map.fetch!(after_log_out, table) == count end)
        |> Enum.map(fn {table, _count} -> table end)

      assert changed == ["people_tokens"]
    end

    test "sweeps a repo call the imports chunk cannot see, which is the residual" do
      # `Repo.delete_all(…)` written statically is in the `imports` chunk and is
      # caught above. `fn repo, _ -> repo.delete_all(…) end` inside a
      # `Multi.run` is **not** — the receiver is bound at run time — and that is
      # the exact idiom `Lifecycle` itself uses five times, so the invisible form
      # is the one a future author copies from the one module the rule exists to
      # isolate. Measured: the same delete written statically is caught and
      # named; inside a `Multi.run` it killed zero tests.
      #
      # So the rule is swept a second way, over the source each module was
      # compiled from: any call to `delete`, `delete!` or `delete_all` on a repo
      # alias or on a bare variable. `Map.delete/2` and friends are not reached,
      # because their receiver is an alias that is not a repo.
      offenders = Enum.reject(source_offenders(), &(&1 in deleting_sources()))

      assert offenders == []
    end

    test "and the second sweep sees the nested form, which is its control" do
      nested = """
      defmodule Elsewhere do
        def go(multi) do
          Ecto.Multi.run(multi, :gone, fn repo, _changes -> repo.delete_all(Thing) end)
        end
      end
      """

      qualified = "defmodule Elsewhere do def go, do: HospitalityComs.Repo.delete_all(Thing) end"
      innocent = "defmodule Elsewhere do def go(map), do: Map.delete(map, :key) end"

      assert deletes_in_source?(nested)
      assert deletes_in_source?(qualified)
      refute deletes_in_source?(innocent)

      # And the sweep over the real tree finds exactly the two files that are
      # allowed to delete, so the emptiness above is a fact about `lib/` rather
      # than about a reader that never fires.
      assert Enum.sort(source_offenders()) == Enum.sort(deleting_sources())
    end

    test "and every query the context makes lives in Records" do
      # `HospitalityComs.Profiles`' rule, applied where it matters most: a
      # reader of `Lifecycle` sees which rows go and in what order, and a reader
      # of `Records` sees exactly which rows each statement can reach. Read out
      # of the compiled `imports` chunk the way `peers_test.exs` reads it.
      #
      # **The known edge, measured rather than assumed**, and it is
      # `peers_test.exs`' and `profiles_test.exs`' too: a query with no
      # interpolation and no dynamic composition — `from(p in Person, where:
      # is_nil(p.erased_at))` — is fully expanded at compile time and calls into
      # no builder at all, so it passes this. One with a `^` anywhere in it does
      # not, and every query in this tree takes an id or an instant.
      assert query_builders(Lifecycle) == []
      assert Ecto.Query.Builder in query_builders(Records)
      assert Ecto.Query.Builder.From in query_builders(Records)
    end
  end

  ## Helpers

  defp person_at(%PersonScope{person: %Person{} = person}, %DateTime{} = instant) do
    PersonScope.for_person(person, instant)
  end

  # A venue, a person, and an ordinary month-long engagement between them.
  defp engaged do
    {employer, _creation} = scoped_venue_fixture(@now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        role_label: "Bartender",
        starts_at: @now,
        ends_at: @in_a_month,
        code_expires_at: DateTime.add(@now, 7, :day)
      })

    %{employer: employer, person: person, engagement: engagement}
  end

  # An engagement whose term has not opened yet.
  defp future_engagement do
    {employer, _creation} = scoped_venue_fixture(@now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        role_label: "Bartender",
        starts_at: DateTime.add(@now, 10, :day),
        ends_at: DateTime.add(@now, 40, :day),
        code_expires_at: DateTime.add(@now, 7, :day)
      })

    %{employer: employer, person: person, engagement: engagement}
  end

  # The venue's sole grant-holding engagement.
  defp managed_venue do
    {employer, creation} = scoped_venue_fixture(@now)
    person = person_scope_fixture(@now)

    engagement =
      engagement_fixture(employer, person, %{
        role_label: "Manager",
        grant_id: creation.grant.id,
        starts_at: @now,
        ends_at: @in_a_month,
        code_expires_at: DateTime.add(@now, 7, :day)
      })

    %{employer: employer, person: person, engagement: engagement, grant: creation.grant}
  end

  # One row in every base table the application can write. What
  # `table_counts/0`'s comparison needs, because an empty table compares zero to
  # zero and fourteen of the twenty-three were empty on the ordinary fixture.
  defp populated do
    %{employer: employer, person: person, engagement: engagement} = engaged()

    peer = person_scope_fixture(@now)
    peer_engagement = PeersFixtures.engage(employer, peer, %{}, @now)

    # `connection_requests`, `peer_connections`, `peer_messages`.
    connection = PeersFixtures.connection_fixture(person, peer)
    {:ok, _} = Peers.send_message(person_at(person, @now), connection.id, "hello")

    # `shift_types`, `shift_rooms`, `roster_entries`, `room_messages`, and
    # `retained_message_copies` behind them.
    shift_type = RoomsFixtures.shift_type_fixture(employer, 30)
    room = RoomsFixtures.shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
    {:ok, _entry} = Rosters.add_to_roster(employer, room.id, engagement.id)
    {:ok, _} = Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hi")
    {:ok, _} = Rooms.send_shift_room_message(person_at(person, @during_shift), room.id, "on it")

    # `venue_room_suspensions`.
    {:ok, _} = Rooms.suspend_venue_room(person_at(peer, @now), employer.venue_id)

    # `declared_entries`, `attested_entry_disclosures`, `correction_requests`.
    {:ok, _} =
      Profiles.declare_entry(person_at(person, @now), %{
        role_label: "Barback",
        organisation_name: "The Anchor",
        starts_at: DateTime.add(@now, -400, :day),
        ends_at: DateTime.add(@now, -300, :day)
      })

    {:ok, _} = hide(person, engagement.id, peer)
    {:ok, _} = Profiles.request_correction(person_at(person, @now), engagement.id, %{body: "No."})

    # `retention_runs`.
    {:ok, _} = Lifecycle.sweep(@now)

    %{
      employer: employer,
      person: person,
      engagement: engagement,
      peer: peer,
      peer_engagement: peer_engagement
    }
  end

  defp unpopulated(counts) do
    counts
    |> Enum.filter(fn {_table, count} -> count == 0 end)
    |> Enum.map(fn {table, _count} -> table end)
    |> Enum.sort()
  end

  # Two co-rostered people, connected, with one message each.
  defp conversation do
    %{first: first, second: second} = PeersFixtures.co_rostered(@now)
    connection = PeersFixtures.connection_fixture(first, second)

    {:ok, _} = Peers.send_message(person_at(first, @now), connection.id, "from the erased")
    {:ok, _} = Peers.send_message(person_at(second, @now), connection.id, "from the survivor")

    %{first: first, second: second, connection: connection}
  end

  defp revoke_grant(grant_id, instant) do
    Repo.update_all(
      from(g in HospitalityComs.Venues.EmployerGrant,
        where: g.id == ^grant_id,
        update: [
          set: [revoked_at: ^DateTime.truncate(instant, :second), revoked_by_grant_id: ^grant_id]
        ]
      ),
      []
    )
  end

  defp venue_messages(venue_id) do
    Repo.all(from(m in RoomMessage, where: m.venue_id == ^venue_id, order_by: [asc: m.sent_at]))
  end

  defp attested_entries(venue_id) do
    Repo.all(from(e in AttestedEntry, where: e.venue_id == ^venue_id, order_by: [asc: e.id]))
  end

  # An exclusive lock on one committed `people` row, held until released —
  # exactly what `erase_person/1`'s first step takes and holds for the length of
  # its transaction.
  defp hold_person(person_id) do
    held(fn test -> lock_person_row(test, person_id) end)
  end

  defp lock_person_row(test, person_id) do
    Repo.query!("SELECT id FROM people WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(person_id)])
    park(test)
  end

  # The closure's own `UPDATE venues`, held uncommitted. It takes
  # `FOR NO KEY UPDATE` on the row, which is what a send under `FOR SHARE`
  # parks behind.
  defp hold_closing_venue(venue_id) do
    held(fn test -> close_venue_row(test, venue_id) end)
  end

  defp close_venue_row(test, venue_id) do
    Repo.query!("UPDATE venues SET closed_at = $1 WHERE id = $2", [
      @now |> DateTime.to_naive() |> NaiveDateTime.truncate(:second),
      Ecto.UUID.dump!(venue_id)
    ])

    park(test)
  end

  # `work` runs inside a real transaction in a process of its own and parks
  # until released, so whatever locks it took are held for the length of it.
  defp held(work) when is_function(work, 1) do
    test = self()
    holder = Task.async(fn -> with_connections(fn -> in_transaction(work, test) end) end)

    assert_receive {:holding, _pid}, 5_000
    holder
  end

  defp in_transaction(work, test), do: Repo.transaction(fn -> work.(test) end)

  defp park(test) do
    send(test, {:holding, self()})
    receive do: (:release -> :ok)
  end

  # Always in an `after`. A barrier that is never released leaves its holder
  # inside an open transaction for as long as the VM lives, and the purge that
  # follows the test blocks on the row it holds.
  defp release_person(holder), do: release_holder(holder)

  defp release_holder(%Task{pid: pid} = holder) do
    send(pid, :release)
    Task.await(holder, 5_000)
  end

  defp person_row(person_id) do
    Person |> Repo.get!(person_id) |> Map.from_struct() |> Map.drop([:__meta__])
  end

  # No `Accounts` path sets this without a magic link, and a `confirmed_at` that
  # is null before and after would make a mutation that nulls it invisible.
  defp confirm(person_id) do
    Repo.update_all(from(p in Person, where: p.id == ^person_id),
      set: [confirmed_at: DateTime.truncate(@now, :second)]
    )
  end

  defp hide(%PersonScope{} = subject, engagement_id, %PersonScope{} = audience) do
    disclose(subject, engagement_id, audience, false)
  end

  defp show(%PersonScope{} = subject, engagement_id, %PersonScope{} = audience) do
    disclose(subject, engagement_id, audience, true)
  end

  defp disclose(subject, engagement_id, %PersonScope{person: %Person{id: id}}, disclosed) do
    Profiles.set_disclosure(person_at(subject, @now), engagement_id, {:person, id}, disclosed)
  end

  defp scheduled_for(engagement_id) do
    Repo.all(
      from(j in Oban.Job,
        where: fragment("? ->> 'engagement_id' = ?", j.args, ^engagement_id),
        select: j.id
      )
    )
  end

  # Every module compiled from `lib/`. Read out of the application rather than
  # listed, and filtered on the compile-time source path so that the fixtures
  # under `test/support` — which delete for a living — are not swept.
  defp library_modules do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)
    Enum.filter(modules, &library_module?/1)
  end

  defp library_module?(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:compile)
      |> Keyword.get(:source, ~c"")
      |> to_string()
      |> String.contains?("/lib/")
  end

  # `Repo.delete*` reached statically, and `Ecto.Multi.delete*` reached at all.
  # A `repo.delete_all/1` on a repo bound at run time is invisible here, exactly
  # as it is to `person_zone_test.exs`'s repo sweep; what closes that is that
  # the only place such a call is made is inside this context's own multi.
  defp deletes?(module) do
    Enum.any?(called_functions(module), fn {called, function, _arity} ->
      (called in @repos or called == Ecto.Multi) and function in @delete_functions
    end)
  end

  defp called_functions(module) do
    {:ok, {^module, [imports: imports]}} =
      module |> :code.which() |> :beam_lib.chunks([:imports])

    imports
  end

  # The second sweep, over source rather than over the `imports` chunk, because
  # a `repo.delete_all/1` on a repo bound at run time is invisible to the first
  # and is the idiom `Lifecycle` itself uses.
  defp source_offenders do
    library_modules()
    |> Enum.map(&source_of/1)
    |> Enum.uniq()
    |> Enum.filter(fn path -> path |> File.read!() |> deletes_in_source?() end)
  end

  # Derived from the modules rather than written as paths, so a file that moves
  # cannot silently widen the exemption.
  defp deleting_sources, do: Enum.map([Lifecycle, Accounts], &source_of/1)

  defp source_of(module) do
    module.module_info(:compile) |> Keyword.get(:source, ~c"") |> to_string()
  end

  defp query_builders(module) do
    module
    |> called_functions()
    |> Enum.map(fn {called, _function, _arity} -> called end)
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.Ecto.Query.Builder"))
  end

  defp deletes_in_source?(source) when is_binary(source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc -> {node, collect_delete(node, acc)} end)

    found != []
  end

  defp collect_delete({{:., _meta, [receiver, function]}, _call_meta, _args}, acc)
       when function in @delete_functions do
    flagged(deleting_receiver?(receiver), function, acc)
  end

  defp collect_delete(_node, acc), do: acc

  defp flagged(true, function, acc), do: [function | acc]
  defp flagged(false, _function, acc), do: acc

  defp deleting_receiver?({:__aliases__, _meta, parts}), do: List.last(parts) in @delete_receivers

  defp deleting_receiver?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: true

  defp deleting_receiver?(_receiver), do: false

  defp table_counts do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        ORDER BY table_name
        """,
        []
      )

    Map.new(rows, fn [table] ->
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, count}
    end)
  end
end
