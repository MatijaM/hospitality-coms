defmodule HospitalityComs.Rooms.VenueRoomSuspension do
  @moduledoc """
  A person's own opt-out of one venue room, and the reason it is a person-zone
  table.

  ## KTD18 is a classification, not a `select` list

  Origin R11 is one sentence carrying the document's central privacy claim: a
  person may take themselves out of the venue room, reversibly, and the employer
  must not be able to see that they have. Employer visibility of the flag would
  make it a retaliation surface rather than an opt-out, which is the shape of
  the case the plan's Problem Frame cites.

  A boolean on `engagements` could not deliver that. `employer_role` holds
  table-level `SELECT` there, so the flag would arrive with every membership
  read and the only thing hiding it would be somebody remembering to trim a
  `select`. Anywhere in the employer zone has the same problem.

  So the row lives in a table of its own, classified `:person` in
  `HospitalityComs.Zones`, which means three things hold at once and none of
  them is a convention: `employer_role` holds no privilege on it and the sweep
  in `HospitalityComs.BoundaryTest` asserts so; `HospitalityComs.EmployerRepo`'s
  query backstop raises `ZoneViolationError` on any employer query that reaches
  it, naming the table; and Postgres would refuse the same statement for want of
  privilege if the backstop were removed.

  There is no `venue_id` here and there will not be one — a person-zone table
  carrying an employer key is the thing the partition forbids. It names the
  *engagement*, which is the one row in the schema that already means "this
  person, at this venue", and pointing at it from the person's side is what the
  bridge is for.

  ## It is a period, because nothing may store an authorization decision

  `[suspended_at, resumed_at)`, half-open (KTD4), generated into a `tstzrange`
  in the database and guarded there by an exclusion constraint on
  `(engagement_id, period)`. Suspended at instant `t` is `period @> t` — the
  same predicate, spelled the same way, as `Engagements.Records.active_at/2`.

  A boolean would be a cached decision, which is the failure the whole design
  exists to prevent. A period also makes "suspend twice" a database error rather
  than a second open row nobody notices, and it leaves the person a record of
  when they were out — in their own zone, reaching no employer.

  Resuming at the instant of suspension gives `[a, a)`, the empty range: the
  person was never out, and they may suspend again over the same instant because
  an empty range overlaps nothing.

  ## Suspension does not reach shift rooms

  KTD18 says the venue room only, and this module cannot reach further even if a
  caller asked: shift-room membership is derived from `roster_entries` and
  `engagements`, both employer-zone reads, and neither query joins this table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Engagements.Engagement

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "venue_room_suspensions" do
    field :suspended_at, :utc_datetime
    field :resumed_at, :utc_datetime

    belongs_to :engagement, Engagement

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          engagement_id: Ecto.UUID.t() | nil,
          engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          suspended_at: DateTime.t() | nil,
          resumed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @overlap_constraint :venue_room_suspensions_no_overlap

  @doc """
  The name of the exclusion constraint that makes one open suspension the most
  an engagement can hold.

  Exposed so the proof suite can look for it in `pg_constraint` by the same name
  the changeset declares, rather than by a string written twice.
  """
  @spec overlap_constraint() :: atom()
  def overlap_constraint, do: @overlap_constraint

  @doc """
  Opens a suspension on `engagement_id` at `now`, with no upper bound.

  Nothing is cast from user attributes. A suspension is a person saying "not
  now" about a room they are already in; there is nothing in it for them to
  choose, and a castable `suspended_at` would be a way to backdate an absence.
  """
  @spec open_changeset(Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def open_changeset(engagement_id, %DateTime{} = now) when is_binary(engagement_id) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> change(
      engagement_id: engagement_id,
      suspended_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> declare_constraints()
  end

  @doc """
  Closes an open suspension at `now`.

  The row is kept. Deleting it would erase the person's own record of having
  been out, and deletion is confined to the lifecycle context in any case
  (KTD21).
  """
  @spec close_changeset(t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def close_changeset(%__MODULE__{} = suspension, %DateTime{} = now) do
    stamped_at = DateTime.truncate(now, :second)

    suspension
    |> change(resumed_at: stamped_at, updated_at: stamped_at)
    |> declare_constraints()
  end

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> exclusion_constraint(:period,
      name: @overlap_constraint,
      message: "overlaps a suspension this engagement already holds"
    )
    |> check_constraint(:resumed_at,
      name: :venue_room_suspensions_period_not_reversed,
      message: "cannot be before the suspension began"
    )
    |> foreign_key_constraint(:engagement_id)
  end
end
