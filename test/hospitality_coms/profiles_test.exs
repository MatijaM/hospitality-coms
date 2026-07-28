defmodule HospitalityComs.ProfilesTest do
  @moduledoc """
  The worker's portable record, and the rules about who may read which part of
  it.

  ## Why nothing here is sandboxed

  For the reason `HospitalityComs.EngagementsFixtures` gives and this unit makes
  sharper than any before it. An attested entry is written by the claim, which
  spans both repos; and the thing under test is a **view** read through
  `HospitalityComs.EmployerRepo` over rows written through
  `HospitalityComs.Repo`. Under the sandbox those are two transactions that
  cannot see each other's rows, so every employer read would come back empty and
  every negative assertion in the file would pass for the wrong reason.

  So the fixtures commit for real, every row carries the `u5-venue` / `u5-person`
  prefix, and `EngagementsFixtures.purge/0` — extended in U9 with the three new
  tables — removes them before and after each test.

  ## The one thing to read before changing an assertion here

  **The concurrency default is a comparison of two stored periods and names no
  instant.** That is what makes two of the issue's scenarios true at once: the
  default corrects itself when an engagement's dates move, *and* an entry hidden
  while the terms overlapped stays hidden after they stop overlapping. A default
  written as "concurrent at this instant" satisfies the first and fails the
  second by re-disclosing a second job at the moment it ends, which is the leak
  the default exists to prevent. "stays hidden once the terms have stopped
  overlapping" is the test that would catch it.
  """

  use ExUnit.Case, async: false

  import HospitalityComs.EngagementsFixtures, only: [real_connections: 0]

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.EmployerRepo.ZoneViolationError
  alias HospitalityComs.Engagements
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Peers
  alias HospitalityComs.PeersFixtures
  alias HospitalityComs.Profiles
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Profiles.CorrectionRequest
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Profiles.Records
  alias HospitalityComs.Profiles.VisibleEntry
  alias HospitalityComs.Repo

  @now ~U[2026-03-01 12:00:00.000000Z]

  @profiles_namespace "Elixir.HospitalityComs.Profiles."

  # Exactly what an employer read hands back about one entry, written out here
  # and not derived from the struct. Deriving it is what made the oracle control
  # vacuous: `Map.keys/1` of two structs of one type is equal by construction.
  @visible_entry_fields [
    :attested_entry_id,
    :entry_engagement_id,
    :venue_id,
    :venue_name,
    :role_label,
    :starts_at,
    :ends_at,
    :attested_at
  ]

  # Everything `HospitalityComs.Profiles` exports, written out. What makes "no
  # function here writes an attested entry" a claim about the module rather than
  # about the words somebody chose for a function name.
  @public_api [
    amend_declared_entry: 3,
    declare_entry: 2,
    fetch_peer_profile: 2,
    incompleteness_notice: 0,
    list_attested_entries: 1,
    list_correction_requests: 1,
    list_declared_entries: 1,
    list_disclosures: 1,
    list_venue_corrections: 1,
    list_visible_corrections: 2,
    list_visible_entries: 2,
    own_profile: 1,
    request_correction: 3,
    resolve_correction: 3,
    set_disclosure: 4
  ]

  # The two fields that legitimately differ between two workers' entries. Every
  # other field of two reads of the same shape must be equal, so anything a
  # later unit adds is compared rather than ignored.
  @entry_identity [:attested_entry_id, :entry_engagement_id]

  setup do
    real_connections()
  end

  describe "attested entries" do
    test "appear when an engagement is created and carry its role label" do
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30), role_label: "Sommelier")

      assert [entry] = Profiles.list_attested_entries(worker)
      assert entry.entry_engagement_id == engagement.id
      assert entry.venue_id == place.venue.id
      assert entry.venue_name == place.venue.name
      assert entry.role_label == "Sommelier"
      assert DateTime.compare(entry.starts_at, @now) == :eq
      assert DateTime.compare(entry.ends_at, days(30)) == :eq
    end

    test "stay one per engagement when the term is renewed" do
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      assert {:ok, _renewed} =
               Engagements.renew_engagement(place.employer, engagement.id, days(60))

      assert [entry] = Profiles.list_attested_entries(worker)
      assert DateTime.compare(entry.ends_at, days(60)) == :eq
    end

    test "cannot be written or edited through this context at all" do
      # **Issue scenario 2**, structurally. There is no function here that takes
      # an attested entry and no function that produces one; the claim's
      # transaction is the only writer, and `employer_role` holds no privilege on
      # the table either.
      #
      # **Pinned against the whole export list, and that is the correction.**
      # Filtering for a name *containing* "attested" is satisfied by
      # `edit_entry/3` or `restate/2` — the two spellings a writer would most
      # plausibly arrive under — so the claim rested on a naming convention
      # rather than on anything. The literal list below is what a new function
      # has to be added to, which makes the decision explicit rather than
      # implicit in what somebody called it.
      assert Enum.sort(Profiles.__info__(:functions)) == Enum.sort(@public_api)

      writers =
        Enum.filter(@public_api, fn {name, _arity} ->
          name |> Atom.to_string() |> String.contains?("attested")
        end)

      assert writers == [list_attested_entries: 1]
    end

    test "are unchanged by the correction request that contests one" do
      # **Issue scenario 2** as behaviour rather than as an absent function. The
      # worker's only remedy leaves the row it complains about byte-identical.
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      before = Repo.get_by!(AttestedEntry, engagement_id: engagement.id)

      assert {:ok, _request} =
               Profiles.request_correction(worker, engagement.id, %{body: "The dates are wrong."})

      assert Repo.get_by!(AttestedEntry, engagement_id: engagement.id) == before
    end

    test "sit beside two person-zone tables no employer query can compose or read" do
      # `declared_entries` and `attested_entry_disclosures`. Three moduledocs
      # claim the backstop refuses them and nothing asserted it — U6 added a
      # test when it created its one person-zone table and U8 when it created
      # its three, and here it matters most: the ledger carries
      # `audience_venue_id`, so `WHERE audience_venue_id = <me> AND disclosed =
      # false` is the list of workers concealing something from this venue,
      # which is the oracle the standing notice exists not to be.
      #
      # Against rows that actually exist, which is the half
      # `HospitalityComs.BoundaryTest` cannot assert.
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      {:ok, _off} =
        Profiles.set_disclosure(worker, engagement.id, {:venue, place.venue.id}, false)

      {:ok, _declared} = Profiles.declare_entry(worker, declared())

      assert_raise ZoneViolationError, ~r/attested_entry_disclosures/, fn ->
        EmployerRepo.scoped_transaction(place.employer, fn _scope ->
          {:ok, EmployerRepo.all(Disclosure)}
        end)
      end

      assert_raise ZoneViolationError, ~r/declared_entries/, fn ->
        EmployerRepo.scoped_transaction(place.employer, fn _scope ->
          {:ok, EmployerRepo.all(DeclaredEntry)}
        end)
      end

      # And the tier below the backstop, which a raw statement is the only way
      # to reach: the oracle query itself, refused by Postgres.
      assert_raise Postgrex.Error,
                   ~r/permission denied for table attested_entry_disclosures/,
                   fn ->
                     EmployerRepo.scoped_transaction(place.employer, fn _scope ->
                       {:ok,
                        EmployerRepo.query!(
                          """
                          SELECT engagement_id FROM attested_entry_disclosures
                          WHERE audience_venue_id = $1 AND disclosed = false
                          """,
                          [Ecto.UUID.dump!(place.venue.id)]
                        )}
                     end)
                   end
    end

    test "are unreachable to the employer role on the base table" do
      # **Issue scenario 7**, the tier below both BEAM guards: a raw statement is
      # not an `Ecto.Query`, so the zone backstop never sees it and Postgres is
      # the only thing left.
      place = venue()
      engage(place, person(), @now, days(30))

      assert_raise Postgrex.Error, ~r/permission denied for table attested_entries/, fn ->
        EmployerRepo.scoped_transaction(place.employer, fn _scope ->
          {:ok, EmployerRepo.query!("SELECT id FROM attested_entries", [])}
        end)
      end
    end
  end

  describe "the employer-visible view" do
    test "shows a venue its own assertion about its own worker" do
      # The control for every negative assertion in this block: a view that
      # returned nothing would satisfy all of them.
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      assert [entry] = visible(place, engagement)
      assert entry.venue_id == place.venue.id
      assert entry.entry_engagement_id == engagement.id
    end

    test "hides a concurrent engagement at another venue" do
      # **Issue scenario 3.**
      %{worker: worker, elsewhere: elsewhere, here: here, viewer: viewer} =
        concurrent_at_two_venues()

      assert venue_ids(visible(here, viewer)) == [here.venue.id]
      refute elsewhere.venue.id in venue_ids(visible(here, viewer))
      assert [_own, _other] = Profiles.list_attested_entries(worker)
    end

    test "shows a non-concurrent past engagement at another venue by default" do
      # **Issue scenario 4**, and the control for the test above: a default that
      # hid everything would satisfy "a concurrent engagement is absent".
      there = venue()
      here = venue()
      worker = person()

      engage(there, worker, days(-100), days(-70))
      viewer = engage(here, worker, days(-5), days(30))

      assert venue_ids(visible(here, viewer)) == [there.venue.id, here.venue.id]
    end

    test "keeps an entry hidden once the terms have stopped overlapping" do
      # **Issue scenario 5**, and the single most load-bearing assertion in the
      # file. The other venue's term ended ten days ago, so the two engagements
      # are not concurrent *at this instant* — and they overlapped, which is a
      # fact about two periods rather than about now, so the entry stays hidden.
      #
      # A default written as "concurrent at `app_current_instant()`" passes every
      # other test in this block and fails this one, by re-disclosing a second
      # job at the moment it ends.
      there = venue()
      here = venue()
      worker = person()

      engage(there, worker, days(-100), days(-10))
      viewer = engage(here, worker, days(-50), days(30))

      assert venue_ids(visible(here, viewer)) == [here.venue.id]
    end

    test "treats terms that merely abut as not concurrent" do
      # The half-open reading of overlap, on the boundary instant. `[a, b)` and
      # `[b, c)` share no instant, so nothing is hidden — the same convention
      # every other interval in the tree uses (KTD4).
      there = venue()
      here = venue()
      worker = person()

      engage(there, worker, days(-60), days(-30))
      viewer = engage(here, worker, days(-30), days(30))

      assert venue_ids(visible(here, viewer)) == [there.venue.id, here.venue.id]
    end

    test "treats an empty subject term as overlapping nothing" do
      # An engagement ended before it started is `ends_at == starts_at`, the
      # empty range. The endpoint form of overlap reports one for it — measured
      # by U6 on roster entries and needed again by U8 — so the view carries
      # `subject.starts_at < subject.ends_at` and this is that clause.
      #
      # The term has to be in the *future* for `end_engagement/2` to produce the
      # empty range at all: it closes at the later of the caller's instant and
      # the engagement's own start, and an employer scope cannot be placed
      # before the venue's grant was issued.
      there = venue()
      here = venue()
      worker = person()

      emptied = engage(there, worker, days(20), days(50))
      {:ok, closed} = Engagements.end_engagement(there.employer, emptied.id)
      assert DateTime.compare(closed.ends_at, closed.starts_at) == :eq

      viewer = engage(here, worker, days(-5), days(30))

      assert Enum.sort(venue_ids(visible(here, viewer))) ==
               Enum.sort([there.venue.id, here.venue.id])
    end

    test "treats an empty stint at the viewing venue as overlapping nothing" do
      # The other side of the same clause, and it needs its own test: a matrix
      # that only ever binds the empty term to one of the two sides leaves a
      # mutation of the other passing, which is what U8 found on
      # `co_engagements/1`.
      there = venue()
      here = venue()
      worker = person()

      emptied = engage(here, worker, days(20), days(50))
      {:ok, closed} = Engagements.end_engagement(here.employer, emptied.id)
      assert DateTime.compare(closed.ends_at, closed.starts_at) == :eq

      engage(there, worker, days(15), days(30))
      viewer = engage(here, worker, days(-5), days(10))

      assert there.venue.id in venue_ids(visible(here, viewer))
    end

    test "hides an entry that overlapped an earlier stint at the viewing venue" do
      # `NOT EXISTS` ranges over every stint the person has held here, not only
      # the one being viewed through. A worker whose first stint overlapped their
      # job elsewhere has already been co-located with this venue, and a join to
      # the current stint alone would re-disclose it.
      there = venue()
      here = venue()
      worker = person()

      engage(there, worker, days(-90), days(-70))
      engage(here, worker, days(-100), days(-60))
      viewer = engage(here, worker, days(-5), days(30))

      # Both of this venue's own entries come back — a venue always sees its own
      # assertions — and the one from elsewhere does not.
      refute there.venue.id in venue_ids(visible(here, viewer))
      assert venue_ids(visible(here, viewer)) == [here.venue.id, here.venue.id]
    end

    test "corrects the default when the entry's dates move, with nothing having run" do
      # The plan's own words: "changing an engagement's dates corrects the
      # default automatically". Nothing is materialised, so the write that moves
      # the term is the whole of the correction.
      there = venue()
      here = venue()
      worker = person()

      elsewhere = engage(there, worker, @now, days(30))
      viewer = engage(here, worker, days(10), days(40))

      assert venue_ids(visible(here, viewer, days(15))) == [here.venue.id]

      {:ok, _closed} = Engagements.end_engagement(employer_at(there, days(5)), elsewhere.id)

      assert venue_ids(visible(here, viewer, days(15))) == [there.venue.id, here.venue.id]
    end

    test "shows nothing once the viewing engagement has ended" do
      # The half of the rule that *is* time-derived: an employer sees the people
      # holding an engagement at its venue active at the scope's instant, so an
      # ex-worker leaves its reach with no job having run.
      place = venue()
      worker = person()
      viewer = engage(place, worker, @now, days(30))

      assert [_entry] = visible(place, viewer, days(29))
      assert visible(place, viewer, days(30)) == []
    end

    test "returns nothing for an engagement belonging to another venue" do
      # Tenancy, and AE1. The view resolves its own venue from
      # `app_current_employer_id()`, so another venue's engagement matches
      # nothing rather than being refused — a refusal would confirm that the
      # engagement exists.
      here = venue()
      there = venue()
      worker = person()

      viewer = engage(here, worker, @now, days(30))
      engage(there, worker, days(-100), days(-70))

      refute visible(here, viewer) == []
      assert visible(there, viewer) == []
      assert visible(here, %{id: Ecto.UUID.generate()}) == []
    end

    test "answers the same under a session time zone that is not UTC" do
      # **The regression test the `AT TIME ZONE 'UTC'` fix never had.**
      # `app_current_instant()` returns `timestamptz`; Ecto's `:utc_datetime` is
      # `timestamp` *without* one, so comparing them makes Postgres convert the
      # column using the session's `TimeZone`, which nothing in this application
      # sets. The suite runs under `Etc/UTC`, which is exactly why the bug was
      # invisible — and why nothing pinned the fix either.
      #
      # Measured with the conversion removed: this read comes back empty under
      # `America/New_York`, because `2026-03-01 12:00:00` read as local is
      # `17:00Z` and the viewer's engagement has not started yet.
      place = venue()
      worker = person()
      viewer = engage(place, worker, @now, days(30))

      # The control, at the server's own default.
      assert [_entry] = visible(place, viewer)

      assert {:ok, [shifted]} =
               EmployerRepo.scoped_transaction(employer_at(place, @now), fn _scope ->
                 EmployerRepo.query!("SET LOCAL TimeZone = 'America/New_York'", [])
                 {:ok, EmployerRepo.all(Records.employer_visible_entries(viewer.id))}
               end)

      assert shifted.entry_engagement_id == viewer.id
    end

    test "raises rather than returning nothing when read outside the wrapper" do
      # U3 built `app_current_employer_id()` to raise for exactly this, and this
      # is the first test in the tree where the relation behind it has rows: an
      # empty result and a NULL-filtered result are indistinguishable, and a
      # worker who has disclosed nothing looks the same as a boundary that
      # silently failed.
      place = venue()
      engage(place, person(), @now, days(30))

      assert_raise Postgrex.Error, ~r/is not set on this connection/, fn ->
        EmployerRepo.query!("SELECT * FROM employer_visible_attested_entries", [])
      end
    end

    test "refuses an employer scope holding no grant, by function clause" do
      place = venue()
      worker = person()
      viewer = engage(place, worker, @now, days(30))

      grantless = EmployerScope.for_employer(place.venue.id, @now)

      assert_raise FunctionClauseError, fn ->
        Profiles.list_visible_entries(dynamic(grantless), viewer.id)
      end

      # And the second read, which had no such test. `for_employer/2` builds a
      # scope with tenancy and no authority; every employer function here heads
      # on `grant_id` being a binary, so the refusal happens before the body
      # runs rather than inside it.
      assert_raise FunctionClauseError, fn ->
        Profiles.list_visible_corrections(dynamic(grantless), viewer.id)
      end

      assert_raise FunctionClauseError, fn ->
        Profiles.list_venue_corrections(dynamic(grantless))
      end

      assert_raise FunctionClauseError, fn ->
        Profiles.resolve_correction(dynamic(grantless), Ecto.UUID.generate(), :declined)
      end
    end

    test "refuses a grant that belongs to another venue, on all four employer paths" do
      # `{:error, :no_grant}` is enumerated in four specs and was asserted
      # nowhere. The grant is resolved against the database on every call —
      # live at the scope's instant and belonging to the scope's venue — and a
      # scope naming another venue's grant is refused before any read happens.
      place = venue()
      elsewhere = venue()
      worker = person()

      engagement = engage(place, worker, @now, days(30))
      {:ok, request} = Profiles.request_correction(worker, engagement.id, %{body: "Wrong role."})

      forged = EmployerScope.for_grant(place.venue.id, elsewhere.grant.id, @now)

      assert Profiles.list_visible_entries(forged, engagement.id) == {:error, :no_grant}
      assert Profiles.list_visible_corrections(forged, engagement.id) == {:error, :no_grant}
      assert Profiles.list_venue_corrections(forged) == {:error, :no_grant}
      assert Profiles.resolve_correction(forged, request.id, :declined) == {:error, :no_grant}

      # The control: the same four calls under the venue's own grant answer.
      assert {:ok, [_entry]} = Profiles.list_visible_entries(place.employer, engagement.id)
      assert {:ok, [_seen]} = Profiles.list_visible_corrections(place.employer, engagement.id)
      assert {:ok, [_own]} = Profiles.list_venue_corrections(place.employer)
      assert {:ok, _resolved} = Profiles.resolve_correction(place.employer, request.id, :declined)
    end
  end

  describe "disclosure, per employer" do
    test "reveals a concurrent entry the default hid" do
      %{worker: worker, elsewhere: elsewhere, here: here, viewer: viewer, other: other} =
        concurrent_at_two_venues()

      assert venue_ids(visible(here, viewer)) == [here.venue.id]

      assert {:ok, disclosure} =
               Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, true)

      assert disclosure.disclosed

      assert Enum.sort(venue_ids(visible(here, viewer))) ==
               Enum.sort([elsewhere.venue.id, here.venue.id])
    end

    test "removes it again when the disclosure is revoked" do
      # **Issue scenario 6.** Nothing is cached and no job runs: the write and
      # the next read are the whole mechanism.
      %{worker: worker, here: here, viewer: viewer, other: other} = concurrent_at_two_venues()

      {:ok, _on} = Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, true)
      assert length(visible(here, viewer)) == 2

      assert {:ok, off} =
               Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, false)

      refute off.disclosed

      assert venue_ids(visible(here, viewer)) == [here.venue.id]
    end

    test "hides a non-concurrent entry the default would have shown" do
      there = venue()
      here = venue()
      worker = person()

      elsewhere = engage(there, worker, days(-100), days(-70))
      viewer = engage(here, worker, days(-5), days(30))

      assert length(visible(here, viewer)) == 2

      assert {:ok, _off} =
               Profiles.set_disclosure(worker, elsewhere.id, {:venue, here.venue.id}, false)

      assert venue_ids(visible(here, viewer)) == [here.venue.id]
    end

    test "binds the audience it names and no other venue" do
      there = venue()
      here = venue()
      third = venue()
      worker = person()

      elsewhere = engage(there, worker, days(-100), days(-70))
      here_viewer = engage(here, worker, days(-5), days(30))
      third_viewer = engage(third, worker, days(-4), days(30))

      assert {:ok, _off} =
               Profiles.set_disclosure(worker, elsewhere.id, {:venue, here.venue.id}, false)

      assert venue_ids(visible(here, here_viewer)) == [here.venue.id]
      assert there.venue.id in venue_ids(visible(third, third_viewer))
    end

    test "leaves a venue's own assertion visible to it whatever the ledger says" do
      # The own-venue branch. Hiding a venue's own record from itself is not a
      # thing disclosure means, and the ledger row is inert rather than refused —
      # a refusal would be a rule the worker has to learn.
      place = venue()
      worker = person()
      viewer = engage(place, worker, @now, days(30))

      assert {:ok, _off} =
               Profiles.set_disclosure(worker, viewer.id, {:venue, place.venue.id}, false)

      assert venue_ids(visible(place, viewer)) == [place.venue.id]
    end

    test "replaces the decision rather than adding a second row" do
      %{worker: worker, here: here, other: other} = concurrent_at_two_venues()

      assert {:ok, first} =
               Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, true)

      assert {:ok, second} =
               Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, false)

      assert second.id == first.id
      refute second.disclosed
      assert [^second] = Profiles.list_disclosures(worker)
    end

    test "refuses an engagement that is not the caller's, and an id that names nothing" do
      %{worker: worker, here: here, other: other} = concurrent_at_two_venues()
      stranger = person()

      assert Profiles.set_disclosure(stranger, other.id, {:venue, here.venue.id}, false) ==
               {:error, :not_found}

      assert Profiles.set_disclosure(worker, Ecto.UUID.generate(), {:venue, here.venue.id}, false) ==
               {:error, :not_found}
    end

    test "refuses a venue that does not exist, as a changeset error" do
      %{worker: worker, other: other} = concurrent_at_two_venues()

      assert {:error, changeset} =
               Profiles.set_disclosure(worker, other.id, {:venue, Ecto.UUID.generate()}, false)

      assert %{audience_venue_id: ["does not exist"]} = errors_on(changeset)
    end

    test "refuses a row naming somebody else's engagement, in the database" do
      # **The ownership rule, one tier below the check that produces
      # `:not_found`.** Every other ownership rule in this tree is a composite
      # foreign key — `attested_entries`, `roster_entries`, `room_messages` and
      # `correction_requests` all key into `engagements (id, venue_id)` — and
      # this was the one resting on application code alone. It is now
      # `(engagement_id, person_id)` into `engagements (id, person_id)`, MATCH
      # FULL, so a writer that did not go through `set_disclosure/4` is refused
      # by Postgres.
      %{worker: worker, here: here, other: other} = concurrent_at_two_venues()
      stranger = person()
      %Person{id: stranger_id} = stranger.person

      forged = %Disclosure{
        engagement_id: other.id,
        person_id: stranger_id,
        audience_venue_id: here.venue.id,
        disclosed: true,
        decided_at: DateTime.truncate(@now, :second)
      }

      assert_raise Ecto.ConstraintError,
                   ~r/attested_entry_disclosures_engagement_fkey/,
                   fn -> Repo.insert!(forged) end

      # The control: the same row under its real owner is accepted, so the
      # refusal above is the key rather than the shape.
      %Person{id: worker_id} = worker.person

      assert {:ok, _row} = Repo.insert(%{forged | person_id: worker_id})
    end

    test "refuses a row naming two audiences or none, in the database" do
      # The CHECK, written as `(a IS NULL) <> (b IS NULL)` so it is NULL-proof by
      # construction. `x IS NULL OR y = z` is satisfied by a NULL `y`, which is
      # the shape U8 shipped and had caught; this is the shape that is not.
      %{worker: worker, here: here, other: other} = concurrent_at_two_venues()
      %Person{id: worker_id} = worker.person

      both = %Disclosure{
        engagement_id: other.id,
        person_id: worker_id,
        audience_venue_id: here.venue.id,
        audience_person_id: worker_id,
        disclosed: true,
        decided_at: DateTime.truncate(@now, :second)
      }

      neither = %Disclosure{
        engagement_id: other.id,
        person_id: worker_id,
        disclosed: true,
        decided_at: DateTime.truncate(@now, :second)
      }

      # `Ecto.ConstraintError` rather than `Postgrex.Error`: a bare struct
      # carries no declared constraints, which is what makes this a test of the
      # database rather than of the changeset. `Profiles.set_disclosure/4` can
      # never produce either row — it puts exactly one audience — so the CHECK
      # is what stops a writer that did not go through it.
      assert_raise Ecto.ConstraintError, ~r/attested_entry_disclosures_one_audience/, fn ->
        Repo.insert!(both)
      end

      assert_raise Ecto.ConstraintError, ~r/attested_entry_disclosures_one_audience/, fn ->
        Repo.insert!(neither)
      end
    end
  end

  describe "disclosure, per peer" do
    test "shows a peer the worker's attested entries by default" do
      # The control for this block, and the peer default stated: a peer was
      # co-rostered with this worker and the venue room's roll already told them
      # the venue and the role label, so an entry they can already infer is not
      # worth a default that hides it.
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)

      assert {:ok, profile} = Profiles.fetch_peer_profile(first, second.person.id)
      assert [entry] = profile.attested_entries
      assert entry.role_label == "Bartender"
    end

    test "hides one entry from one named peer and from nobody else" do
      # **Issue scenario 10**, the peer half.
      %{first: first, second: second, second_engagement: engagement, employer: employer} =
        PeersFixtures.co_rostered(@now)

      third = EngagementsFixtures.person_scope_fixture(@now)
      PeersFixtures.engage(employer, third, %{}, @now)

      assert {:ok, _off} =
               Profiles.set_disclosure(second, engagement.id, {:person, first.person.id}, false)

      assert {:ok, %{attested_entries: []}} = Profiles.fetch_peer_profile(first, second.person.id)

      assert {:ok, %{attested_entries: [_entry]}} =
               Profiles.fetch_peer_profile(third, second.person.id)
    end

    test "leaves the employer's view untouched by a peer decision" do
      # **Issue scenario 10**, the independence. Two rows, two audience columns,
      # two readers — one through the view and one through `Repo`.
      %{first: first, second: second, second_engagement: engagement, employer: employer} =
        PeersFixtures.co_rostered(@now)

      assert {:ok, _off} =
               Profiles.set_disclosure(second, engagement.id, {:person, first.person.id}, false)

      assert {:ok, [_entry]} = Profiles.list_visible_entries(employer, engagement.id)
    end

    test "leaves a peer's view untouched by an employer decision" do
      # And the other direction, which is the one the scenario names: an entry
      # hidden from an employer is still the worker's to show a colleague.
      %{first: first, second: second, second_engagement: engagement, employer: employer} =
        PeersFixtures.co_rostered(@now)

      assert {:ok, _off} =
               Profiles.set_disclosure(second, engagement.id, {:venue, employer.venue_id}, false)

      assert {:ok, %{attested_entries: [_entry]}} =
               Profiles.fetch_peer_profile(first, second.person.id)
    end

    test "shows a peer the correction request attached to an entry they can see" do
      # The control for the test below, and the peer half of R16: a request is
      # visible to any viewer of the entry it contests. The employer side has
      # both directions; this side had neither, and nothing anywhere read
      # `profile.correction_requests`.
      %{first: first, second: second, second_engagement: engagement} =
        PeersFixtures.co_rostered(@now)

      {:ok, request} =
        Profiles.request_correction(second, engagement.id, %{body: "The dates are wrong."})

      assert {:ok, profile} = Profiles.fetch_peer_profile(first, second.person.id)
      assert [seen] = profile.correction_requests
      assert seen.correction_request_id == request.id
      assert seen.body == "The dates are wrong."
    end

    test "takes the correction request away with the entry it is hidden with" do
      # **The re-disclosure path nothing closed.** A request carries
      # `venue_id`, `entry_engagement_id` and the worker's own free text, so a
      # rule that reached the entry and not the request would hand back exactly
      # what it had just withheld — under the worker's own words, which is
      # worse than the entry.
      %{first: first, second: second, second_engagement: engagement} =
        PeersFixtures.co_rostered(@now)

      {:ok, _request} =
        Profiles.request_correction(second, engagement.id, %{body: "The dates are wrong."})

      assert {:ok, _off} =
               Profiles.set_disclosure(second, engagement.id, {:person, first.person.id}, false)

      assert {:ok, profile} = Profiles.fetch_peer_profile(first, second.person.id)
      assert profile.attested_entries == []
      assert profile.correction_requests == []
    end

    test "refuses somebody who is neither visible nor connected" do
      %{first: first} = PeersFixtures.co_rostered(@now)
      %{first: stranger} = PeersFixtures.co_rostered(@now)

      assert Profiles.fetch_peer_profile(first, stranger.person.id) == {:error, :not_a_peer}
      assert Profiles.fetch_peer_profile(first, Ecto.UUID.generate()) == {:error, :not_a_peer}
      assert Profiles.fetch_peer_profile(first, first.person.id) == {:error, :not_a_peer}
    end

    test "still answers a connected peer whose visibility has lapsed" do
      # The reason the gate is *visible or connected* and not one of the two. A
      # connection outlives the visibility that produced it (R13), and a profile
      # that vanished would be taken away from two people still in conversation.
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      _connection = PeersFixtures.connection_fixture(first, second)

      later = days(90)
      first_later = PeersFixtures.person_at(first, later)

      refute Peers.visible?(first_later, second.person.id)
      assert Peers.connected?(first_later, second.person.id)

      assert {:ok, %{attested_entries: [_entry]}} =
               Profiles.fetch_peer_profile(first_later, second.person.id)
    end
  end

  describe "the manager who is also a peer" do
    # **The overlap this unit's first cut missed, and the reason it was
    # invisible.** An employer session is a person session plus a venue, so a
    # venue's manager necessarily holds an engagement there — which makes them
    # co-rostered with every worker at that venue, which makes them a *visible
    # peer*, and the peer default is disclosed. The concurrency default the
    # employer view enforces was therefore recoverable by asking the same
    # question through the other door: no grant, nothing manufactured, and no
    # consent step, because `fetch_peer_profile/2` gates on visible **or**
    # connected.
    #
    # Every other test in this file hands the employer scope and the peer scope
    # to two different people. These give both to one, which is what the
    # product actually does.

    test "sees no more of a worker's other venues as a peer than their own venue does" do
      %{manager: manager, worker: worker, here: here, worker_engagement: worker_engagement} =
        manager_and_worker()

      assert venue_ids(visible(here, worker_engagement)) == [here.venue.id]

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(manager, worker.person.id)
      assert venue_ids(peer_view.attested_entries) == [here.venue.id]
    end

    test "keeps the correction request out with the entry it contests" do
      # R16 makes a correction request visible to any viewer of the entry, so
      # the peer read has to apply the same rule to both — the relationship the
      # two employer views already have to each other.
      %{manager: manager, worker: worker, elsewhere_engagement: elsewhere} =
        manager_and_worker()

      {:ok, _request} =
        Profiles.request_correction(worker, elsewhere.id, %{body: "Wrong dates."})

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(manager, worker.person.id)
      assert peer_view.correction_requests == []
    end

    test "still sees an entry the worker disclosed to them by name" do
      # The override layers on top of the new default in both directions, which
      # is what keeps this a default rather than a rule. The control for the two
      # tests above: a peer read that returned nothing would satisfy both.
      %{manager: manager, worker: worker, elsewhere_engagement: elsewhere, here: here} =
        manager_and_worker()

      {:ok, _request} = Profiles.request_correction(worker, elsewhere.id, %{body: "Wrong dates."})

      assert {:ok, _on} =
               Profiles.set_disclosure(worker, elsewhere.id, {:person, manager.person.id}, true)

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(manager, worker.person.id)

      assert Enum.sort(venue_ids(peer_view.attested_entries)) ==
               Enum.sort([here.venue.id, elsewhere.venue_id])

      assert [_seen] = peer_view.correction_requests
    end

    test "leaves an entry the shared venue's own rule would not hide" do
      # **The control for the whole block**, and the same shape "shows a
      # non-concurrent past engagement at another venue by default" has on the
      # employer side. The rule subtracts what the colleague's venue would
      # subtract and nothing else: a job the worker held before this one is not
      # concurrent with it, so the venue can see it and so can its people.
      #
      # A peer read that returned only the shared venue would satisfy every
      # negative assertion above.
      here = venue()
      there = venue()

      colleague = person()
      worker = person()

      engage(here, colleague, @now, days(30))
      engage(here, worker, @now, days(30))
      engage(there, worker, days(-100), days(-70))

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(colleague, worker.person.id)

      assert Enum.sort(venue_ids(peer_view.attested_entries)) ==
               Enum.sort([here.venue.id, there.venue.id])
    end

    test "applies the rule of every venue the colleague works at, not only the shared one" do
      # A colleague holding posts at two venues is bound by both, and that is a
      # decision rather than a consequence: the alternative — showing an entry
      # any one of their venues would show — would let somebody working at two
      # places see, through the more permissive of the two, exactly what the
      # stricter one is not allowed to know.
      #
      # `here` is where the two are co-rostered. `also` is the colleague's
      # second post, where the worker had a stint years ago that overlapped a
      # third venue's — so `also`'s own rule hides the third venue's entry while
      # `here`'s rule has no opinion about it.
      here = venue()
      also = venue()
      third = venue()

      colleague = person()
      worker = person()

      engage(here, colleague, @now, days(30))
      engage(also, colleague, @now, days(30))

      engage(here, worker, @now, days(30))
      engage(also, worker, days(-100), days(-70))
      engage(third, worker, days(-90), days(-80))

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(colleague, worker.person.id)

      assert Enum.sort(venue_ids(peer_view.attested_entries)) ==
               Enum.sort([here.venue.id, also.venue.id])

      refute third.venue.id in venue_ids(peer_view.attested_entries)
    end

    test "hides only what the shared venue's own rule hides, not the venue's own assertion" do
      # The own-venue branch, from the peer's side. An entry attested by the
      # venue the colleague works at is always visible to them — hiding it would
      # take away exactly what the venue room's roll already told them, which is
      # the whole justification for the peer default being open.
      %{manager: manager, worker: worker, here: here} = manager_and_worker()

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(manager, worker.person.id)
      assert venue_ids(peer_view.attested_entries) == [here.venue.id]
    end

    test "treats an empty entry term as overlapping nothing, from the peer's side too" do
      # The two non-emptiness clauses, which the peer predicate carries because
      # it is the view's predicate and would be wrong without them: the endpoint
      # form reports an overlap for `ends_at == starts_at`, so an engagement
      # ended before it started would conceal itself. Measured — with the pair
      # removed the whole employer block still passes and so did this one, which
      # is why both sides get a test of their own.
      here = venue()
      there = venue()

      colleague = person()
      worker = person()

      engage(here, colleague, @now, days(30))
      engage(here, worker, @now, days(30))

      emptied = engage(there, worker, days(20), days(50))
      {:ok, closed} = Engagements.end_engagement(there.employer, emptied.id)
      assert DateTime.compare(closed.ends_at, closed.starts_at) == :eq

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(colleague, worker.person.id)
      assert there.venue.id in venue_ids(peer_view.attested_entries)
    end

    test "treats an empty stint at the colleague's venue as overlapping nothing" do
      # The other side of the same clause, and it needs its own test for the
      # reason U8 found on `co_engagements/1`: a matrix that only ever binds the
      # empty term to one of the two sides leaves a mutation of the other
      # passing.
      here = venue()
      there = venue()

      colleague = person()
      worker = person()

      engage(here, colleague, @now, days(30))

      emptied = engage(here, worker, days(20), days(50))
      {:ok, closed} = Engagements.end_engagement(here.employer, emptied.id)
      assert DateTime.compare(closed.ends_at, closed.starts_at) == :eq

      engage(there, worker, days(15), days(30))
      engage(here, worker, days(-5), days(10))

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(colleague, worker.person.id)
      assert there.venue.id in venue_ids(peer_view.attested_entries)
    end

    test "stops applying once the colleague's own engagement has ended, which is on the record" do
      # **A residual, asserted rather than described.** The rule keys on the
      # peer holding an engagement at the venue that is *active at the asking
      # instant*, which is the shape the employer view has. Visibility outlives
      # an engagement by thirty days (R13), so for that window an ex-colleague
      # is a peer holding no post — and sees the worker's record with no venue's
      # rule applied to it.
      #
      # Bounded and deliberate: it needs the peer's own term to have closed, it
      # closes with the tail, and the alternative — "ever held an engagement
      # there" — would apply a venue's rule for ever to somebody who left it
      # years ago.
      %{manager: manager, worker: worker, here: here, elsewhere: elsewhere} =
        manager_and_worker()

      later = PeersFixtures.person_at(manager, days(40))

      assert Peers.visible?(later, worker.person.id)

      assert {:ok, peer_view} = Profiles.fetch_peer_profile(later, worker.person.id)

      assert Enum.sort(venue_ids(peer_view.attested_entries)) ==
               Enum.sort([here.venue.id, elsewhere.venue.id])
    end
  end

  describe "correction requests" do
    test "are readable by the venue that made the assertion" do
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      assert {:ok, request} =
               Profiles.request_correction(worker, engagement.id, %{body: "Wrong role."})

      assert {:ok, [read]} = Profiles.list_venue_corrections(place.employer)
      assert read.correction_request_id == request.id
      assert read.body == "Wrong role."
      assert is_nil(read.resolved_at)
      assert is_nil(read.resolution)
    end

    test "are visible alongside the entry to another venue that can see it" do
      # **Issue scenario 8.** R16 makes a request visible to any viewer of the
      # entry, and the second view is that claim as a join onto the first rather
      # than as a second rule.
      %{worker: worker, here: here, viewer: viewer, other: other} = concurrent_at_two_venues()

      {:ok, request} = Profiles.request_correction(worker, other.id, %{body: "Wrong dates."})
      {:ok, _on} = Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, true)

      assert {:ok, [seen]} =
               Profiles.list_visible_corrections(employer_at(here, @now), viewer.id)

      assert seen.correction_request_id == request.id
      assert seen.body == "Wrong dates."
    end

    test "are absent for a venue that cannot see the entry" do
      # The control for the test above: the second view inherits the first
      # view's rule, so a hidden entry takes its correction request with it.
      %{worker: worker, here: here, viewer: viewer, other: other} = concurrent_at_two_venues()

      {:ok, _request} = Profiles.request_correction(worker, other.id, %{body: "Wrong dates."})

      assert {:ok, []} = Profiles.list_visible_corrections(employer_at(here, @now), viewer.id)
    end

    test "leave the entry and the request visible when declined" do
      # **Issue scenario 9.** A refusal that erased the request would let an
      # employer make a contest disappear.
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      {:ok, request} = Profiles.request_correction(worker, engagement.id, %{body: "Wrong role."})

      assert {:ok, declined} =
               Profiles.resolve_correction(place.employer, request.id, :declined)

      assert declined.resolution == "declined"
      assert declined.resolved_by_grant_id == place.grant.id

      assert [_entry] = visible(place, engagement)

      # **One shape, four readers, and it is asserted as one.** These two lines
      # used to assert `"declined"` and `:declined` two lines apart — the suite
      # had locked in a divergence the render struct exists to prevent, because
      # `venue_corrections/1` selected no field list and returned the schema.
      assert {:ok, [%{resolution: :declined}]} = Profiles.list_venue_corrections(place.employer)
      assert [%{resolution: :declined}] = Profiles.list_correction_requests(worker)
    end

    test "leave the attested entry unchanged when accepted" do
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      before = Repo.get_by!(AttestedEntry, engagement_id: engagement.id)
      {:ok, request} = Profiles.request_correction(worker, engagement.id, %{body: "Wrong role."})

      assert {:ok, accepted} = Profiles.resolve_correction(place.employer, request.id, :accepted)
      assert accepted.resolution == "accepted"
      assert Repo.get_by!(AttestedEntry, engagement_id: engagement.id) == before
    end

    test "refuse a second resolution" do
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      {:ok, request} = Profiles.request_correction(worker, engagement.id, %{body: "Wrong role."})
      {:ok, _first} = Profiles.resolve_correction(place.employer, request.id, :declined)

      assert Profiles.resolve_correction(place.employer, request.id, :accepted) ==
               {:error, :already_resolved}
    end

    test "refuse another venue's request and an id that names nothing, identically" do
      place = venue()
      elsewhere = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      {:ok, request} = Profiles.request_correction(worker, engagement.id, %{body: "Wrong role."})

      assert Profiles.resolve_correction(elsewhere.employer, request.id, :declined) ==
               {:error, :not_found}

      assert Profiles.resolve_correction(place.employer, Ecto.UUID.generate(), :declined) ==
               {:error, :not_found}
    end

    test "refuse a resolution stamped before the request was raised" do
      # **A `Postgrex.Error` escaping a function whose spec enumerates three
      # atoms.** `correction_requests_resolved_after_requested` refuses a
      # resolution earlier than its request, and resolving is an `update_all`,
      # so no changeset can carry the constraint back as a changeset error. The
      # predicate carries it instead, and the refusal is `:not_found`: at the
      # instant being asked about the request has not been raised.
      #
      # Reachable through `HospitalityComs.Clock.Offset`, which U11's demo
      # controls drive, and reachable here by dating the worker's scope forward
      # rather than the employer's back — an employer scope cannot be placed
      # before its venue's grant was issued.
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      later = PeersFixtures.person_at(worker, days(5))
      {:ok, request} = Profiles.request_correction(later, engagement.id, %{body: "Wrong role."})

      assert Profiles.resolve_correction(place.employer, request.id, :declined) ==
               {:error, :not_found}

      # The control: the same call once the instant has caught up.
      assert {:ok, declined} =
               Profiles.resolve_correction(employer_at(place, days(10)), request.id, :declined)

      assert declined.resolution == "declined"
    end

    test "refuse an engagement that is not the caller's" do
      place = venue()
      worker = person()
      stranger = person()
      engagement = engage(place, worker, @now, days(30))

      assert Profiles.request_correction(stranger, engagement.id, %{body: "Not mine."}) ==
               {:error, :not_found}

      assert Profiles.request_correction(worker, Ecto.UUID.generate(), %{body: "Nowhere."}) ==
               {:error, :not_found}
    end

    test "refuse a blank body and one over the bound" do
      place = venue()
      worker = person()
      engagement = engage(place, worker, @now, days(30))

      assert {:error, blank} = Profiles.request_correction(worker, engagement.id, %{body: "   "})
      assert %{body: ["can't be blank"]} = errors_on(blank)

      long = String.duplicate("x", CorrectionRequest.max_body_length() + 1)

      assert {:error, oversize} =
               Profiles.request_correction(worker, engagement.id, %{body: long})

      assert %{body: [_message]} = errors_on(oversize)
    end
  end

  describe "declared entries" do
    test "are written, listed and amended by their author" do
      worker = person()

      assert {:ok, entry} =
               Profiles.declare_entry(worker, %{
                 role_label: "Barback",
                 organisation_name: "The Anchor",
                 starts_at: days(-400),
                 ends_at: days(-300)
               })

      assert [^entry] = Profiles.list_declared_entries(worker)

      assert {:ok, amended} =
               Profiles.amend_declared_entry(worker, entry.id, %{role_label: "Bartender"})

      assert amended.role_label == "Bartender"
      assert DateTime.compare(amended.declared_at, entry.declared_at) == :eq
    end

    test "refuse a blank label, a reversed term, and a label over the bound" do
      worker = person()

      assert {:error, blank} =
               Profiles.declare_entry(worker, declared(%{role_label: "  "}))

      assert %{role_label: ["can't be blank"]} = errors_on(blank)

      assert {:error, reversed} =
               Profiles.declare_entry(
                 worker,
                 declared(%{starts_at: days(-100), ends_at: days(-200)})
               )

      assert %{ends_at: ["must be after the start"]} = errors_on(reversed)

      long = String.duplicate("x", DeclaredEntry.max_label_length() + 1)
      assert {:error, oversize} = Profiles.declare_entry(worker, declared(%{role_label: long}))
      assert %{role_label: [_message]} = errors_on(oversize)
    end

    test "refuse an amendment by anybody else" do
      worker = person()
      stranger = person()
      {:ok, entry} = Profiles.declare_entry(worker, declared())

      assert Profiles.amend_declared_entry(stranger, entry.id, %{role_label: "Manager"}) ==
               {:error, :not_found}

      assert Profiles.amend_declared_entry(worker, Ecto.UUID.generate(), %{role_label: "M"}) ==
               {:error, :not_found}
    end

    test "never reach the employer-visible view" do
      # The plan's zone diagram routes only `attested_entries` through the view,
      # and the line is deliberate: the view carries what employers asserted,
      # under a rule whose purpose is to stop one employer inferring another.
      place = venue()
      worker = person()
      viewer = engage(place, worker, @now, days(30))
      {:ok, _declared} = Profiles.declare_entry(worker, declared())

      assert [entry] = visible(place, viewer)
      assert entry.venue_id == place.venue.id
      assert length(Profiles.list_declared_entries(worker)) == 1
    end

    test "reach a peer whole, because writing one is publishing it" do
      %{first: first, second: second} = PeersFixtures.co_rostered(@now)
      {:ok, declared} = Profiles.declare_entry(second, declared())

      assert {:ok, profile} = Profiles.fetch_peer_profile(first, second.person.id)
      assert [seen] = profile.declared_entries
      assert seen.id == declared.id
    end
  end

  describe "the worker's own record names only them" do
    # **Three person filters that nothing exercised.** Measured: dropping
    # `where: engagement.person_id == ^person_id` from `disclosures_of/1`, the
    # same clause from `correction_requests_of/1`, or
    # `where: entry.person_id == ^person_id` from `declared_entries_of/1` each
    # left the whole suite green. `attested_entries_of/1`'s equivalent fails
    # five, and the difference is specific: only the peer scenarios put two
    # people's rows in the database at once, and none of them reads these three
    # lists.
    #
    # Unfiltered, `list_disclosures/1` hands every person's concealment ledger
    # to any `PersonScope` — which is the one thing its own docstring says must
    # not exist — and `list_declared_entries/1` publishes everybody's declared
    # entries to every peer, because `declared_entries_of/1` is also the peer
    # read.

    test "the disclosure ledger is one person's alone" do
      %{worker: worker, here: here, other: other} = concurrent_at_two_venues()

      %{worker: stranger, here: their_here, other: their_other} = concurrent_at_two_venues()

      assert {:ok, mine} =
               Profiles.set_disclosure(worker, other.id, {:venue, here.venue.id}, true)

      assert {:ok, _theirs} =
               Profiles.set_disclosure(
                 stranger,
                 their_other.id,
                 {:venue, their_here.venue.id},
                 true
               )

      assert [^mine] = Profiles.list_disclosures(worker)
    end

    test "the correction requests are one person's alone" do
      place = venue()
      worker = person()
      stranger = person()

      mine = engage(place, worker, @now, days(30))
      theirs = engage(place, stranger, @now, days(30))

      {:ok, request} = Profiles.request_correction(worker, mine.id, %{body: "Mine."})
      {:ok, _other} = Profiles.request_correction(stranger, theirs.id, %{body: "Theirs."})

      assert [seen] = Profiles.list_correction_requests(worker)
      assert seen.correction_request_id == request.id
      assert seen.body == "Mine."
    end

    test "the declared entries are one person's alone" do
      worker = person()
      stranger = person()

      {:ok, mine} = Profiles.declare_entry(worker, declared())
      {:ok, _theirs} = Profiles.declare_entry(stranger, declared(%{role_label: "Chef"}))

      assert [^mine] = Profiles.list_declared_entries(worker)
    end
  end

  describe "the standing incompleteness notice" do
    test "takes no arguments, so it cannot depend on the worker it is shown beside" do
      # **The oracle, structurally.** A notice that could be computed per worker
      # would tell every viewer which workers are concealing something, which is
      # strictly more than the concealed entries would have disclosed.
      notices =
        Enum.filter(Profiles.__info__(:functions), fn {name, _arity} ->
          name == :incompleteness_notice
        end)

      assert notices == [incompleteness_notice: 0]
      assert is_binary(Profiles.incompleteness_notice())
    end

    test "leaves a concealing worker indistinguishable from one with nothing to conceal" do
      # **The oracle, behaviourally.** One worker is hiding an engagement at
      # another venue; the other has never worked anywhere else. The employer's
      # read is identical in length and in shape, and nothing in it counts what
      # is missing.
      here = venue()
      there = venue()

      concealing = person()
      engage(there, concealing, @now, days(30))
      concealing_viewer = engage(here, concealing, @now, days(30))

      plain = person()
      plain_viewer = engage(here, plain, @now, days(30))

      concealed = visible(here, concealing_viewer)
      ordinary = visible(here, plain_viewer)

      assert venue_ids(concealed) == [here.venue.id]
      assert venue_ids(ordinary) == [here.venue.id]

      # **The field list, against a literal written here rather than against the
      # other read.** This assertion used to be
      # `Map.keys(hd(concealed)) == Map.keys(hd(ordinary))`, which cannot fail:
      # both sides are `%VisibleEntry{}` and `defstruct` fixes the key set at
      # compile time, so it was invariant under every possible difference in
      # what the two reads contained. Measured — a `hidden_count` added to the
      # view, selected in `Records` and carried on `VisibleEntry` reported 1
      # against 0, which is exactly the oracle criterion 7 forbids, and that
      # spelling passed.
      assert Enum.sort(fields(hd(concealed))) == Enum.sort(@visible_entry_fields)
      assert Enum.sort(fields(hd(ordinary))) == Enum.sort(@visible_entry_fields)

      # And the values, everywhere they are not the two workers' own ids. A
      # field that counted what was missing would differ here whatever it was
      # called, so this catches an oracle the list above was never told to
      # expect.
      assert shape(hd(concealed)) == shape(hd(ordinary))
    end
  end

  describe "the unit's verification" do
    test "a manager's employer session and their own person session differ for one worker" do
      # The issue's stated verification, in the shape the product actually has:
      # the manager is a worker at the same venue, so they hold an employer
      # session *and* a person session, and the two answer differently about the
      # same colleague.
      #
      # **What differs is the worker's own decision, and that is the whole
      # correction this batch makes to the claim.** The two sessions no longer
      # differ by *default*: a manager reading as a peer is a person who works
      # at this venue, so venue A's concurrency rule follows them through the
      # peer door too. Before that, the two differed for free and the difference
      # *was* the leak — the peer read handed back exactly what the employer
      # read withheld.
      #
      # So the verification is the same claim, made about a difference the
      # product means: two ledgers, two audiences, and one worker moving one of
      # them. The worker's own record is the third answer and is bound by
      # neither.
      here = venue()
      there = venue()

      manager = person()
      worker = person()

      manager_engagement =
        engage(here, manager, @now, days(30), grant_id: here.grant.id, role_label: "Manager")

      worker_engagement = engage(here, worker, @now, days(30))
      elsewhere = engage(there, worker, @now, days(30))

      assert {:ok, holding} =
               Engagements.fetch_grant_holding_engagement(manager, here.venue.id)

      assert holding.id == manager_engagement.id

      employer_session = EmployerScope.for_grant(here.venue.id, holding.grant_id, @now)

      assert {:ok, before_employer} =
               Profiles.list_visible_entries(employer_session, worker_engagement.id)

      assert {:ok, before_person} = Profiles.fetch_peer_profile(manager, worker.person.id)

      # Equal by default, which is the manager-as-peer fix stated as an equality.
      assert venue_ids(before_employer) == [here.venue.id]
      assert venue_ids(before_person.attested_entries) == [here.venue.id]

      assert {:ok, _on} =
               Profiles.set_disclosure(worker, elsewhere.id, {:person, manager.person.id}, true)

      assert {:ok, employer_view} =
               Profiles.list_visible_entries(employer_session, worker_engagement.id)

      assert {:ok, person_view} = Profiles.fetch_peer_profile(manager, worker.person.id)

      assert venue_ids(employer_view) == [here.venue.id]

      assert Enum.sort(venue_ids(person_view.attested_entries)) ==
               Enum.sort([here.venue.id, there.venue.id])

      refute venue_ids(employer_view) == venue_ids(person_view.attested_entries)

      # And the worker's own record, which is bound by neither ledger: they can
      # always see what they are choosing about.
      own = Profiles.own_profile(worker)

      assert Enum.sort(venue_ids(own.attested_entries)) ==
               Enum.sort([here.venue.id, there.venue.id])

      assert own.declared_entries == []
      assert own.correction_requests == []
    end
  end

  describe "the rule that Records owns every query" do
    # Structural, out of the compiled `imports` chunk, the way `peers_test.exs`
    # reads it and `person_zone_test.exs` reads repo calls. A whole-namespace
    # sweep, so a new `HospitalityComs.Profiles.*` module is covered on the day
    # it is written rather than on the day somebody adds it to a list.

    test "is a fact about the compiled modules, not a convention" do
      # **Every builder, not an enumerated subset.** This filtered against a
      # `@read_builders` list that named eight of them and omitted `Filter`,
      # `Select`, `Update`, `Dynamic`, `CTE` and `Combination` — so a
      # `HospitalityComs.Profiles.*` sibling composing `where/3` onto a query
      # `Records` handed it escaped the sweep entirely, which is the exact drift
      # U8 found in `Peers` and wrote the check to catch. `Peers` needs the
      # subset because its context composes the `where`, `RETURNING` and `SET`
      # of a write; nothing here composes any of them, so nothing here needs an
      # exemption and the rule is the whole namespace against the whole set.
      offenders =
        Enum.filter(profile_modules(), fn module ->
          module != Records and query_builders(module) != []
        end)

      assert offenders == []
    end

    test "leaves the context building no query at all, which is stricter than Peers" do
      # `HospitalityComs.Peers` keeps `Filter`, `Select` and `Update` because it
      # composes the `where`, `RETURNING` and `SET` of a write onto a query
      # `Records` handed it. Here every write is a whole query `Records` hands
      # over — including the conditional update that resolves a correction — so
      # the context reaches none of them, and this says so rather than leaving
      # the stricter property to be eroded quietly.
      assert query_builders(Profiles) == []
    end

    test "reads a chunk that actually says something, which is the control" do
      modules = profile_modules()

      assert Profiles in modules
      assert Records in modules
      assert VisibleEntry in modules
      refute HospitalityComs.PeersFixtures in modules

      assert Ecto.Query.Builder in query_builders(Records)
      assert Ecto.Query.Builder.From in query_builders(Records)
    end
  end

  ## Helpers

  defp days(count), do: DateTime.add(@now, count, :day)

  defp person, do: EngagementsFixtures.person_scope_fixture(@now)

  defp venue do
    {employer, creation} = EngagementsFixtures.scoped_venue_fixture(@now)
    %{employer: employer, venue: creation.venue, grant: creation.grant}
  end

  defp employer_at(%{venue: venue, grant: grant}, instant) do
    EmployerScope.for_grant(venue.id, grant.id, instant)
  end

  # The claim code's own expiry hangs off the *issuing* instant rather than off
  # the term, so a term in the past does not make the invitation unissuable.
  defp engage(place, worker, from, to, attrs \\ []) do
    EngagementsFixtures.engagement_fixture(
      place.employer,
      worker,
      Enum.into(attrs, %{
        role_label: "Bartender",
        starts_at: from,
        ends_at: to,
        code_expires_at: DateTime.add(place.employer.now, 7, :day)
      })
    )
  end

  # One worker, two venues, terms that overlap — the setup most of this file
  # asks about. `other` is the engagement elsewhere, `viewer` is the one the
  # employer at `here` reads through.
  defp concurrent_at_two_venues do
    elsewhere = venue()
    here = venue()
    worker = person()

    other = engage(elsewhere, worker, @now, days(30))
    viewer = engage(here, worker, @now, days(30))

    %{worker: worker, elsewhere: elsewhere, here: here, other: other, viewer: viewer}
  end

  # One human holding both an `EmployerScope` and a `PersonScope` at one venue,
  # and a worker there who also works somewhere else. The shape the product
  # actually has — a manager is a worker too — and the shape no other test in
  # this file builds.
  defp manager_and_worker do
    here = venue()
    elsewhere = venue()

    manager = person()
    worker = person()

    manager_engagement =
      engage(here, manager, @now, days(30), grant_id: here.grant.id, role_label: "Manager")

    worker_engagement = engage(here, worker, @now, days(30))
    elsewhere_engagement = engage(elsewhere, worker, @now, days(30))

    %{
      here: here,
      elsewhere: elsewhere,
      manager: manager,
      worker: worker,
      manager_engagement: manager_engagement,
      worker_engagement: worker_engagement,
      elsewhere_engagement: elsewhere_engagement
    }
  end

  defp visible(place, viewer, instant \\ @now) do
    {:ok, entries} = Profiles.list_visible_entries(employer_at(place, instant), viewer.id)
    entries
  end

  defp venue_ids(entries), do: Enum.map(entries, & &1.venue_id)

  defp fields(entry), do: entry |> Map.from_struct() |> Map.keys()

  defp shape(entry), do: entry |> Map.from_struct() |> Map.drop(@entry_identity)

  defp declared(attrs \\ %{}) do
    Enum.into(attrs, %{
      role_label: "Barback",
      organisation_name: "The Anchor",
      starts_at: days(-400),
      ends_at: days(-300)
    })
  end

  defp profile_modules do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)

    Enum.filter(modules, fn module ->
      name = Atom.to_string(module)

      name == "Elixir.HospitalityComs.Profiles" or
        String.starts_with?(name, @profiles_namespace)
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

  # A scope the type checker cannot see the shape of, which is the shape a real
  # caller's scope has. Written inline, Elixir proves at compile time that the
  # function has no clause matching it and warns at the call site — a good
  # warning and a bad test, because a scope built at run time from a session
  # carries no such proof.
  defp dynamic(scope), do: Map.fetch!(%{scope: scope}, :scope)

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
