defmodule HospitalityComs.Rosters do
  @moduledoc """
  Who is on a shift, and for how long — the only writes a shift room's
  membership has.

  Everything here runs under a `HospitalityComs.Accounts.EmployerScope` through
  `HospitalityComs.EmployerRepo` inside `scoped_transaction/2`, under a grant
  resolved against the database on every call, exactly as
  `HospitalityComs.Venues` and `HospitalityComs.Engagements` do. Rostering is an
  administrative act: it is the employer saying who works the shift.

  Reading a roster's *consequences* is not administrative and does not live
  here. `HospitalityComs.Rooms` owns "who is in this room" and "who may read
  it", because those are questions about rooms that a roster happens to be an
  input to, and because one of them subtracts a person-zone table no employer
  scope may reach.

  ## Removal closes a period; nothing here deletes a row

  KTD6b, and it is the reason this context exists in the shape it does. The
  earlier design materialised a shift room's membership at shift start so that a
  later roster correction could not retroactively withdraw access to messages
  somebody had already read. It inverts under its own failure mode — a job
  firing ten minutes late captures the roster *as corrected*, which is the exact
  withdrawal it existed to prevent, and a run that never happened is
  indistinguishable from a roster that was empty.

  `remove_from_roster/3` sets `left_at` to the scope's instant instead. Closing
  a period at `now` cannot shorten the part of it before `now`, so an overlap
  that has already happened is unreachable by any write this context permits —
  non-retroactivity becomes a property of the schema rather than a rule somebody
  enforces. The employer role holds `UPDATE` on `left_at` and `updated_at` alone
  for the same reason: `joined_at` is not movable by any statement an employer
  session can issue.

  It follows that a roster entry is never deleted here, and not only because
  deletion is confined to the lifecycle context (KTD21). A rostering made in
  error is *closed*, which for an entry that has not begun means closing it at
  its own `joined_at` — the empty range, overlapping nothing, so the person was
  never in the room and their slot is free again.

  ## Two overlapping periods on one shift are a database error

  `roster_entries_no_overlap` is an `EXCLUDE USING gist (shift_room_id WITH =,
  engagement_id WITH =, period WITH &&)` — the GiST index KTD6b asks for, doing
  two jobs at once. `add_to_roster/3` checks for an open entry first so the
  ordinary case gets `{:error, :already_rostered}` rather than a constraint
  message, and the constraint is what makes the check safe under concurrency:
  two managers rostering the same person at once both see no open entry, both
  insert, and the second is refused by Postgres and arrives as a changeset error
  because `HospitalityComs.Rosters.RosterEntry` declares the constraint by name.

  ## Only this venue's engagements

  The engagement a roster entry names is resolved against the database inside
  the transaction, at the scope's instant and at the scope's venue, so an
  engagement belonging to another venue or one whose term has closed is
  `{:error, :not_found}` — the same answer an id that names nothing gets, so the
  refusal enumerates nothing. The composite foreign key refuses the same thing
  underneath, whatever this module believes.
  """

  import Ecto.Query

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Records, as: EngagementRecords
  alias HospitalityComs.Rooms.Records
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues

  @typedoc """
  Why a roster write was refused.

  `:no_grant` is the acting authority; `:not_found` covers the shift room, the
  engagement, and the entry alike, so a caller learns nothing about which of
  them exists.
  """
  @type refusal() :: :no_grant | :not_found | :already_rostered | :not_rostered

  @doc """
  Puts an engagement on a shift room's roster from the scope's instant.

  The entry has no upper bound until somebody removes it, which is what makes a
  person added mid-shift a member for the rest of the room's open window without
  anybody deciding when they should stop being one.

  `joined_at` is the instant of *this call*, not the shift's start. That is what
  makes a rostering undone before the shift begins a period that never overlaps
  the room — see `remove_from_roster/3`.

  Refuses a scope with no grant by function clause.
  """
  @spec add_to_roster(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()}
          | {:error, refusal() | Ecto.Changeset.t(RosterEntry.t())}
  def add_to_roster(%EmployerScope{grant_id: grant_id} = scope, shift_room_id, engagement_id)
      when is_binary(grant_id) and is_binary(shift_room_id) and is_binary(engagement_id) do
    EmployerRepo.scoped_transaction(scope, &write_entry(&1, shift_room_id, engagement_id))
  end

  @spec write_entry(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()}
          | {:error, refusal() | Ecto.Changeset.t(RosterEntry.t())}
  defp write_entry(scope, shift_room_id, engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, room} <- fetch_room(scope, shift_room_id),
         {:ok, engagement} <- fetch_engagement(scope, engagement_id),
         :ok <- unrostered(scope, shift_room_id, engagement_id) do
      room
      |> RosterEntry.join_changeset(engagement, scope.now)
      |> EmployerRepo.insert()
    end
  end

  # The friendly half of the race. The exclusion constraint is the safe half:
  # two managers rostering the same person at once both pass this and the second
  # insert is refused by Postgres, arriving as a changeset error on `:period`
  # because the constraint is declared by name.
  @spec unrostered(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :already_rostered}
  defp unrostered(scope, shift_room_id, engagement_id) do
    scope
    |> open_entry(shift_room_id, engagement_id)
    |> EmployerRepo.exists?()
    |> refuse_if_rostered()
  end

  @spec refuse_if_rostered(boolean()) :: :ok | {:error, :already_rostered}
  defp refuse_if_rostered(true), do: {:error, :already_rostered}
  defp refuse_if_rostered(false), do: :ok

  @doc """
  Closes an engagement's open period on a shift room at the scope's instant.

  The row stays. Access the person has already earned by overlapping the room's
  open window stays with it — that is the whole of KTD6b, and it is why this is
  an `UPDATE` of one column rather than a `DELETE`.

  An entry whose `joined_at` is still in the future closes at its own opening
  instead, which is the empty range: it overlaps nothing, so the person was
  never in the room and the slot is free for somebody else. This is the same
  widening `HospitalityComs.Engagements.end_engagement/2` makes, for the same
  reason — a mistake must be undoable without leaving a period nobody can free.

  `{:error, :not_rostered}` when there is no open period, which includes one
  that was closed a moment ago: closing it twice would move the upper bound
  forward and *shorten* nothing, but it would rewrite a record of when somebody
  left, and there is no reason to allow that.
  """
  @spec remove_from_roster(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()}
          | {:error, refusal() | Ecto.Changeset.t(RosterEntry.t())}
  def remove_from_roster(%EmployerScope{grant_id: grant_id} = scope, shift_room_id, engagement_id)
      when is_binary(grant_id) and is_binary(shift_room_id) and is_binary(engagement_id) do
    EmployerRepo.scoped_transaction(scope, &close_entry(&1, shift_room_id, engagement_id))
  end

  @spec close_entry(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()}
          | {:error, refusal() | Ecto.Changeset.t(RosterEntry.t())}
  defp close_entry(scope, shift_room_id, engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, entry} <- fetch_open_entry(scope, shift_room_id, engagement_id) do
      entry
      |> RosterEntry.leave_changeset(scope.now)
      |> EmployerRepo.update()
    end
  end

  @doc """
  The shift room's roster at the scope's instant, earliest joined first.

  Entries whose period contains the instant — the roster as it stands, which is
  not the same set as the room's membership (an entry can be live before the
  room opens) and not the same set as its readers (a closed entry that overlapped
  is still one). `HospitalityComs.Rooms` owns those two.
  """
  @spec list_roster(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [RosterEntry.t()]} | {:error, :no_grant | :not_found}
  def list_roster(%EmployerScope{grant_id: grant_id} = scope, shift_room_id)
      when is_binary(grant_id) and is_binary(shift_room_id) do
    EmployerRepo.scoped_transaction(scope, &read_roster(&1, shift_room_id))
  end

  @spec read_roster(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [RosterEntry.t()]} | {:error, :no_grant | :not_found}
  defp read_roster(scope, shift_room_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, _room} <- fetch_room(scope, shift_room_id) do
      {:ok,
       Records.roster()
       |> Records.of_room(shift_room_id)
       |> Records.rostered_at(scope.now)
       |> Records.entries()
       |> EmployerRepo.all()}
    end
  end

  @doc """
  Every period this engagement has ever held on this shift room, earliest first.

  Closed periods included, because a closed period is the record this unit keeps
  instead of a deleted row.
  """
  @spec list_engagement_periods(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [RosterEntry.t()]} | {:error, :no_grant | :not_found}
  def list_engagement_periods(
        %EmployerScope{grant_id: grant_id} = scope,
        shift_room_id,
        engagement_id
      )
      when is_binary(grant_id) and is_binary(shift_room_id) and is_binary(engagement_id) do
    EmployerRepo.scoped_transaction(
      scope,
      &read_engagement_periods(&1, shift_room_id, engagement_id)
    )
  end

  @spec read_engagement_periods(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [RosterEntry.t()]} | {:error, :no_grant | :not_found}
  defp read_engagement_periods(scope, shift_room_id, engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, _room} <- fetch_room(scope, shift_room_id) do
      {:ok,
       Records.roster()
       |> Records.of_room(shift_room_id)
       |> Records.of_engagement(engagement_id)
       |> Records.entries()
       |> EmployerRepo.all()}
    end
  end

  ## Resolution

  @spec fetch_room(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, ShiftRoom.t()} | {:error, :not_found}
  defp fetch_room(scope, shift_room_id) do
    Records.rooms()
    |> Records.of_venue(scope.venue_id)
    |> Records.room(shift_room_id)
    |> EmployerRepo.one()
    |> found_room()
  end

  # At the scope's instant and at the scope's venue. An engagement whose term
  # has closed cannot be rostered onto a shift: the roster is a statement about
  # who works, and somebody who no longer works there does not.
  @spec fetch_engagement(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :not_found}
  defp fetch_engagement(scope, engagement_id) do
    Engagement
    |> EngagementRecords.of_venue(scope.venue_id)
    |> EngagementRecords.active_at(scope.now)
    |> where([engagement], engagement.id == ^engagement_id)
    |> EmployerRepo.one()
    |> found_engagement()
  end

  @spec fetch_open_entry(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()} | {:error, :not_rostered}
  defp fetch_open_entry(scope, shift_room_id, engagement_id) do
    scope
    |> open_entry(shift_room_id, engagement_id)
    |> EmployerRepo.one()
    |> rostered()
  end

  # Open rather than merely live at the instant: an entry closed for the future
  # is not something to close again, and one whose period has not begun is.
  @spec open_entry(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  defp open_entry(scope, shift_room_id, engagement_id) do
    Records.roster()
    |> Records.entries_of_venue(scope.venue_id)
    |> Records.of_room(shift_room_id)
    |> Records.of_engagement(engagement_id)
    |> Records.still_open()
    |> Records.entries()
  end

  @spec found_room(ShiftRoom.t() | nil) :: {:ok, ShiftRoom.t()} | {:error, :not_found}
  defp found_room(nil), do: {:error, :not_found}
  defp found_room(%ShiftRoom{} = room), do: {:ok, room}

  @spec found_engagement(Engagement.t() | nil) :: {:ok, Engagement.t()} | {:error, :not_found}
  defp found_engagement(nil), do: {:error, :not_found}
  defp found_engagement(%Engagement{} = engagement), do: {:ok, engagement}

  @spec rostered(RosterEntry.t() | nil) :: {:ok, RosterEntry.t()} | {:error, :not_rostered}
  defp rostered(nil), do: {:error, :not_rostered}
  defp rostered(%RosterEntry{} = entry), do: {:ok, entry}
end
