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
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.PeersFixtures
  alias HospitalityComs.Profiles
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Venues.Venue
  alias HospitalityComs.Workers.ExpireEngagement

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_month DateTime.add(@now, 30, :day)
  @after_the_end DateTime.add(@in_a_month, 1, :hour)

  # Every module that may not delete is read out of the application, so a
  # context added by a later unit is covered on the day it compiles.
  @repos [HospitalityComs.Repo, HospitalityComs.EmployerRepo]
  @delete_functions [:delete, :delete!, :delete_all]

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

      assert Repo.get(HospitalityComs.Profiles.Disclosure, own.id)
      assert Repo.get(HospitalityComs.Profiles.Disclosure, theirs.id)
    end
  end

  ## The retained copy, from the suppression side

  describe "erasure and retained own-message copies" do
    test "deletes the copies that already existed" do
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      assert {:ok, 1} = Lifecycle.retain_own_messages(engagement.id, @after_the_end)
      assert length(Lifecycle.list_retained_messages(person_at(person, @after_the_end))) == 1

      assert {:ok, %{retained_copies_deleted: 1}} =
               Lifecycle.erase_person(person_at(person, @after_the_end))

      assert Lifecycle.list_retained_messages(person_at(person, @after_the_end)) == []
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

      assert {:ok, 0} = Lifecycle.retain_own_messages(engagement.id, @after_the_end)

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
      %{employer: employer, person: person} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      assert {:ok, %{messages_stamped: 1}} = Lifecycle.close_venue(employer.venue_id, @now)
      assert %Venue{closed_at: %DateTime{}} = Repo.get!(Venue, employer.venue_id)

      assert {:error, :already_closed} = Lifecycle.close_venue(employer.venue_id, @after_the_end)
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
      %{person: person} = engaged()
      token = Accounts.generate_person_session_token(person.person, @now)

      before = table_counts()
      assert {:ok, [_deleted]} = Accounts.delete_person_session_token(token)
      after_log_out = table_counts()

      changed =
        before
        |> Enum.reject(fn {table, count} -> Map.fetch!(after_log_out, table) == count end)
        |> Enum.map(fn {table, _count} -> table end)

      assert changed == ["people_tokens"]
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
