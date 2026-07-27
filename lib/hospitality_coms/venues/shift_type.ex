defmodule HospitalityComs.Venues.ShiftType do
  @moduledoc """
  A kind of shift a venue runs, and the grace period its rooms stay open for.

  A shift room accepts messages until the grace period defined by its type has
  elapsed past the shift's end, and remains readable afterwards to everyone
  whose roster period overlapped the room's open interval (R11, KTD14). The
  grace is therefore a write window, not a read window, and U6 is what reads
  this column.

  ## Zero is a value, not an omission

  A zero grace closes the room at shift end. It is an ordinary configuration —
  the plan's own test scenarios name it — so the validation is
  `greater_than_or_equal_to: 0` rather than a presence check that would treat
  the meaningful zero as a missing value.

  ## Two hours is the ceiling

  Above that a grace period stops being the tail of a shift and becomes a
  second shift, with a room that outlives the roster that justified it. The
  bound is enforced twice: here, so the caller gets a changeset error naming
  the field, and in a check constraint, so a write that never passes through
  this changeset cannot get around it.

  Shift types belong to a venue rather than to an employer. The plan flags that
  as the narrower of the two readings and the easier one to widen, and the open
  question is recorded there rather than decided here.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "shift_types" do
    field :name, :string
    field :grace_period_minutes, :integer

    belongs_to :venue, Venue

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          name: String.t() | nil,
          grace_period_minutes: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @max_grace_minutes 120
  @max_name_length 160

  @doc """
  The longest grace period a shift type may carry, in minutes.
  """
  @spec max_grace_minutes() :: pos_integer()
  def max_grace_minutes, do: @max_grace_minutes

  @doc """
  A changeset for a shift type at `venue_id`, stamped from `now`.

  The venue is an argument rather than a castable field. It is the caller's
  scope that decides which venue a write lands on, and a `venue_id` arriving in
  user attributes is a cross-tenant write waiting for somebody to forget to
  strip it.
  """
  @spec changeset(t(), Ecto.UUID.t(), map(), DateTime.t()) :: Ecto.Changeset.t(t())
  def changeset(shift_type, venue_id, attrs, %DateTime{} = now) when is_binary(venue_id) do
    shift_type
    |> cast(attrs, [:name, :grace_period_minutes])
    |> put_change(:venue_id, venue_id)
    |> validate_required([:name, :grace_period_minutes])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name_length)
    |> validate_number(:grace_period_minutes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_grace_minutes
    )
    |> check_constraint(:grace_period_minutes,
      name: :shift_types_grace_within_two_hours,
      message: "must be between 0 and #{@max_grace_minutes} minutes"
    )
    |> check_constraint(:name, name: :shift_types_name_present, message: "can't be blank")
    |> check_constraint(:name,
      name: :shift_types_name_within_bound,
      message: "should be at most #{@max_name_length} character(s)"
    )
    |> unique_constraint([:venue_id, :name])
    |> foreign_key_constraint(:venue_id)
    |> stamp(now)
  end

  @doc """
  A venue's shift types, oldest first.
  """
  @spec of_venue(Ecto.UUID.t()) :: Ecto.Query.t()
  def of_venue(venue_id) when is_binary(venue_id) do
    from shift_type in __MODULE__,
      where: shift_type.venue_id == ^venue_id,
      order_by: [asc: shift_type.inserted_at, asc: shift_type.id]
  end

  @spec stamp(Ecto.Changeset.t(t()), DateTime.t()) :: Ecto.Changeset.t(t())
  defp stamp(%Ecto.Changeset{data: %__MODULE__{inserted_at: nil}} = changeset, now) do
    stamped_at = DateTime.truncate(now, :second)

    changeset
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
  end

  defp stamp(changeset, now) do
    put_change(changeset, :updated_at, DateTime.truncate(now, :second))
  end
end
