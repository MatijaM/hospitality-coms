defmodule HospitalityComs.DemoTest do
  @moduledoc """
  The seed manifest, the controls, and the build the controls are absent from.

  ## What this file has to be careful about

  The unit is the last of twelve and adds no table, so almost everything here is
  an assertion about the *other eleven* being reachable in one action. That
  makes it unusually easy to write a test that passes because the fixture said
  so rather than because the system did, which is the defect class this project
  has produced nine times. Every claim here therefore carries a control:

    * a hidden entry is asserted beside a visible one, from the same view;
    * a room closed by a clock advance is asserted beside the same room one
      second earlier;
    * a lapsed visibility is asserted beside the connection it does not touch;
    * a control that refuses is asserted beside the engagements it left alone;
    * a retention deletion is asserted beside the rows whose deadline had not
      arrived, and beside the same advance with the control not run.

  ## Why it is not sandboxed

  `EngagementsFixtures.real_connections/0`, for U5's reason: the manifest is
  written through both repos and under the sandbox those are two transactions
  that cannot see each other's rows. It is also `async: false` because it moves
  the global `HospitalityComs.Clock.Offset`.

  The seed's own rows carry `HospitalityComs.Demo`'s two patterns, which
  `EngagementsFixtures.purge/0` reads, so a run that dies mid-test is cleaned up
  as ordinary fixture residue rather than reported as something written by
  nothing in this tree.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Demo
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Peers
  alias HospitalityComs.Profiles
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.Venue
  alias HospitalityComs.Workers.EngagementSweeper

  # Whole seconds on purpose. `shift_rooms.starts_at` and `closes_at` are
  # `:utc_datetime`, so a microsecond on the seed's instant would be truncated
  # out of the stored bounds and the grace-boundary tests would be comparing an
  # instant against a value a fraction of a second away from the one they meant.
  @instant ~U[2026-06-01 09:00:00.000000Z]

  # The base tables a seeded manifest fills. Written out because `census/0`
  # compares counts and **an empty table compares zero to zero**: without this,
  # a second seed writing into any table the manifest happens not to reach is
  # invisible. The four it does not fill are `people_tokens` (nobody logs in),
  # `venue_room_suspensions` (nobody opts out), `retention_runs` (no sweep has
  # run) and `oban_peers`.
  @seeded_tables ~w(
    attested_entries attested_entry_disclosures connection_requests correction_requests
    declared_entries employer_grants engagements invitations oban_jobs peer_connections
    peer_messages people retained_message_copies room_messages roster_entries shift_rooms
    shift_types venues
  )

  setup do
    EngagementsFixtures.real_connections()
    :ok = Clock.Offset.set(@instant)
    ExUnit.Callbacks.on_exit(fn -> Clock.Offset.reset() end)
    :ok
  end

  describe "the manifest" do
    setup [:seeded]

    test "produces a person holding concurrent engagements at both employers", %{
      manifest: manifest
    } do
      engagements = Engagements.list_person_engagements(person_scope(manifest, :tomo))

      assert length(engagements) == 2

      assert Enum.map(engagements, & &1.venue_id) |> Enum.sort() ==
               Enum.sort([manifest.venues.harbour, manifest.venues.kolektiv])
    end

    test "hides the concurrent venue's entry from the other venue by default", %{
      manifest: manifest
    } do
      {:ok, entries} =
        Profiles.list_visible_entries(
          employer_scope(manifest, :harbour),
          manifest.engagements.tomo_harbour
        )

      refute manifest.venues.kolektiv in Enum.map(entries, & &1.venue_id)
    end

    test "and shows the reading venue its own entry, which is the control", %{manifest: manifest} do
      {:ok, entries} =
        Profiles.list_visible_entries(
          employer_scope(manifest, :harbour),
          manifest.engagements.tomo_harbour
        )

      assert manifest.venues.harbour in Enum.map(entries, & &1.venue_id)
    end

    test "produces an accepted peer connection carrying at least two messages", %{
      manifest: manifest
    } do
      scope = person_scope(manifest, :tomo)

      assert {:ok, conversation} = Peers.fetch_conversation(scope, manifest.connection_id)
      assert is_nil(conversation.disconnected_at)
      assert {:ok, messages} = Peers.list_messages(scope, manifest.connection_id)
      assert length(messages) >= 2
    end

    test "produces a pending request nobody has answered", %{manifest: manifest} do
      scope = person_scope(manifest, :tomo)

      assert {:ok, request} = Peers.fetch_request(scope, manifest.pending_request_id)
      assert request.state == :pending
      assert request.requester_id == manifest.people.luka
    end

    test "produces a past shift, a closed shift and a live shift", %{manifest: manifest} do
      tomo = person_scope(manifest, :tomo)

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(tomo, manifest.shift_rooms.past_shift, "late")

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(tomo, manifest.shift_rooms.closed_shift, "late")

      assert {:ok, _message} =
               Rooms.send_shift_room_message(tomo, manifest.shift_rooms.live_shift, "on it")
    end

    test "gives the two shift types different graces, copied onto their rooms", %{
      manifest: manifest
    } do
      scope = employer_scope(manifest, :harbour)

      {:ok, types} = Venues.list_shift_types(scope)
      {:ok, past} = Rooms.fetch_shift_room(scope, manifest.shift_rooms.past_shift)
      {:ok, closed} = Rooms.fetch_shift_room(scope, manifest.shift_rooms.closed_shift)

      assert types |> Enum.map(& &1.grace_period_minutes) |> Enum.sort() == [15, 120]
      assert past.grace_period_minutes == 120
      assert closed.grace_period_minutes == 15
    end

    test "leaves the past shift's roster readable, which a roster stamped at seed time is not",
         %{manifest: manifest} do
      scope = employer_scope(manifest, :harbour)
      room_id = manifest.shift_rooms.past_shift

      {:ok, readers} = Rooms.list_shift_room_readers(scope, room_id)

      {:ok, ana} =
        Rosters.list_engagement_periods(scope, room_id, manifest.engagements.ana_harbour)

      # Both overlapped the room's open window, so both still read it — which is
      # the whole of KTD6b, and which is zero if the periods were stamped at
      # seed time instead of at the instants the manifest says they happened.
      assert length(readers) == 2
      assert [%{left_at: %DateTime{}}] = ana
    end

    test "leaves a person holding zero engagements whose account still works", %{
      manifest: manifest
    } do
      luka = person_scope(manifest, :luka)

      assert Engagements.list_person_engagements(luka) == []
      assert length(Engagements.list_person_history(luka)) == 1
      assert length(Profiles.list_attested_entries(luka)) == 1

      # `assert %{} = …` is the empty-map *pattern*, which matches every map, so
      # `own_profile/1` returning `%{}` satisfied it. The keys are written out
      # here and the attested half is compared against the read above, which is
      # the half a profile with nothing in it would fail.
      assert %{
               attested_entries: attested,
               declared_entries: [],
               correction_requests: []
             } = Profiles.own_profile(luka)

      assert Enum.map(attested, & &1.attested_entry_id) ==
               Enum.map(Profiles.list_attested_entries(luka), & &1.attested_entry_id)

      assert length(attested) == 1
    end

    test "names the curated rows the profile surface is built on", %{manifest: manifest} do
      # C4: all six of the original anchors exist by the fourth of `write/1`'s
      # eleven phases, so the three rows written after the pending request were
      # outside everything `seed/0` checked and everything the manifest named.
      tomo = person_scope(manifest, :tomo)

      assert Enum.map(Profiles.list_declared_entries(tomo), & &1.declared_entry_id) ==
               [manifest.declared_entry_id]

      assert Enum.map(Profiles.list_correction_requests(tomo), & &1.correction_request_id) ==
               [manifest.correction_request_id]

      assert Enum.map(Profiles.list_disclosures(tomo), & &1.disclosure_id) ==
               [manifest.disclosure_id]
    end
  end

  describe "the manifest after the demo has been driven" do
    setup [:seeded]

    test "survives the seeded approach being accepted, which is the first thing a client does",
         %{manifest: manifest} do
      # C1. `connection_id` was "the only connection Tomo is a party to", and
      # accepting puts a second row in `peer_connections`, so every later read
      # of the manifest raised `Ecto.MultipleResultsError` out of a function
      # spec'd `{:ok, manifest()} | {:error, :partial_manifest}` — a 500 with no
      # envelope, permanent for that database, from the demo's own first move.
      assert {:ok, _connection} =
               Peers.accept_request(person_scope(manifest, :tomo), manifest.pending_request_id)

      assert {:ok, again} = Demo.seed()
      assert again.status == :present
      assert Map.delete(again, :status) == Map.delete(manifest, :status)
    end

    test "and survives it being declined, which empties the inbox it was read from", %{
      manifest: manifest
    } do
      # The other half of C1: `pending_request_id` came off
      # `Peers.list_incoming_requests/1` through `List.first/1`, and a declined
      # request is not incoming, so the same read became a `MatchError`.
      assert {:ok, _declined} =
               Peers.decline_request(person_scope(manifest, :tomo), manifest.pending_request_id)

      assert {:ok, again} = Demo.seed()
      assert again.status == :present
      assert Map.delete(again, :status) == Map.delete(manifest, :status)
    end

    test "and survives the seeded conversation being disconnected", %{manifest: manifest} do
      assert {:ok, _closed} =
               Peers.disconnect(person_scope(manifest, :tomo), manifest.connection_id)

      assert {:ok, again} = Demo.seed()
      assert again.connection_id == manifest.connection_id
    end
  end

  describe "seeding twice" do
    setup [:seeded]

    test "writes nothing the second time and answers with the same ids", %{manifest: first} do
      # **The bound is every base table, and the emptiness check is what keeps
      # it one.** It used to count four schemas, so a second seed writing one
      # `declared_entries` row left all 53 tests passing while a `room_messages`
      # row killed one. That is U10's defect exactly — its log-out bound was
      # vacuous over fourteen of the twenty-three base tables because an empty
      # table compares zero to zero — so this reuses `lifecycle_test.exs`'s
      # idiom: count from `information_schema`, and assert the tables the
      # manifest is supposed to fill are non-empty before comparing anything.
      before = census()

      assert Enum.reject(@seeded_tables, &(Map.fetch!(before, &1) > 0)) == []

      assert {:ok, second} = Demo.seed()

      assert second.status == :present
      assert Map.delete(second, :status) == Map.delete(first, :status)
      assert census() == before
    end

    test "refuses a database missing a row written after the last anchor", %{manifest: manifest} do
      # C4. `declared_entries` is written by the tenth of `write/1`'s eleven
      # phases; the six original anchors are all in place by the fourth. So a
      # run interrupted between them answered `:present` and wrote nothing,
      # `priv/repo/seeds.exs` printed "already here", and the profile surface
      # was short a row with nothing saying so. Reproduced before the fix.
      {1, _} =
        Repo.delete_all(
          from(entry in DeclaredEntry, where: entry.id == ^manifest.declared_entry_id)
        )

      assert Demo.seed() == {:error, :partial_manifest}
    end

    test "refuses a database holding only part of the manifest", %{manifest: manifest} do
      # Renamed rather than deleted, because every anchor is referenced with
      # `ON DELETE RESTRICT` and a manifest one anchor short is the state under
      # test either way: five of the six resolve.
      {1, _} =
        Repo.update_all(
          from(venue in Venue, where: venue.id == ^manifest.venues.kolektiv),
          set: [name: "Kolektiv Coffee interrupted (demo)"]
        )

      assert Demo.seed() == {:error, :partial_manifest}
    end
  end

  describe "run_due_work/0 and retention" do
    setup [:seeded]

    test "a clock advance alone deletes nothing", %{manifest: manifest} do
      # **True here because nothing is running, and that is a fact about the
      # environment rather than about the control.** `config/test.exs` sets
      # `testing: :manual`, so no queue and no cron tick exists to notice the
      # advance. `config/dev.exs` now sets the same thing, and the test below
      # is what holds it there; without it, cron stages `RetentionSweeper` at
      # the *real* instant while the worker reads the *injected* clock, and this
      # assertion is false within the hour in the one environment the controls
      # exist for.
      before = shift_message_count(manifest.shift_rooms.past_shift)

      {:ok, _instant} = Demo.advance_clock(day: 11)

      assert shift_message_count(manifest.shift_rooms.past_shift) == before
      assert before > 0
    end

    test "counts the window and the worker apart, and they agree" do
      # `swept` is what `list_expired/3` found and `announced` is how many of
      # those the real worker judged closed. Both read one clock, so they are
      # equal by construction — which is why replacing the worker's `:revoked`
      # test with `true` kills nothing: it is an equivalent mutant. What is not
      # equivalent is the worker disagreeing with the window, and this is what
      # would catch it. `>= 1` because zero equals zero.
      {:ok, work} = Demo.run_due_work()

      assert work.swept == work.announced
      assert work.swept >= 1
    end

    test "and the advance followed by the control deletes exactly the due rows", %{
      manifest: manifest
    } do
      {:ok, _instant} = Demo.advance_clock(day: 11)
      {:ok, work} = Demo.run_due_work()

      assert work.retention.outcome == :completed
      assert shift_message_count(manifest.shift_rooms.past_shift) == 0
      assert roster_count(manifest.shift_rooms.past_shift) == 0
      assert shift_message_count(manifest.shift_rooms.closed_shift) == 1
      assert roster_count(manifest.shift_rooms.closed_shift) == 1
    end

    test "announces a term that closed long before the production sweep window", %{
      manifest: manifest
    } do
      {:ok, _instant} = Demo.advance_clock(day: 31)
      {:ok, work} = Demo.run_due_work()

      assert work.announced >= 1
      assert manifest.engagements.luka_kolektiv in swept_ids(work.instant)
    end

    test "and the production window still looks back exactly one day, which is the control" do
      instant = Clock.now()

      assert DateTime.diff(instant, EngagementSweeper.lookback_from(instant), :day) == 1
    end

    test "stamps the archive deadline through the real worker", %{manifest: manifest} do
      assert archive_deadlines(manifest.people.tomo) == [nil]

      {:ok, _closed} = Demo.end_all_engagements(manifest.people.tomo)
      {:ok, work} = Demo.run_due_work()

      assert work.announced >= 1
      refute nil in archive_deadlines(manifest.people.tomo)
    end

    test "with no deadline passed it still records a run, of zeroes" do
      {:ok, work} = Demo.run_due_work()

      # A recorded zero and no record at all are different facts (U10). The
      # announcement half is *not* zero at the seed's own instant — Luka's term
      # closed ten days ago — which is the control that keeps this test about
      # retention rather than about the control having done nothing.
      assert work.announced == 1

      assert %{
               outcome: :completed,
               own_message_copies: 0,
               shift_messages: 0,
               roster_entries: 0,
               venue_room_messages: 0
             } = work.retention
    end
  end

  describe "the grace boundary" do
    setup [:seeded]

    test "advancing past a shift's grace closes that room", %{manifest: manifest} do
      {:ok, _instant} = Demo.advance_clock(hour: 9)

      assert {:error, :room_closed} =
               Rooms.send_shift_room_message(
                 person_scope(manifest, :tomo),
                 manifest.shift_rooms.live_shift,
                 "still here"
               )
    end

    test "and one second earlier it is still open, which is the control", %{manifest: manifest} do
      {:ok, _instant} = Demo.advance_clock(hour: 9)
      {:ok, _instant} = Demo.advance_clock(second: -1)

      assert {:ok, _message} =
               Rooms.send_shift_room_message(
                 person_scope(manifest, :tomo),
                 manifest.shift_rooms.live_shift,
                 "still here"
               )
    end
  end

  describe "the thirty-day lapse" do
    setup [:seeded]

    test "advancing thirty-one days past an engagement end lapses visibility", %{
      manifest: manifest
    } do
      assert Peers.visible?(person_scope(manifest, :tomo), manifest.people.luka)

      {:ok, _instant} = Demo.advance_clock(day: 31)

      refute Peers.visible?(person_scope(manifest, :tomo), manifest.people.luka)
    end

    test "and the request that depended on it reports :lapsed", %{manifest: manifest} do
      {:ok, _instant} = Demo.advance_clock(day: 31)

      assert {:ok, request} =
               Peers.fetch_request(person_scope(manifest, :tomo), manifest.pending_request_id)

      assert request.state == :lapsed
    end

    test "and the accepted connection is untouched, which is the control", %{manifest: manifest} do
      {:ok, before} = Peers.list_messages(person_scope(manifest, :tomo), manifest.connection_id)

      {:ok, _instant} = Demo.advance_clock(day: 31)

      scope = person_scope(manifest, :tomo)

      assert {:ok, conversation} = Peers.fetch_conversation(scope, manifest.connection_id)
      assert is_nil(conversation.disconnected_at)
      assert Peers.list_messages(scope, manifest.connection_id) == {:ok, before}
    end
  end

  describe "end_all_engagements/1" do
    setup [:seeded]

    test "leaves the person's profile readable", %{manifest: manifest} do
      entries = Profiles.list_attested_entries(person_scope(manifest, :tomo))

      assert {:ok, closed} = Demo.end_all_engagements(manifest.people.tomo)
      assert length(closed) == 2

      # The same entries, by identity. Their `ends_at` moves, which is the point
      # — the record follows the employment rather than vanishing with it.
      assert Enum.map(
               Profiles.list_attested_entries(person_scope(manifest, :tomo)),
               & &1.attested_entry_id
             ) ==
               Enum.map(entries, & &1.attested_entry_id)

      assert length(entries) == 2
    end

    test "and leaves their conversations sending and receiving", %{manifest: manifest} do
      {:ok, _closed} = Demo.end_all_engagements(manifest.people.tomo)

      tomo = person_scope(manifest, :tomo)
      ana = person_scope(manifest, :ana)

      assert {:ok, message} = Peers.send_message(tomo, manifest.connection_id, "still around")
      assert {:ok, seen} = Peers.list_messages(ana, manifest.connection_id)
      assert message.id in Enum.map(seen, & &1.id)
    end

    test "and leaves their own retained message copies", %{manifest: manifest} do
      before = Lifecycle.list_retained_messages(person_scope(manifest, :tomo))

      {:ok, _closed} = Demo.end_all_engagements(manifest.people.tomo)

      assert before != []

      assert Enum.map(Lifecycle.list_retained_messages(person_scope(manifest, :tomo)), & &1.id) ==
               Enum.map(before, & &1.id)
    end

    test "and leaves them holding zero engagements, which is the control", %{manifest: manifest} do
      {:ok, _closed} = Demo.end_all_engagements(manifest.people.tomo)

      assert Engagements.list_person_engagements(person_scope(manifest, :tomo)) == []
    end

    test "refuses a venue's last grant-holding engagement, and says it closed nothing", %{
      manifest: manifest
    } do
      # The third element is not decoration: each close is its own transaction
      # and the pre-flight takes no lock, so a refusal from inside the loop
      # leaves what it closed committed. Here the refusal is the pre-flight's,
      # so the list is empty — and it is now rendered rather than asserted in
      # the message.
      assert Demo.end_all_engagements(manifest.people.ana) == {:error, :last_grant_holder, []}
    end

    test "and ends none of that person's other engagements, which is the control", %{
      manifest: manifest
    } do
      before = Engagements.list_person_engagements(person_scope(manifest, :ana))

      {:error, :last_grant_holder, []} = Demo.end_all_engagements(manifest.people.ana)

      assert Enum.map(Engagements.list_person_engagements(person_scope(manifest, :ana)), & &1.id) ==
               Enum.map(before, & &1.id)

      assert length(before) == 2
    end

    test "answers :not_found for an id naming nobody, and for one that is not an id" do
      assert Demo.end_all_engagements(Ecto.UUID.generate()) == {:error, :not_found, []}
      assert Demo.end_all_engagements("not-a-uuid") == {:error, :not_found, []}
    end

    test "and for a person id supplied as the sixteen bytes it dumps to", %{manifest: manifest} do
      # `Ecto.UUID.cast/1` accepts a raw sixteen-byte UUID and encodes it, so
      # without the byte-size guard this is a working spelling of Tomo's id that
      # no other surface in this application accepts — and a percent-encoded
      # path segment carries arbitrary bytes. `ChannelAuth.topic_id/1` has the
      # guard; the comment here claimed parity the code did not have.
      {:ok, raw} = Ecto.UUID.dump(manifest.people.tomo)

      assert byte_size(raw) == 16
      assert Ecto.UUID.cast(raw) == {:ok, manifest.people.tomo}
      assert Demo.end_all_engagements(raw) == {:error, :not_found, []}
      assert length(Engagements.list_person_engagements(person_scope(manifest, :tomo))) == 2
    end

    test "succeeds with an empty list for a person holding nothing", %{manifest: manifest} do
      assert Demo.end_all_engagements(manifest.people.luka) == {:ok, []}
    end
  end

  describe "end_all_engagements/1 under a clock wound backwards" do
    setup [:seeded]

    test "leaves a term that has not opened exactly where it was", %{manifest: manifest} do
      # The target set is what the person *holds* at the control's instant, not
      # "every term that has not closed". `end_engagement/2`'s own set is one
      # state wider on purpose, so a claim made in error can be taken back —
      # and that widening closes at `max(starts_at, now)`, which for a term that
      # has not opened is the empty range. Applied to every engagement a person
      # holds it does not end employment, it un-writes it.
      before = engagement_bounds(manifest.engagements.mira_harbour)

      {:ok, _instant} = Demo.advance_clock(day: -202)

      assert Demo.end_all_engagements(manifest.people.mira) == {:ok, []}
      assert engagement_bounds(manifest.engagements.mira_harbour) == before
      assert {starts_at, ends_at} = before
      assert DateTime.compare(starts_at, ends_at) == :lt
    end

    test "and does not poison run_due_work/0 for ever", %{manifest: manifest} do
      # C2, measured. Closing Mira's term at an instant before it opened gave it
      # `ends_at == starts_at` two hundred days before the words spoken inside
      # it, and the archive deadline is `ends_at + 90 days` —
      # `retained_message_copies_deadline_after_sending` refuses a copy dated
      # before its own message. Postgres evaluates a CHECK on the candidate row
      # *before* `ON CONFLICT` arbitration, so `backfill_copies/3`'s
      # `on_conflict: :nothing` did not save the message that was already
      # copied, and `run_due_work/0`'s unbounded lower edge re-reached the term
      # on every later run whatever the clock said. `mix ecto.reset` was the
      # only way out.
      {:ok, _instant} = Demo.advance_clock(day: -202)
      {:ok, []} = Demo.end_all_engagements(manifest.people.mira)
      {:ok, _instant} = Demo.advance_clock(day: 3)

      assert {:ok, _work} = Demo.run_due_work()

      :ok = Clock.Offset.set(@instant)

      assert {:ok, work} = Demo.run_due_work()
      assert work.retention.outcome == :completed
    end
  end

  describe "the controls and an employer session" do
    setup [:seeded]

    test "an employer scope is refused by function clause", %{manifest: manifest} do
      scope = untyped(employer_scope(manifest, :harbour))

      assert_raise FunctionClauseError, fn -> Demo.end_all_engagements(scope) end
    end

    test "and an employer session cannot see the cross-venue set the control operates on", %{
      manifest: manifest
    } do
      {:ok, harbour} = Engagements.list_engagements(employer_scope(manifest, :harbour))

      tomo_at_harbour =
        Enum.filter(harbour, &(&1.person_id == manifest.people.tomo))

      assert length(tomo_at_harbour) == 1
      assert Enum.all?(harbour, &(&1.venue_id == manifest.venues.harbour))

      assert length(Engagements.list_person_engagements(person_scope(manifest, :tomo))) == 2
    end
  end

  describe "the fixtures and the seeds script" do
    test "EngagementsFixtures.purge/0 removes a seeded manifest" do
      {:ok, _manifest} = Demo.seed()

      assert Repo.aggregate(
               from(venue in Venue, where: like(venue.name, ^Demo.venue_pattern())),
               :count
             ) ==
               2

      :ok = EngagementsFixtures.purge()

      assert Repo.aggregate(
               from(venue in Venue, where: like(venue.name, ^Demo.venue_pattern())),
               :count
             ) ==
               0
    end

    test "priv/repo/seeds.exs refuses to run under MIX_ENV=test" do
      assert_raise RuntimeError, ~r/Do not seed the test database/, fn ->
        Code.eval_file("priv/repo/seeds.exs")
      end
    end
  end

  describe "the production build" do
    test "compiles lib/ and nothing else" do
      assert HospitalityComs.MixProject.elixirc_paths(:prod) == ["lib"]
      assert "dev_support" in HospitalityComs.MixProject.elixirc_paths(:dev)
    end

    test "so every module in dev_support/ is absent from it" do
      prod = HospitalityComs.MixProject.elixirc_paths(:prod)

      assert Demo in dev_support_modules()
      assert Clock.Offset in dev_support_modules()
      assert HospitalityComsWeb.DemoController in dev_support_modules()

      # Quantified over the directory rather than over the three named above, so
      # a fourth demo module is covered without anybody remembering to add it.
      #
      # It compares each module's compiled source against the paths `:prod`
      # actually compiles. An earlier form compared `dev_support_modules()`
      # against `library_modules()`, which are disjoint by construction — the
      # two are *defined* by the source segment they are filtered on — so it was
      # invariant under every possible change to `mix.exs` and could not fail.
      for module <- dev_support_modules() do
        refute Enum.any?(prod, &compiled_from?(module, &1)),
               "#{inspect(module)} is compiled from a path the production build includes"
      end

      # The control: every module in `lib/` *is* reached by one of those paths,
      # so the check above is about which paths are listed and not about the
      # matching never finding anything.
      assert Enum.all?(library_modules(), fn module ->
               Enum.any?(prod, &compiled_from?(module, &1))
             end)
    end

    test "and no module compiled from lib/ calls one compiled from dev_support/" do
      # **`assert offenders == []` is the canonical assertion that is vacuous on
      # an empty result, and both operands of this sweep are quantified over.**
      # Measured: `library_modules/0` returning `[]` left all 53 tests in this
      # file passing, while `dev_support_modules/0` returning `[]` killed one —
      # and the asymmetry was the defect, because the guarded half was the other
      # test's. The floors below are the manoeuvre that half already uses.
      # Eleven assertions in this project have read as coverage while providing
      # none; two of them were found in this unit, one of them here.
      assert HospitalityComs.Engagements in library_modules()
      assert HospitalityComsWeb.PersonAuth in library_modules()
      assert length(library_modules()) > 50

      assert Demo in dev_support_modules()
      assert length(dev_support_modules()) >= 3

      offenders =
        Enum.filter(library_modules(), fn module ->
          Enum.any?(called_modules(module), &(&1 in dev_support_modules()))
        end)

      assert offenders == []
    end

    test "which the same detector does find in dev_support/, the control" do
      assert Clock.Offset in called_modules(Demo)
    end

    test "and no production config file names the override or the demo routes" do
      for path <- ~w(config/config.exs config/prod.exs config/runtime.exs) do
        source = File.read!(path)

        refute source =~ "Clock.Offset", "#{path} names the offsettable clock"
        refute source =~ "demo_routes", "#{path} names the demo routes"
      end

      assert File.read!("config/dev.exs") =~ "demo_routes"
      assert File.read!("config/test.exs") =~ "demo_routes"
    end
  end

  describe "the queues in the two environments the controls run in" do
    test "neither of them lets a cron tick drive a worker" do
      # **The claim "a clock advance alone deletes nothing" is environment-
      # conditional and nothing recorded that.** It holds in `:test` because
      # `testing: :manual` is set there. `:dev` set no such thing, and Oban's
      # cron stages at the *real* instant while `RetentionSweeper.perform/1`
      # reads the *injected* clock — so `advance_clock(day: 31)` and nothing
      # else deleted a month of retained messages within the hour, unattended,
      # in the one environment these controls exist for. The wall-clock argument
      # in `Demo`'s moduledoc covers the claim-scheduled `ExpireEngagement` job,
      # which genuinely waits; it does not cover cron.
      for env <- [:dev, :test] do
        oban = oban_config(env)

        assert oban[:testing] == :manual,
               "config/#{env}.exs lets Oban run queues and plugins beside an injected clock"
      end
    end

    test "and the configuration they override really does schedule both, the control" do
      oban = oban_config(:dev)

      assert Enum.any?(oban[:plugins], &match?({Oban.Plugins.Cron, _crontab}, &1))
      assert oban[:queues] != []
    end
  end

  ## Setup

  # A scope handed through a map so the type checker cannot see the refusal at
  # the call site. `peers_test.exs`'s idiom and its reason: a scope built at run
  # time from a session carries no compile-time proof, and it is the run-time
  # refusal the boundary rests on.
  # Named `untyped/1` rather than `dynamic/1` because this file imports
  # `Ecto.Query`, which exports a macro of that name.
  defp untyped(scope), do: Map.fetch!(%{scope: scope}, :scope)

  defp seeded(_context) do
    {:ok, manifest} = Demo.seed()
    %{manifest: manifest}
  end

  ## Scopes

  defp person_scope(manifest, label) do
    manifest.people
    |> Map.fetch!(label)
    |> Accounts.get_person!()
    |> PersonScope.for_person(Clock.now())
  end

  # An employer scope built the way `HospitalityComsWeb.ChannelAuth` builds one:
  # from the engagement at that venue which holds a grant the venue has not
  # revoked. There is no separate employer credential in this tree.
  defp employer_scope(manifest, :harbour = label) do
    venue_id = Map.fetch!(manifest.venues, label)
    scope = person_scope(manifest, :mira)

    {:ok, engagement} = Engagements.fetch_grant_holding_engagement(scope, venue_id)

    EmployerScope.for_grant(venue_id, engagement.grant_id, scope.now)
  end

  ## Counting

  # Every base table, from `information_schema`, which is `lifecycle_test.exs`'s
  # reader and `TestDatabaseGuard`'s source. A list of schemas written out here
  # is a list somebody forgets to extend, and the four it named left nineteen
  # tables in which a second seed could write freely.
  defp census do
    # The identifier is quoted by Postgres's own `format('%I')` rather than
    # spliced raw, which is `HospitalityComs.TestDatabaseGuard`'s rule for the
    # same sweep. Every table here happens to be a bare lowercase word today, so
    # raw interpolation works — and would silently mis-count, or error, against
    # the first one that is a reserved word or carries a capital.
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name, format('%I', table_name) FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        ORDER BY table_name
        """,
        []
      )

    Map.new(rows, fn [table, quoted] ->
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{quoted}", [])
      {table, count}
    end)
  end

  defp oban_config(env) do
    "config/config.exs" |> Config.Reader.read!(env: env) |> get_in([:hospitality_coms, Oban])
  end

  defp engagement_bounds(engagement_id) do
    Repo.one!(
      from engagement in Engagement,
        where: engagement.id == ^engagement_id,
        select: {engagement.starts_at, engagement.ends_at}
    )
  end

  defp shift_message_count(shift_room_id) do
    Repo.aggregate(from(m in RoomMessage, where: m.shift_room_id == ^shift_room_id), :count)
  end

  defp roster_count(shift_room_id) do
    Repo.aggregate(from(e in RosterEntry, where: e.shift_room_id == ^shift_room_id), :count)
  end

  defp archive_deadlines(person_id) do
    Repo.all(
      from copy in RetainedMessageCopy,
        where: copy.person_id == ^person_id,
        distinct: true,
        select: copy.delete_after
    )
  end

  defp swept_ids(instant) do
    instant
    |> Engagements.list_expired(~U[1970-01-01 00:00:00.000000Z], EngagementSweeper.batch_size())
    |> Enum.map(& &1.id)
  end

  ## The build, read out of the compiled modules

  defp library_modules, do: modules_under("/lib/")
  defp dev_support_modules, do: modules_under("/dev_support/")

  defp modules_under(segment) do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)

    Enum.filter(modules, fn module ->
      Code.ensure_loaded?(module) and String.contains?(source_of(module), segment)
    end)
  end

  defp source_of(module) do
    module.module_info(:compile) |> Keyword.get(:source, ~c"") |> to_string()
  end

  defp compiled_from?(module, path), do: String.contains?(source_of(module), "/#{path}/")

  # Out of the `imports` chunk, the way `lifecycle_test.exs` reads deletes and
  # `peers_test.exs` reads query builders. It sees *calls*, which is exactly the
  # relation that breaks a production compile; a bare module reference compiles
  # in `:prod` whether or not the module is there, and the CI prod-compile step
  # is what covers the struct-expansion case this cannot see.
  defp called_modules(module) do
    {:ok, {^module, [imports: imports]}} =
      module |> :code.which() |> :beam_lib.chunks([:imports])

    imports |> Enum.map(fn {called, _function, _arity} -> called end) |> Enum.uniq()
  end
end
