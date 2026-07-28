defmodule HospitalityComs.Rosters.RosterEntry do
  @moduledoc """
  One person on one shift, for one interval — and the interval is the point.

  ## Removal closes a period; nothing deletes a row

  KTD6b. The earlier design snapshotted a shift room's membership at shift start
  so that a later roster correction could not retroactively withdraw access to
  messages somebody had already read. That inverts under its own failure mode: a
  job firing late captures the roster *as corrected*, which is the withdrawal it
  existed to prevent, and a run that never happened looks exactly like a roster
  that was empty.

  With a period, non-retroactivity is structural rather than defended.
  `HospitalityComs.Rosters.remove_from_roster/3` sets `left_at` to the instant
  of the removal, and closing a period at `now` cannot shorten the part of it
  before `now` — so an overlap that has already happened cannot be unmade by any
  write this schema permits. There is no operation that shortens the lower
  bound, and the employer role holds `UPDATE` on `left_at` and `updated_at`
  alone, so there is no statement that could.

  ## `joined_at` is when the rostering happened, not when the shift starts

  That is what makes "rostered on Monday for Friday's shift, removed on Tuesday"
  a period ending before the room ever opens: no overlap, so the person never
  appears in it and never could have. Stamping `joined_at` at the shift's start
  instead would make that case indistinguishable from somebody who worked it.

  `left_at` is null while the person is still rostered, which makes the period
  unbounded above — the right reading of "still on the roster", and the one that
  lets an entry added mid-shift overlap the rest of the room's open interval
  without anybody deciding what its upper bound should be.

  ## Both bounds carry microseconds, and neither is truncated

  `:utc_datetime_usec` over `timestamp(6)`, alone among this schema's instant
  columns. A bound rounded to the second is a bound that moves when it is
  written, and each direction breaks something the design claims:

    * flooring `joined_at` backdates the rostering by up to a second, which is a
      retroactive grant of the exact kind the period was chosen to make
      unrepresentable;
    * flooring `left_at` closes the period *before* the removal happened, which
      shortens an overlap that has already elapsed — and "no write can do that"
      is the whole of the paragraph above.

  Dropping the truncation on its own would not have been enough. The columns
  were `timestamp(0)`, which **rounds**: a removal at `12:00:01.8` would have
  landed as `12:00:02`, a bound in the future of the call rather than the past
  of it. The column type and the changeset had to move together, and
  `*_create_roster_entries.exs` moved the first.

  `inserted_at` and `updated_at` are still whole seconds — they are bookkeeping,
  and no predicate reads them — so they are the one thing here that is still
  truncated.

  ## Two overlapping periods on one shift are a database error

  `roster_entries_no_overlap` is an `EXCLUDE USING gist (shift_room_id WITH =,
  engagement_id WITH =, period WITH &&)`, and `exclusion_constraint/3` below is
  declared against its name. Without the declaration the violation raises
  through the transaction as a `Postgrex.Error` and the repository's enumerated
  errors become a lie at the one place it is load bearing.

  Adjacent periods are not a violation: removed at `t` and rostered again at `t`
  gives `[a, t)` and `[t, ∞)`, which do not overlap. Neither is an entry removed
  at the instant it was added — `[t, t)` is the empty range, which overlaps
  nothing including the room, so the person was never in it and their slot is
  free again.

  ## It names the engagement

  `roster_entries` is an employer-zone table, so it may not carry `person_id`
  (KTD2). It references `engagements (id, venue_id)` with a `MATCH FULL`
  composite key, so a roster entry at venue A cannot name an engagement at venue
  B whatever `HospitalityComs.Rosters` believes, and the association to a human
  is made from the person's side by following the bridge.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "roster_entries" do
    field :joined_at, :utc_datetime_usec
    field :left_at, :utc_datetime_usec

    # KTD16's shift-history deadline, stamped at insert from the room's
    # `closes_at` and never joined afterwards. Whole seconds, unlike the two
    # bounds above: nothing derives a period from it, and the sweep's comparison
    # is `delete_after < instant`, so a second of slop moves a deletion by a
    # second rather than changing an overlap that has already elapsed.
    field :delete_after, :utc_datetime

    belongs_to :venue, Venue
    belongs_to :shift_room, ShiftRoom
    belongs_to :engagement, Engagement

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          shift_room_id: Ecto.UUID.t() | nil,
          shift_room: ShiftRoom.t() | Ecto.Association.NotLoaded.t() | nil,
          engagement_id: Ecto.UUID.t() | nil,
          engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          joined_at: DateTime.t() | nil,
          left_at: DateTime.t() | nil,
          delete_after: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @overlap_constraint :roster_entries_no_overlap

  @doc """
  The name of the exclusion constraint that refuses double-rostering.

  Exposed so the proof suite can look for it in `pg_constraint` by the same name
  the changeset declares, rather than by a string written twice.
  """
  @spec overlap_constraint() :: atom()
  def overlap_constraint, do: @overlap_constraint

  @doc """
  Puts `engagement` on `room`'s roster from `now`, with no upper bound.

  Nothing is cast from user attributes. Both ids and the venue come from rows
  `HospitalityComs.Rosters` resolved against the database inside the same
  transaction, so there is no attribute a caller could pass that would move the
  entry to another venue or backdate its lower bound.

  `joined_at` is `now` exactly. Truncating it to the second would backdate the
  rostering by up to a second, which is the one thing a lower bound may never
  do; `inserted_at` and `updated_at` are truncated because their column is
  `timestamp(0)` and nothing reads them.
  """
  @spec join_changeset(ShiftRoom.t(), Engagement.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def join_changeset(%ShiftRoom{} = room, %Engagement{} = engagement, %DateTime{} = now) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> change(
      venue_id: room.venue_id,
      shift_room_id: room.id,
      engagement_id: engagement.id,
      joined_at: now,
      delete_after: Lifecycle.history_deadline(room.closes_at),
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> declare_constraints()
  end

  @doc """
  The instant an open entry closes at: `now`, widened to the entry's own
  `joined_at` where that is later.

  The one mutation a roster entry has moves the upper bound and nothing else,
  and there is no changeset for it — `HospitalityComs.Rosters.remove_from_roster/3`
  writes it as one conditional `UPDATE` so that two concurrent removals cannot
  both succeed, and this is the value it writes.

  For an entry rostered in the future the widening gives `[a, a)`, the empty
  range, which overlaps nothing: `ends_at < starts_at` is unrepresentable, and
  this is the same widening `HospitalityComs.Engagements.end_engagement/2` makes
  for the same reason — a rostering made in error must be undoable without
  leaving a period nobody can free.

  Not truncated. A floored upper bound closes the period before the removal
  happened, and the part of a period that has already elapsed is the one thing
  no write here may shorten.
  """
  @spec closing_instant(t(), DateTime.t()) :: DateTime.t()
  def closing_instant(%__MODULE__{joined_at: joined_at}, %DateTime{} = now) do
    joined_at |> DateTime.compare(now) |> later_of(joined_at, now)
  end

  @spec later_of(:lt | :eq | :gt, DateTime.t(), DateTime.t()) :: DateTime.t()
  defp later_of(:gt, joined_at, _now), do: joined_at
  defp later_of(_order, _joined_at, now), do: now

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> exclusion_constraint(:period,
      name: @overlap_constraint,
      message: "overlaps a period this person already holds on this shift"
    )
    |> check_constraint(:left_at,
      name: :roster_entries_period_not_reversed,
      message: "cannot be before the person joined the roster"
    )
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:shift_room_id, name: :roster_entries_shift_room_fkey)
    |> foreign_key_constraint(:engagement_id, name: :roster_entries_engagement_fkey)
  end
end
