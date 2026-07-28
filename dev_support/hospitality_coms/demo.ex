defmodule HospitalityComs.Demo do
  @moduledoc """
  The seed manifest, and the controls that traverse the durations between its
  states.

  The plan's Problem Frame says this application's value is structural rather
  than visible: a two-zone boundary enforced by Postgres privileges, and a
  membership model derived from time rather than stored. Neither shows itself
  in a screenshot. What shows them is *churn* — an engagement reaching its upper
  bound, a grace window closing, a peer connection outliving the employment that
  created it — and churn takes months of wall-clock time that a demo does not
  have. This module manufactures it.

  ## Why this file is not in `lib/`

  Issue #11 names `lib/hospitality_coms/demo.ex`. **`lib/` compiles in `:prod`,
  and `HospitalityComs.Clock.Offset` does not.** `mix.exs` excludes
  `dev_support/` from the production compile path, and that exclusion is the
  whole of KTD5b: "a demo control that can advance thirty days is also a control
  that can trigger irreversible retention deletion; making the override
  structurally absent from the production build is cheaper and stronger than
  guarding it."

  U10 shipped the deletion, so the argument is no longer hypothetical. A module
  in `lib/` naming `Clock.Offset` fails `MIX_ENV=prod mix compile`; a module in
  `lib/` reaching the override through `apply/3` compiles, ships, and puts
  `end_all_engagements/1` one configuration line away from a production
  database. So this file compiles where the override does, inherits its absence,
  and the router mounts its controller behind
  `Application.compile_env(:hospitality_coms, :demo_routes)` — the same
  mechanism that already gates the Swoosh mailbox.

  `HospitalityComs.DemoTest` asserts that absence as a property of the build:
  `elixirc_paths(:prod)`, the source path of every module in this directory, and
  the fact that no module compiled from `lib/` references one compiled from
  here. `.github/workflows/ci.yml` runs the real prod compile alongside it.

  ## `run_due_work/0` drives the workers, and never the queue

  **Oban's staging query asks `scheduled_at <= DateTime.utc_now()` inside its
  own engine, and `HospitalityComs.Clock` does not reach it.** Advancing the
  offset thirty days changes every membership query in this application
  instantly, while an expiry announcement scheduled for that upper bound still
  waits thirty *real* days. Skipping that wait is the entire purpose of the
  injectable clock, so a demo that advanced the clock and waited for the queue
  would demonstrate nothing — and three of the plan's success criteria would
  have no reachable demonstration at all.

  So this control calls `HospitalityComs.Workers.ExpireEngagement.perform/1` and
  `HospitalityComs.Workers.RetentionSweeper.perform/1` directly. It does *not*
  call `HospitalityComs.Workers.EngagementSweeper.perform/1`, whose entire
  contribution is `Oban.insert/2`: inserting a job this control would then have
  to execute itself is a round trip through a table for nothing. What it reuses
  instead is that sweeper's batch bound, through the function the sweeper
  already exports, so the two cannot drift.

  **One number differs from production and it is deliberate.**
  `EngagementSweeper` looks back one day, on a recorded assumption that "a term
  that closed more than a day ago is never swept again, which costs nothing
  because correctness never depended on the announcement". Under a clock that
  jumps thirty-one days in one control action *every* closed term falls outside
  a one-day window — and since U10 the announcement is also what stamps
  `retained_message_copies.delete_after`. So this control uses an unbounded
  lower edge and keeps the batch bound. That is a property of a clock that
  jumps, not a disagreement with the sweeper.

  ## The control holds no authority, and borrows one venue's at a time

  "Demo controls run under their own scope, not an employer scope, because
  ending engagements across employers is something no employer session may do."

  `end_all_engagements/1` takes a person id and nothing else. It enumerates that
  person's engagements through `HospitalityComs.Repo` — the application acting
  for itself, the shape `HospitalityComs.Lifecycle` and the three workers
  already have — which is precisely what `HospitalityComs.EmployerRepo` refuses,
  because a scoped transaction is one venue's and the row-level policy on
  `engagements` is `venue_id = app_current_employer_id()`.

  Each individual close then runs as *that venue*, through
  `HospitalityComs.Engagements.end_engagement/2`, under a scope built from a
  grant that venue holds. That is reuse rather than a loophole, and it is what
  makes R22 true here without restating it: `end_engagement/2` already refuses a
  venue's last active grant-holding engagement under `FOR UPDATE`, reusing
  `EmployerGrant.live_at/2` so that "live" cannot come to mean two things. A
  demo control with its own copy of KTD17 would be a second definition of the
  invariant KTD17 exists to hold.

  The refusal is all-or-nothing. Each close is its own transaction, so there is
  no set to roll back; the control therefore asks
  `Engagements.would_orphan_venue?/2` about every engagement before it closes
  any. A control that ended four of five and reported a failure would leave the
  demonstration in a state no single action explains.

  ## The seeds build scopes at historical instants; they do not move the clock

  Every context in this tree stamps from the scope it was handed —
  `Rosters.add_to_roster/3` writes `joined_at` from `scope.now`,
  `Rooms.send_venue_room_message/3` writes `sent_at` from `scope.now`,
  `Engagements.claim_invitation/2` writes `claimed_at` from `scope.now`. None of
  them reads the clock, because KTD5 says only a unit-of-work boundary may. So a
  manifest with a *past* roster is written by handing each call a scope at the
  instant that step happened, and the global clock is never touched.

  Getting that wrong is not a compile error and does not look like a failure: a
  roster written at seed time simply produces a period that does not overlap the
  shift it belongs to, and the past shift comes back with nobody in it.
  `HospitalityComs.DemoTest` pins the past roster's readability for that reason.

  Every instant in the manifest is **relative to the clock at seed time**, never
  absolute. Seeding a development database at 15:40 produces a shift that is
  live at 15:40; an absolute epoch would make the live shift live on one day of
  one year.

  ## Idempotence is all-or-nothing, and a half-seeded database says so

  The manifest resolves by natural key: four people by email, two venues by
  name. All six present is `:present` and writes nothing; none present is
  `:created`; anything in between is `{:error, :partial_manifest}`.

  The third state is the honest one. A find-or-create per step silently
  completes a run that died halfway, and the row it did not write is the one
  nobody notices is missing. A marker on the first entity skips everything after
  a crash in the middle. Enumerating the anchors and refusing on a partial
  answer is the only shape in which a half-seeded database is a message rather
  than a mystery, and the remedy is one command: `mix ecto.reset`.

  ## Names carry a marker, and the fixtures read it from here

  Venues end in `" (demo)"` and addresses sit at `@demo.invalid`, a reserved TLD
  that can never resolve. Both read acceptably in a client and both are `LIKE`
  patterns, which is what `HospitalityComs.EngagementsFixtures.purge/0` needs:
  `HospitalityComs.DemoTest` is not sandboxed and commits for real, so a run
  that dies mid-test leaves the manifest behind, and without the patterns
  `HospitalityComs.TestDatabaseGuard` would report it in its *loud* category —
  "written by nothing in this tree" — which is a false alarm about the one thing
  that guard exists to make legible. The patterns are exported from here so
  there is one spelling of each.
  """

  import Ecto.Query

  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle.RetentionRun
  alias HospitalityComs.Peers
  alias HospitalityComs.Peers.Connection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Profiles
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rosters
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue
  alias HospitalityComs.Workers.EngagementSweeper
  alias HospitalityComs.Workers.ExpireEngagement
  alias HospitalityComs.Workers.RetentionSweeper

  @venue_suffix " (demo)"
  @person_domain "@demo.invalid"

  # The manifest's anchors, by natural key. `resolve/1` asks for all six and
  # decides between the three states on how many it found.
  @venue_names %{harbour: "Harbour Tavern", kolektiv: "Kolektiv Coffee"}
  @person_names %{mira: "mira", ana: "ana", tomo: "tomo", luka: "luka"}

  # Venue A's three rooms, in the order their terms open, which is the order
  # `resolve/1` reads them back in. Written here rather than inferred so that a
  # fourth room added later fails loudly instead of relabelling these three.
  @room_labels [:past_shift, :closed_shift, :live_shift]

  @typedoc """
  Where the seeded world is, by label.

  Ids rather than structs: the manifest is rendered as JSON by
  `HospitalityComsWeb.DemoController` and read by tests that fetch what they
  need through the contexts, so carrying loaded rows here would be two
  representations of the same thing and one of them stale.
  """
  @type manifest() :: %{
          status: :created | :present,
          instant: DateTime.t(),
          venues: %{atom() => Ecto.UUID.t()},
          people: %{atom() => Ecto.UUID.t()},
          engagements: %{atom() => Ecto.UUID.t()},
          shift_types: %{atom() => Ecto.UUID.t()},
          shift_rooms: %{atom() => Ecto.UUID.t()},
          connection_id: Ecto.UUID.t(),
          pending_request_id: Ecto.UUID.t()
        }

  @typedoc """
  What the clock control reports: where the clock is, and whether it is pinned.
  """
  @type clock_state() :: %{
          instant: DateTime.t(),
          implementation: module(),
          fixed: DateTime.t() | nil,
          shift: Duration.t()
        }

  @typedoc """
  What one `run_due_work/0` did.

  `swept` and `announced` are counted apart for the reason
  `HospitalityComs.Workers.EngagementSweeper` counts `suppressed` and `failed`
  apart: collapsed into one they read identically and mean opposite things. The
  difference between them is the terms that turned out to be active after all,
  which is a renewal having happened rather than anything going wrong.
  """
  @type due_work() :: %{
          instant: DateTime.t(),
          swept: non_neg_integer(),
          announced: non_neg_integer(),
          retention: RetentionRun.t()
        }

  @typedoc """
  Why `end_all_engagements/1` closed nothing, or stopped.

  `:not_found` is an id naming nobody. `:last_grant_holder` is R22 and is
  decided before anything is closed. `:no_grant` is a venue with no live
  authority at all — an orphan, in `HospitalityComs.Lifecycle`'s sense — which
  no scope can act for. `:stale` and a changeset are `end_engagement/2`'s own,
  reachable only if something committed between the pre-flight and the close.
  """
  @type closure_failure() ::
          :not_found
          | :last_grant_holder
          | :no_grant
          | :stale
          | Ecto.Changeset.t(Engagement.t())

  ## Names, and the patterns that find them again

  @doc """
  The `LIKE` pattern matching every venue name this module writes.
  """
  @spec venue_pattern() :: String.t()
  def venue_pattern, do: "%#{@venue_suffix}"

  @doc """
  The `LIKE` pattern matching every address this module registers.
  """
  @spec person_pattern() :: String.t()
  def person_pattern, do: "%#{@person_domain}"

  @doc """
  The address the person known by `label` in the manifest is registered under.
  """
  @spec person_email(atom()) :: String.t()
  def person_email(label) when is_map_key(@person_names, label) do
    "#{Map.fetch!(@person_names, label)}#{@person_domain}"
  end

  @doc """
  The name the venue known by `label` in the manifest carries.
  """
  @spec venue_name(atom()) :: String.t()
  def venue_name(label) when is_map_key(@venue_names, label) do
    "#{Map.fetch!(@venue_names, label)}#{@venue_suffix}"
  end

  ## Seeding

  @doc """
  Writes the manifest, or reports that it is already there.

  `:created` wrote it, `:present` found all six anchors and wrote nothing, and
  `{:error, :partial_manifest}` found some — a database somebody interrupted,
  which `mix ecto.reset` fixes and this function deliberately will not.

  Reads the clock once. Every instant in the manifest is derived from it, and
  every context call is handed a scope carrying the instant that step happened
  at, so no historical row is stamped with the seed's own instant.
  """
  @spec seed() :: {:ok, manifest()} | {:error, :partial_manifest}
  def seed, do: seeded(anchors(), Clock.now())

  @spec seeded({non_neg_integer(), non_neg_integer()}, DateTime.t()) ::
          {:ok, manifest()} | {:error, :partial_manifest}
  defp seeded({0, _total}, instant) do
    :ok = write(instant)
    resolved(:created, instant)
  end

  defp seeded({total, total}, instant), do: resolved(:present, instant)
  defp seeded({_found, _total}, _instant), do: {:error, :partial_manifest}

  @spec anchors() :: {non_neg_integer(), non_neg_integer()}
  defp anchors do
    names = Enum.map(Map.keys(@venue_names), &venue_name/1)
    emails = Enum.map(Map.keys(@person_names), &person_email/1)

    venues = Repo.aggregate(from(venue in Venue, where: venue.name in ^names), :count)
    people = Repo.aggregate(from(person in Person, where: person.email in ^emails), :count)

    {venues + people, length(names) + length(emails)}
  end

  @spec resolved(:created | :present, DateTime.t()) :: {:ok, manifest()}
  defp resolved(status, instant) do
    venues = Map.new(@venue_names, fn {label, _name} -> {label, venue_id!(label)} end)
    people = Map.new(@person_names, fn {label, _name} -> {label, person_id!(label)} end)

    {:ok,
     %{
       status: status,
       instant: instant,
       venues: venues,
       people: people,
       engagements: engagement_ids(people, venues),
       shift_types: shift_type_ids(venues.harbour),
       shift_rooms: shift_room_ids(venues.harbour),
       connection_id: connection_id!(people.tomo),
       pending_request_id: pending_request_id!(people.tomo, instant)
     }}
  end

  @spec venue_id!(atom()) :: Ecto.UUID.t()
  defp venue_id!(label) do
    Repo.one!(from venue in Venue, where: venue.name == ^venue_name(label), select: venue.id)
  end

  @spec person_id!(atom()) :: Ecto.UUID.t()
  defp person_id!(label) do
    Repo.one!(from person in Person, where: person.email == ^person_email(label), select: person.id)
  end

  # One engagement per (person, venue) pair in the manifest, which is what makes
  # the pair a key: nobody here holds two stints at one venue.
  @spec engagement_ids(%{atom() => Ecto.UUID.t()}, %{atom() => Ecto.UUID.t()}) ::
          %{atom() => Ecto.UUID.t()}
  defp engagement_ids(people, venues) do
    Map.new(
      [
        mira_harbour: {people.mira, venues.harbour},
        ana_harbour: {people.ana, venues.harbour},
        ana_kolektiv: {people.ana, venues.kolektiv},
        tomo_harbour: {people.tomo, venues.harbour},
        tomo_kolektiv: {people.tomo, venues.kolektiv},
        luka_kolektiv: {people.luka, venues.kolektiv}
      ],
      fn {label, {person_id, venue_id}} -> {label, engagement_id!(person_id, venue_id)} end
    )
  end

  @spec engagement_id!(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.UUID.t()
  defp engagement_id!(person_id, venue_id) do
    Repo.one!(
      from engagement in Engagement,
        where: engagement.person_id == ^person_id and engagement.venue_id == ^venue_id,
        select: engagement.id
    )
  end

  @spec shift_type_ids(Ecto.UUID.t()) :: %{atom() => Ecto.UUID.t()}
  defp shift_type_ids(venue_id) do
    Map.new([close: "Close", day: "Day"], fn {label, name} ->
      {label,
       Repo.one!(
         from shift_type in ShiftType,
           where: shift_type.venue_id == ^venue_id and shift_type.name == ^name,
           select: shift_type.id
       )}
    end)
  end

  @spec shift_room_ids(Ecto.UUID.t()) :: %{atom() => Ecto.UUID.t()}
  defp shift_room_ids(venue_id) do
    ids =
      Repo.all(
        from room in ShiftRoom,
          where: room.venue_id == ^venue_id,
          order_by: [asc: room.starts_at],
          select: room.id
      )

    labelled(ids, length(@room_labels))
  end

  @spec labelled([Ecto.UUID.t()], non_neg_integer()) :: %{atom() => Ecto.UUID.t()}
  defp labelled(ids, expected) when length(ids) == expected do
    @room_labels |> Enum.zip(ids) |> Map.new()
  end

  defp labelled(ids, expected) do
    raise """
    The demo manifest expects #{expected} shift rooms at the Harbour and found #{length(ids)}.

    Both anchors resolved, so this database holds part of a seed run that did not \
    finish, or rows somebody added beside it. Empty it and seed again:

        mix ecto.reset
    """
  end

  @spec connection_id!(Ecto.UUID.t()) :: Ecto.UUID.t()
  defp connection_id!(person_id) do
    %Connection{id: id} =
      Repo.one!(
        from connection in Connection,
          where: connection.person_a_id == ^person_id or connection.person_b_id == ^person_id
      )

    id
  end

  # Read through the context rather than off the table, because "pending" is
  # derived — `Peers` computes it from the pair's visibility at the instant
  # asked about — and a query here would be a second opinion about it.
  @spec pending_request_id!(Ecto.UUID.t(), DateTime.t()) :: Ecto.UUID.t()
  defp pending_request_id!(person_id, instant) do
    %ConnectionRequest{id: id} =
      person_id
      |> person_scope(instant)
      |> Peers.list_incoming_requests()
      |> List.first()

    id
  end

  ## The manifest, written

  # The whole timeline, in order. Every step is handed a scope at the instant it
  # happened, so the rows carry the history the demo needs rather than the
  # instant the seed ran at. See the moduledoc.
  @spec write(DateTime.t()) :: :ok
  defp write(t0) do
    people = register_people(days(t0, -210))

    harbour = found_venue(people.mira, :harbour, days(t0, -205), days(t0, -201), days(t0, -200))

    # Ana's ordinary engagement opens *before* the venue she manages, and the
    # order is load-bearing rather than flavour. `end_all_engagements/1` walks a
    # person's engagements oldest first, so this is what makes the manifest
    # exercise R22's all-or-nothing: it reaches an engagement it could close
    # before it reaches the authority it must refuse. Founded the other way
    # round, a control with no pre-flight at all would refuse on the first step
    # and look correct.
    hire(harbour, people.ana, "Server", days(t0, -185), days(t0, -180), days(t0, 90))

    kolektiv = found_venue(people.ana, :kolektiv, days(t0, -160), days(t0, -155), days(t0, -150))

    hire(kolektiv, people.luka, "Kitchen Porter", days(t0, -75), days(t0, -70), days(t0, -10))
    hire(harbour, people.tomo, "Bartender", days(t0, -65), days(t0, -60), days(t0, 120))

    connect(people.tomo, people.ana, t0)

    hire(kolektiv, people.tomo, "Barista", days(t0, -45), days(t0, -40), days(t0, 140))

    open_rooms(harbour, people, t0)
    talk(harbour, people, t0)
    curate(people, kolektiv.venue_id, t0)

    :ok
  end

  # In a transaction because `Accounts.register_person/2` inserts with
  # `mode: :savepoint`, which needs one to open a savepoint inside. Every test
  # in the suite gets that from the sandbox; a seed run has no sandbox, so it
  # supplies its own — the same thing `EngagementsFixtures.person_fixture/1`
  # does, for the same reason.
  @spec register_people(DateTime.t()) :: %{atom() => Person.t()}
  defp register_people(instant) do
    {:ok, people} =
      Repo.transaction(fn ->
        Map.new(@person_names, fn {label, _name} ->
          {:ok, person} = Accounts.register_person(%{email: person_email(label)}, instant)
          {label, person}
        end)
      end)

    people
  end

  # A venue, and the engagement that makes it administrable. KTD2 means no
  # employer-zone row records who founded it: the founding grant is conferred by
  # an invitation, and the person becomes the manager by claiming it.
  @spec found_venue(Person.t(), atom(), DateTime.t(), DateTime.t(), DateTime.t()) ::
          EmployerScope.t()
  defp found_venue(founder, label, created_at, issued_at, claimed_at) do
    {:ok, %{venue: venue, grant: grant}} =
      Venues.create_venue(PersonScope.for_person(founder, created_at), %{
        name: venue_name(label),
        timezone: timezone(label)
      })

    scope = EmployerScope.for_grant(venue.id, grant.id, issued_at)

    hire(scope, founder, manager_label(label), issued_at, claimed_at, days(claimed_at, 400), %{
      grant_id: grant.id
    })

    scope
  end

  @spec timezone(atom()) :: String.t()
  defp timezone(:harbour), do: "Europe/Zagreb"
  defp timezone(:kolektiv), do: "Europe/London"

  @spec manager_label(atom()) :: String.t()
  defp manager_label(:harbour), do: "General Manager"
  defp manager_label(:kolektiv), do: "Owner"

  # An invitation issued at one instant and claimed at another, which is what an
  # engagement is: an offer and an acceptance, never a row an employer writes on
  # somebody's behalf (R1).
  @spec hire(
          EmployerScope.t(),
          Person.t(),
          String.t(),
          DateTime.t(),
          DateTime.t(),
          DateTime.t(),
          map()
        ) :: Engagement.t()
  defp hire(scope, person, role_label, issued_at, claimed_at, ends_at, extra \\ %{}) do
    attrs =
      Map.merge(extra, %{
        role_label: role_label,
        starts_at: claimed_at,
        ends_at: ends_at,
        code_expires_at: days(issued_at, 7)
      })

    {:ok, %{claim_code: code}} =
      Engagements.issue_invitation(%{scope | now: issued_at}, attrs)

    {:ok, %{engagement: engagement}} =
      Engagements.claim_invitation(PersonScope.for_person(person, claimed_at), code)

    engagement
  end

  # The accepted connection the payoff depends on: made while both were working
  # at the Harbour, and outliving whatever happens to either engagement.
  @spec connect(Person.t(), Person.t(), DateTime.t()) :: :ok
  defp connect(tomo, ana, t0) do
    {:ok, request} =
      Peers.request_connection(PersonScope.for_person(tomo, days(t0, -50)), ana.id)

    {:ok, connection} =
      Peers.accept_request(PersonScope.for_person(ana, days(t0, -49)), request.id)

    {:ok, _first} =
      Peers.send_message(
        PersonScope.for_person(tomo, days(t0, -48)),
        connection.id,
        "Good shift tonight. Same again Friday?"
      )

    {:ok, _second} =
      Peers.send_message(
        PersonScope.for_person(ana, days(t0, -47)),
        connection.id,
        "Friday works. Bring the good shaker."
      )

    :ok
  end

  # Two shift types with different graces, and three rooms: one long closed and
  # carrying a past roster, one closed within the day, one open now.
  #
  # The three deadlines this stamps are all in the future at `t0`, deliberately.
  # A deadline already past at seed time would have the operator's first
  # `run_due_work/0` delete rows before the clock had moved at all, and the
  # control that proves an advance is necessary would be measuring nothing.
  @spec open_rooms(EmployerScope.t(), %{atom() => Person.t()}, DateTime.t()) :: :ok
  defp open_rooms(harbour, people, t0) do
    {:ok, close} =
      Venues.create_shift_type(%{harbour | now: days(t0, -35)}, harbour.venue_id, %{
        name: "Close",
        grace_period_minutes: 120
      })

    {:ok, day} =
      Venues.create_shift_type(%{harbour | now: days(t0, -35)}, harbour.venue_id, %{
        name: "Day",
        grace_period_minutes: 15
      })

    past_shift(harbour, people, close, t0)
    closed_shift(harbour, people, day, t0)
    live_shift(harbour, people, close, t0)

    :ok
  end

  @spec past_shift(EmployerScope.t(), %{atom() => Person.t()}, ShiftType.t(), DateTime.t()) :: :ok
  defp past_shift(harbour, people, shift_type, t0) do
    starts_at = days(t0, -20)

    {:ok, room} =
      Rooms.create_shift_room(%{harbour | now: days(t0, -25)}, shift_type.id, %{
        starts_at: starts_at,
        ends_at: hours(starts_at, 8)
      })

    tomo = engagement_of(people.tomo, harbour.venue_id)
    ana = engagement_of(people.ana, harbour.venue_id)

    {:ok, _} = Rosters.add_to_roster(%{harbour | now: starts_at}, room.id, tomo)
    {:ok, _} = Rosters.add_to_roster(%{harbour | now: starts_at}, room.id, ana)

    {:ok, _} =
      Rooms.send_shift_room_message(
        PersonScope.for_person(people.tomo, hours(starts_at, 2)),
        room.id,
        "Cellar's low on the pale ale."
      )

    # A closed period, which is what a roster correction is: the row stays and
    # the access already earned stays with it (KTD6b).
    {:ok, _} = Rosters.remove_from_roster(%{harbour | now: hours(starts_at, 5)}, room.id, ana)

    :ok
  end

  @spec closed_shift(EmployerScope.t(), %{atom() => Person.t()}, ShiftType.t(), DateTime.t()) ::
          :ok
  defp closed_shift(harbour, people, shift_type, t0) do
    starts_at = days(t0, -2)

    {:ok, room} =
      Rooms.create_shift_room(%{harbour | now: days(t0, -4)}, shift_type.id, %{
        starts_at: starts_at,
        ends_at: hours(starts_at, 8)
      })

    tomo = engagement_of(people.tomo, harbour.venue_id)
    {:ok, _} = Rosters.add_to_roster(%{harbour | now: starts_at}, room.id, tomo)

    {:ok, _} =
      Rooms.send_shift_room_message(
        PersonScope.for_person(people.tomo, hours(starts_at, 1)),
        room.id,
        "Two covers running late, holding the table."
      )

    :ok
  end

  @spec live_shift(EmployerScope.t(), %{atom() => Person.t()}, ShiftType.t(), DateTime.t()) :: :ok
  defp live_shift(harbour, people, shift_type, t0) do
    starts_at = hours(t0, -1)

    {:ok, room} =
      Rooms.create_shift_room(%{harbour | now: hours(t0, -3)}, shift_type.id, %{
        starts_at: starts_at,
        ends_at: hours(starts_at, 8)
      })

    tomo = engagement_of(people.tomo, harbour.venue_id)
    {:ok, _} = Rosters.add_to_roster(%{harbour | now: starts_at}, room.id, tomo)

    :ok
  end

  # Venue-room history, which is what makes the worker's own retained copy exist
  # at all: `Rooms.send_venue_room_message/3` writes one in the same transaction.
  @spec talk(EmployerScope.t(), %{atom() => Person.t()}, DateTime.t()) :: :ok
  defp talk(harbour, people, t0) do
    [
      {people.mira, days(t0, -30), "Rota for the month is up. Shout if a shift clashes."},
      {people.tomo, days(t0, -29), "Swapping Thursday with Ana, both fine with it."},
      {people.ana, days(t0, -1), "Glass wash is fixed. Third cycle is the hot one."}
    ]
    |> Enum.each(fn {person, instant, body} ->
      {:ok, _message} =
        Rooms.send_venue_room_message(
          PersonScope.for_person(person, instant),
          harbour.venue_id,
          body
        )
    end)
  end

  # The person-controlled half of the profile: a pending approach nobody has
  # answered, an entry the worker wrote themselves, a contested attestation, and
  # one explicit disclosure decision.
  #
  # The *hidden concurrent entry* is not written here and cannot be. It is
  # derived: Tomo's Kolektiv engagement overlaps his Harbour one, so the
  # employer-visible view withholds the Kolektiv entry from the Harbour with
  # nothing stored. The ledger row below is the other kind — an explicit
  # decision about one named peer.
  @spec curate(%{atom() => Person.t()}, Ecto.UUID.t(), DateTime.t()) :: :ok
  defp curate(people, kolektiv_id, t0) do
    {:ok, _request} =
      Peers.request_connection(PersonScope.for_person(people.luka, days(t0, -5)), people.tomo.id)

    {:ok, _declared} =
      Profiles.declare_entry(PersonScope.for_person(people.tomo, days(t0, -3)), %{
        role_label: "Barback",
        organisation_name: "Pivnica Medvedgrad",
        starts_at: days(t0, -900),
        ends_at: days(t0, -600)
      })

    {:ok, _correction} =
      Profiles.request_correction(
        PersonScope.for_person(people.tomo, days(t0, -1)),
        engagement_of(people.tomo, kolektiv_id),
        %{body: "The label should read Head Barista from the second month."}
      )

    {:ok, _disclosure} =
      Profiles.set_disclosure(
        PersonScope.for_person(people.tomo, hours(t0, -12)),
        engagement_of(people.tomo, kolektiv_id),
        {:person, people.ana.id},
        false
      )

    :ok
  end

  @spec engagement_of(Person.t(), Ecto.UUID.t()) :: Ecto.UUID.t()
  defp engagement_of(%Person{id: person_id}, venue_id), do: engagement_id!(person_id, venue_id)

  ## The clock

  @doc """
  Where the clock is, and how it got there.
  """
  @spec clock() :: clock_state()
  def clock do
    state = Clock.Offset.state()

    %{
      instant: Clock.now(),
      implementation: Clock.impl(),
      fixed: state.fixed,
      shift: state.shift
    }
  end

  @doc """
  Pins the clock to `instant`, discarding any accumulated advance.
  """
  @spec set_clock(DateTime.t()) :: {:ok, DateTime.t()}
  def set_clock(%DateTime{} = instant) do
    :ok = Clock.Offset.set(instant)
    {:ok, Clock.now()}
  end

  @doc """
  Moves the clock forward by `duration` and answers with where it landed.

  A negative duration moves it back, which `Duration` permits and a demo needs:
  an operator who has run past the moment they wanted to show has no other way
  back short of re-seeding.
  """
  @spec advance_clock(Duration.t() | [{atom(), integer()}]) :: {:ok, DateTime.t()}
  def advance_clock(duration) do
    :ok = Clock.Offset.advance(duration)
    {:ok, Clock.now()}
  end

  @doc """
  Returns the clock to the system instant.
  """
  @spec reset_clock() :: {:ok, DateTime.t()}
  def reset_clock do
    :ok = Clock.Offset.reset()
    {:ok, Clock.now()}
  end

  ## Work that would otherwise wait for a queue

  @doc """
  Runs every scheduled mechanism as though the queue had caught up.

  Announces the expiry of every term that has closed and has not been announced
  since, which is also what stamps each of those workers' own retained copies,
  and then sweeps retention. Both by calling the workers directly: see the
  moduledoc for why waiting for Oban cannot work under an injected clock.

  Idempotent in the way the workers are. A second run announces the same terms
  again — the announcement is a nudge, not a write — finds no copy to make and
  no deadline to move, and sweeps rows that are already gone.
  """
  @spec run_due_work() :: {:ok, due_work()}
  def run_due_work do
    instant = Clock.now()
    expired = Engagements.list_expired(instant, epoch(), EngagementSweeper.batch_size())

    # Announcements first, and the order is load-bearing: announcing is what
    # stamps `retained_message_copies.delete_after`, and a sweep that ran before
    # the stamp would leave a deadline that has already passed until the next
    # run. One control action has to leave the world consistent.
    announced = Enum.count(expired, &announce/1)
    {:ok, run} = RetentionSweeper.perform(job(RetentionSweeper.new(%{})))

    {:ok,
     %{instant: instant, swept: length(expired), announced: announced, retention: run}}
  end

  # The whole history, rather than `EngagementSweeper.lookback_from/1`'s day.
  # See the moduledoc: a control that jumps the clock a month puts every closed
  # term outside a window built for a queue that runs every five minutes.
  @spec epoch() :: DateTime.t()
  defp epoch, do: ~U[1970-01-01 00:00:00.000000Z]

  # The real worker, with no queue between, on the job the claim would have
  # scheduled. `perform/1` re-derives activeness at its own instant and
  # broadcasts only if the term has closed, so a renewal since the sweep makes
  # it inert exactly as it does in production.
  @spec announce(Engagement.t()) :: boolean()
  defp announce(%Engagement{} = engagement) do
    {:ok, expiry} = engagement |> ExpireEngagement.schedule_for() |> job() |> ExpireEngagement.perform()

    expiry == :revoked
  end

  # The worker's own changeset, applied rather than inserted. Two things follow
  # and both are the point: the args are `ExpireEngagement.schedule_for/1`'s
  # rather than a second spelling of them here, and nothing reaches `oban_jobs`
  # — there is no queue in this path to insert into (see the moduledoc).
  #
  # **The JSON round trip is not decoration.** `oban_jobs.args` is a `jsonb`
  # column, so a job Oban hands a worker carries *string* keys, and
  # `ExpireEngagement.perform/1` matches on `"engagement_id"`. A changeset that
  # was applied rather than inserted never reached the column, so its args are
  # still the atom-keyed map `schedule_for/1` built and the worker refuses it by
  # function clause. Encoding and decoding is what the queue does to them.
  @spec job(Ecto.Changeset.t(Oban.Job.t())) :: Oban.Job.t()
  defp job(changeset) do
    job = Ecto.Changeset.apply_action!(changeset, :insert)

    %{job | args: job.args |> Jason.encode!() |> Jason.decode!()}
  end

  ## Ending every engagement a person holds

  @doc """
  Closes every engagement of `person_id` whose term has not already closed.

  R44, and the action AE7 turns on: afterwards the person is employed nowhere
  and their profile, their attested entries, their retained own messages and
  their peer conversations all still work.

  Refuses with `:last_grant_holder` if any of them is its venue's last active
  grant-holding engagement (R22, KTD17), and refuses *before* closing any of
  them — each close is its own transaction, so a partial refusal is one nothing
  can undo. An id naming nobody is `:not_found`; a person holding nothing
  closable succeeds and answers with an empty list.

  Takes a person id and no scope. The enumeration crosses venues, which is
  exactly what no employer session may do; each close then runs as the venue it
  belongs to. See the moduledoc.
  """
  @spec end_all_engagements(Ecto.UUID.t()) ::
          {:ok, [Engagement.t()]} | {:error, closure_failure()}
  def end_all_engagements(person_id) when is_binary(person_id) do
    now = Clock.now()

    person_id
    |> identified()
    |> known(now)
    |> closable()
    |> refuse_or_close()
  end

  # A person id arriving over HTTP is user input. `Ecto.UUID.cast/1` is the same
  # shape `HospitalityComsWeb.ChannelAuth.topic_id/1` uses for a topic suffix,
  # and for the same reason: without it `Repo.get/2` raises
  # `Ecto.Query.CastError` out of a function whose spec enumerates three atoms.
  @spec identified(String.t()) :: Ecto.UUID.t() | nil
  defp identified(person_id) do
    person_id |> Ecto.UUID.cast() |> cast_or_nil()
  end

  @spec cast_or_nil({:ok, Ecto.UUID.t()} | :error) :: Ecto.UUID.t() | nil
  defp cast_or_nil({:ok, person_id}), do: person_id
  defp cast_or_nil(:error), do: nil

  @spec known(Ecto.UUID.t() | nil, DateTime.t()) ::
          {:ok, [Engagement.t()], DateTime.t()} | {:error, :not_found}
  defp known(nil, _now), do: {:error, :not_found}
  defp known(person_id, now), do: Person |> Repo.get(person_id) |> held(now)

  @spec held(Person.t() | nil, DateTime.t()) ::
          {:ok, [Engagement.t()], DateTime.t()} | {:error, :not_found}
  defp held(nil, _now), do: {:error, :not_found}

  defp held(%Person{} = person, now) do
    engagements =
      person
      |> PersonScope.for_person(now)
      |> Engagements.list_person_history()
      |> Enum.filter(&(DateTime.compare(&1.ends_at, now) == :gt))

    {:ok, engagements, now}
  end

  # The pre-flight, and the whole of why it is not a second copy of KTD17:
  # `Engagements.would_orphan_venue?/2` is the same decision `end_engagement/2`
  # makes, asked by the function that makes it.
  @spec closable({:ok, [Engagement.t()], DateTime.t()} | {:error, :not_found}) ::
          {:ok, [{EmployerScope.t(), Engagement.t()}]} | {:error, closure_failure()}
  defp closable({:error, :not_found}), do: {:error, :not_found}

  defp closable({:ok, engagements, now}) do
    engagements
    |> Enum.map(&{acting_scope(&1.venue_id, now), &1})
    |> permitted()
  end

  @spec permitted([{EmployerScope.t() | nil, Engagement.t()}]) ::
          {:ok, [{EmployerScope.t(), Engagement.t()}]}
          | {:error, :last_grant_holder | :no_grant}
  defp permitted(pairs) do
    cond do
      Enum.any?(pairs, fn {scope, _engagement} -> is_nil(scope) end) -> {:error, :no_grant}
      Enum.any?(pairs, &orphaning?/1) -> {:error, :last_grant_holder}
      true -> {:ok, pairs}
    end
  end

  @spec orphaning?({EmployerScope.t(), Engagement.t()}) :: boolean()
  defp orphaning?({scope, engagement}),
    do: Engagements.would_orphan_venue?(scope, engagement.id)

  @spec refuse_or_close(
          {:ok, [{EmployerScope.t(), Engagement.t()}]} | {:error, closure_failure()}
        ) :: {:ok, [Engagement.t()]} | {:error, closure_failure()}
  defp refuse_or_close({:error, reason}), do: {:error, reason}

  defp refuse_or_close({:ok, pairs}) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn {scope, engagement}, {:ok, closed} ->
      scope |> Engagements.end_engagement(engagement.id) |> collected(closed)
    end)
    |> oldest_first()
  end

  @spec collected(
          {:ok, Engagement.t()} | {:error, closure_failure()},
          [Engagement.t()]
        ) :: {:cont, {:ok, [Engagement.t()]}} | {:halt, {:error, closure_failure()}}
  defp collected({:ok, engagement}, closed), do: {:cont, {:ok, [engagement | closed]}}
  defp collected({:error, reason}, _closed), do: {:halt, {:error, reason}}

  @spec oldest_first({:ok, [Engagement.t()]} | {:error, closure_failure()}) ::
          {:ok, [Engagement.t()]} | {:error, closure_failure()}
  defp oldest_first({:ok, closed}), do: {:ok, Enum.reverse(closed)}
  defp oldest_first({:error, reason}), do: {:error, reason}

  # A live grant at the venue, which is the authority the close runs under. The
  # control has none of its own; this is the venue's, borrowed for one write.
  @spec acting_scope(Ecto.UUID.t(), DateTime.t()) :: EmployerScope.t() | nil
  defp acting_scope(venue_id, now) do
    venue_id
    |> EmployerGrant.live_at(now)
    |> order_by([grant], asc: grant.granted_at, asc: grant.id)
    |> limit(1)
    |> select([grant], grant.id)
    |> Repo.one()
    |> scoped(venue_id, now)
  end

  @spec scoped(Ecto.UUID.t() | nil, Ecto.UUID.t(), DateTime.t()) :: EmployerScope.t() | nil
  defp scoped(nil, _venue_id, _now), do: nil
  defp scoped(grant_id, venue_id, now), do: EmployerScope.for_grant(venue_id, grant_id, now)

  ## Small helpers

  @spec person_scope(Ecto.UUID.t(), DateTime.t()) :: PersonScope.t()
  defp person_scope(person_id, instant) do
    PersonScope.for_person(Accounts.get_person!(person_id), instant)
  end

  @spec days(DateTime.t(), integer()) :: DateTime.t()
  defp days(instant, count), do: DateTime.add(instant, count, :day)

  @spec hours(DateTime.t(), integer()) :: DateTime.t()
  defp hours(instant, count), do: DateTime.add(instant, count, :hour)
end
