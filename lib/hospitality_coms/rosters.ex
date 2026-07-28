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

  The close is one statement with `left_at IS NULL` in its own `WHERE`, so two
  managers removing the same person at two instants cannot both succeed and
  leave the upper bound wherever the slower transaction put it. See
  `close_open_period/2`; `HospitalityComs.RoomsConcurrencyTest` measures it.

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
  the transaction, at the scope's venue, so an engagement belonging to another
  venue is `{:error, :not_found}`. The composite foreign key refuses the same
  thing underneath, whatever this module believes.

  ## Next week's hire goes on next week's rota

  `add_to_roster/3` takes an engagement whose **term has not closed** at the
  scope's instant — active *or not yet started* — which is
  `HospitalityComs.Engagements.Records.not_ended_by/2` and is exactly the target
  set `HospitalityComs.Engagements.end_engagement/2` uses, for the reason U5
  widened that one: an engagement that has not opened is a different state from
  one that has closed, and a predicate written for the second excluded the first
  as a side effect.

  It used to require the engagement to be *active*, so a person who claimed an
  invitation whose term opens next Monday could not be put on next Tuesday's
  shift today — even though the entry created would be `[today, ∞)` and would
  overlap Tuesday's room perfectly well. The operator had to wait for the
  engagement to open before building the rota that engagement exists for.

  **Nothing depended on the write-time check, and that is measured rather than
  assumed.** Membership and readability both intersect the roster with an
  engagement active *at the instant asked about* —
  `HospitalityComs.Rooms.Records.shift_room_members/2`, `shift_room_readers/2`
  and `readable_shift_rooms/2` all compose
  `HospitalityComs.Engagements.Records.active_at/2` — so an entry belonging to a
  term that has not opened confers no membership, no readability and no room in
  the person's own list until it does. `HospitalityComs.RostersTest` asserts
  that against a real rostering rather than leaving it to this paragraph.

  **One residue, and it is the price of one spelling.** "The term has not
  closed" is `ends_at > instant`, so it also admits an engagement that was
  *ended before it opened* — `end_engagement/2` produces `ends_at == starts_at`,
  and where that instant is in the future the empty term is still ahead of now.
  Such an entry confers nothing at any instant, because the empty range is
  active at none, and `remove_from_roster/3` closes it like any other. Excluding
  it would take a non-emptiness clause this predicate does not otherwise need
  and would make the set `add_to_roster/3` accepts differ from the set
  `end_engagement/2` targets, which is how one concept comes to have two
  spellings.

  ## The refusal stays `:not_found`, and that is a decision

  An engagement at another venue, a term that has closed, and an id that names
  nothing all get `{:error, :not_found}` — identically, so the refusal
  enumerates nothing (AE1). That is deliberate and is not the leftover of the
  bug above: a caller who could tell "no such engagement" from "that engagement
  cannot be rostered" could walk a venue's engagement ids one refusal at a time,
  and the shift room id in the same call is the other half of the same
  disclosure.

  Whether an operator acting *inside their own venue* deserves a distinguishable
  reason is a real question and a **product** one, not an implementation one:
  the answer changes what a manager may learn by asking, and issue #24 raises it
  without deciding it. Left as `:not_found` here.
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
  the room — see `remove_from_roster/3`. It is also why a hire whose term opens
  next Monday can be rostered today: the entry opens now, the engagement opens
  Monday, and membership is the intersection.

  The engagement's term must not have **closed** at the scope's instant; it need
  not have opened. See the moduledoc for what that widening rests on and for the
  one state it admits as a consequence.

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

  It is the same answer a caller gets when somebody else closed the period
  while this call was resolving it — see `close_open_period/2`.
  """
  @spec remove_from_roster(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()} | {:error, :no_grant | :not_rostered}
  def remove_from_roster(%EmployerScope{grant_id: grant_id} = scope, shift_room_id, engagement_id)
      when is_binary(grant_id) and is_binary(shift_room_id) and is_binary(engagement_id) do
    EmployerRepo.scoped_transaction(scope, &close_entry(&1, shift_room_id, engagement_id))
  end

  @spec close_entry(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RosterEntry.t()} | {:error, :no_grant | :not_rostered}
  defp close_entry(scope, shift_room_id, engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, entry} <- fetch_open_entry(scope, shift_room_id, engagement_id) do
      entry |> close_open_period(scope.now) |> closed_or_lost()
    end
  end

  # The whole of the concurrency story is `is_nil(candidate.left_at)` repeated
  # inside the write.
  #
  # Reading the open entry and then updating it by primary key let two managers
  # removing the same person at two instants both read the same row and both
  # write. The later *commit* won, which is neither the earlier removal nor the
  # later one — it is whichever transaction the scheduler finished second — so a
  # period's upper bound moved backwards while both callers were told the
  # removal had happened.
  #
  # One `UPDATE … WHERE left_at IS NULL` that both aim at answers it: Postgres
  # serialises them on the row and re-evaluates the predicate for the second,
  # which then matches nothing. That is the manoeuvre
  # `HospitalityComs.Engagements.claim_invitation/2` makes with `claimed_at IS
  # NULL`, and it fits better here than the `optimistic_lock/2` U5 put on
  # `engagements`: a renewal is a repeatable mutation where "somebody else
  # changed this" is the only honest answer, while closing a period happens once
  # and the honest answer to closing one somebody else has already closed is
  # `:not_rostered` — the answer this function already gives for a period closed
  # a moment ago, which is the same event seen a little later.
  #
  # No constraint can fire. `closing_instant/2` never returns an instant before
  # `joined_at`, and narrowing a period cannot create an overlap that widening
  # it would — so there is no changeset in this path and none in the spec.
  @spec close_open_period(RosterEntry.t(), DateTime.t()) ::
          {non_neg_integer(), [RosterEntry.t()] | nil}
  defp close_open_period(entry, now) do
    RosterEntry
    |> where([candidate], candidate.id == ^entry.id)
    |> where([candidate], is_nil(candidate.left_at))
    |> select([candidate], candidate)
    |> EmployerRepo.update_all(
      set: [
        left_at: RosterEntry.closing_instant(entry, now),
        updated_at: DateTime.truncate(now, :second)
      ]
    )
  end

  @spec closed_or_lost({non_neg_integer(), [RosterEntry.t()] | nil}) ::
          {:ok, RosterEntry.t()} | {:error, :not_rostered}
  defp closed_or_lost({1, [%RosterEntry{} = entry]}), do: {:ok, entry}
  defp closed_or_lost({0, _rows}), do: {:error, :not_rostered}

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

  # At the scope's venue, and on a term that has not closed by the scope's
  # instant. An engagement whose term has closed cannot be rostered onto a
  # shift: the roster is a statement about who works, and somebody who no longer
  # works there does not. One that has not opened *yet* is a different state —
  # it is the rota being built in advance, which is what a rota is for — and
  # `not_ended_by/2` is the same predicate `end_engagement/2` targets rather
  # than a second spelling of "not closed".
  @spec fetch_engagement(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :not_found}
  defp fetch_engagement(scope, engagement_id) do
    Engagement
    |> EngagementRecords.of_venue(scope.venue_id)
    |> EngagementRecords.not_ended_by(scope.now)
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
