defmodule HospitalityComs.Rooms.ShiftRoom do
  @moduledoc """
  One shift, and the room it is.

  There is no separate `shifts` table. The plan's zone diagram lists `shifts`
  alongside `membership_snapshots`; KTD6b deleted the second, and the first
  never carried a field the room did not. A shift room is a term, the type it
  was built from, and the grace it stops accepting messages after.

  ## The open interval is `[starts_at, ends_at + grace)`

  Half-open, like every other interval in this schema (KTD4), so the instant a
  room closes already belongs to the closed side and two consecutive shifts of
  the same type neither overlap nor leave a gap.

  It is a **write** window, not a read window. R11: a shift room accepts
  messages until the grace has elapsed and *remains readable* afterwards to
  everyone whose roster period overlapped that same interval. Closing writes and
  closing reads are two different events, and only the first has a clock.

  `closes_at` is a `GENERATED ALWAYS AS (ends_at + make_interval(mins =>
  grace_period_minutes)) STORED` column, read back after every write and never
  set. Deriving it in Elixir instead would make it a second spelling of a rule
  the database already knows, and the one that could disagree.

  ## The grace is stamped, not joined

  `grace_period_minutes` is copied from the shift type when the room is created
  and never read back through `shift_type_id`. That is the rule an invitation's
  term follows onto an engagement, and the argument is sharper here: a shift
  type edited on Tuesday would otherwise reopen Monday's closed room — or close
  one somebody is standing in — retroactively, and for every room of that type
  at once.

  `shift_type_id` stays, for provenance and for the name a client renders. It is
  a composite key into `shift_types (id, venue_id)`, `MATCH FULL`, so a room at
  venue A cannot be built from venue B's type.

  ## Nothing here is castable from user attributes

  Every field is set by `HospitalityComs.Rooms.create_shift_room/2` from the
  caller's scope and from the shift type it resolved, except the two instants
  that *are* the caller's choice. `venue_id` in particular is put from the
  scope: a `venue_id` arriving in user attributes is a cross-tenant write
  waiting for somebody to forget to strip it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "shift_rooms" do
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :grace_period_minutes, :integer

    # Generated in the database and never written from here. `read_after_writes`
    # is what puts it in the `RETURNING` list, so an inserted struct carries the
    # boundary the database computed rather than one this module guessed.
    field :closes_at, :utc_datetime, read_after_writes: true

    belongs_to :venue, Venue
    belongs_to :shift_type, ShiftType

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          shift_type_id: Ecto.UUID.t() | nil,
          shift_type: ShiftType.t() | Ecto.Association.NotLoaded.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          grace_period_minutes: non_neg_integer() | nil,
          closes_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  A room for `shift_type`, over the term in `attrs`, stamped from `now`.

  `attrs` carries `:starts_at` and `:ends_at`. The venue and the grace come from
  the shift type the caller already resolved against the database, so neither is
  castable and neither can name somebody else's venue.
  """
  @spec changeset(ShiftType.t(), map(), DateTime.t()) :: Ecto.Changeset.t(t())
  def changeset(%ShiftType{} = shift_type, attrs, %DateTime{} = now) when is_map(attrs) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> cast(attrs, [:starts_at, :ends_at])
    |> validate_required([:starts_at, :ends_at])
    |> put_change(:venue_id, shift_type.venue_id)
    |> put_change(:shift_type_id, shift_type.id)
    |> put_change(:grace_period_minutes, shift_type.grace_period_minutes)
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
    |> validate_term()
    |> declare_constraints()
  end

  # The database carries the same rule as a check constraint, and the constraint
  # is what a write bypassing this changeset would meet. This clause is here so
  # the ordinary caller gets a field error rather than a constraint message.
  @spec validate_term(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp validate_term(changeset) do
    ordered_term(
      changeset,
      get_change(changeset, :starts_at),
      get_change(changeset, :ends_at)
    )
  end

  @spec ordered_term(Ecto.Changeset.t(t()), DateTime.t() | nil, DateTime.t() | nil) ::
          Ecto.Changeset.t(t())
  defp ordered_term(changeset, %DateTime{} = starts_at, %DateTime{} = ends_at) do
    ends_at
    |> DateTime.compare(starts_at)
    |> refuse_unless_ordered(changeset)
  end

  defp ordered_term(changeset, _starts_at, _ends_at), do: changeset

  @spec refuse_unless_ordered(:lt | :eq | :gt, Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp refuse_unless_ordered(:gt, changeset), do: changeset

  defp refuse_unless_ordered(_order, changeset) do
    add_error(changeset, :ends_at, "must be after the shift starts")
  end

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> check_constraint(:ends_at,
      name: :shift_rooms_term_ordered,
      message: "must be after the shift starts"
    )
    |> check_constraint(:grace_period_minutes,
      name: :shift_rooms_grace_within_bound,
      message: "must be between 0 and #{ShiftType.max_grace_minutes()} minutes"
    )
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:shift_type_id, name: :shift_rooms_shift_type_fkey)
  end
end
