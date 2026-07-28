defmodule HospitalityComs.Workers.RetentionSweeperTest do
  @moduledoc """
  The unattended deleter, and the one decision the whole of it rests on.

  ## Deadlines are stamped, never joined

  KTD16. Every trigger reads a `delete_after` column written when the row was
  created — or, for venue-room history, when the venue was closed — and never a
  join against a period that can still move. Computing at sweep time lets a
  manager entering a backdated end date move a deletion deadline into the past
  and have the next unattended run destroy a worker's messages with no notice.

  Two tests here assert exactly that, and they are the reason the column exists:
  each stamps a deadline, then moves the period the deadline came from into the
  distant past, then sweeps at an instant that is past the *moved* period and
  short of the *stamped* deadline, and asserts the rows survive. Both use a
  direct `update_all` on the period, which stands in for a backdating path this
  application does not currently expose — which is the point. The column is
  stamped so that whether such a path exists later stops being a question the
  deleter's correctness depends on.

  ## Half-open, in the same direction as everything else

  `delete_after < instant`. A row whose deadline is exactly the sweep's instant
  survives; the same row a second later does not. Both directions are asserted,
  because a sweeper that deleted nothing at all satisfies the first alone.

  ## The two windows differ on purpose

  Shift history is deleted thirty days after the room closes; the worker's own
  copy of the same message lives ninety days past their engagement's end. That
  gap is what makes KTD16's argument for physically separate rows observable
  rather than asserted: a filtered view over one row would carry two deadlines
  and the shorter would silently win.

  ## Why the workers are driven directly

  `config/test.exs` sets Oban's `testing: :manual`, so no queue runs and no
  plugin ticks. Oban's staging query is bound to real wall-clock time and
  `HospitalityComs.Clock` does not reach it, so advancing the offset changes
  every membership query in the application instantly while a scheduled job
  still waits for real time to arrive. `Oban.Testing.perform_job/2` steps around
  it. `HospitalityComs.Lifecycle.sweep/1` takes the instant so that a test can
  place a sweep on either side of a boundary without moving global state.

  Not sandboxed, through `EngagementsFixtures.real_connections/0`, for U5's
  reason.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: HospitalityComs.Repo

  import Ecto.Query
  import HospitalityComs.EngagementsFixtures
  import HospitalityComs.RoomsFixtures, only: [shift_type_fixture: 2, shift_room_fixture: 4]

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Lifecycle.RetainedMessageCopy
  alias HospitalityComs.Lifecycle.RetentionRun
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rosters
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Workers.ExpireEngagement
  alias HospitalityComs.Workers.RetentionSweeper

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_month DateTime.add(@now, 30, :day)
  @after_the_end DateTime.add(@in_a_month, 1, :hour)

  # The shift: opens an hour from `@now`, runs eight hours, thirty minutes of
  # grace. Comfortably inside the engagement's term, so the worker's archive is
  # written before the venue's copy of the same message is due for deletion.
  @grace_minutes 30
  @shift_starts DateTime.add(@now, 1, :hour)
  @shift_ends DateTime.add(@now, 9, :hour)
  @shift_closes DateTime.add(@shift_ends, @grace_minutes, :minute)
  @during_shift DateTime.add(@now, 2, :hour)

  setup do
    real_connections()
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)
  end

  ## Own-message copies

  describe "own-message copies" do
    test "are deleted on their stamped deadline and not before it" do
      %{person: person, copies: [copy | _]} = history_with_archive()

      due = copy.delete_after

      assert {:ok, run} = Lifecycle.sweep(due)
      assert run.own_message_copies == 0
      assert Lifecycle.list_retained_messages(person_at(person, due)) != []

      after_due = DateTime.add(due, 1, :second)

      assert {:ok, run} = Lifecycle.sweep(after_due)
      assert run.own_message_copies == 2
      assert Lifecycle.list_retained_messages(person_at(person, after_due)) == []
    end

    test "are unaffected by an engagement end backdated after the stamp" do
      # The unit's central claim. `delete_after` came from the engagement's
      # closed upper bound at the moment the copy was written; moving that bound
      # into the distant past afterwards must not move the deadline, because a
      # deleter that joined the period would destroy this worker's archive on
      # the next unattended run.
      %{person: person, engagement: engagement, copies: [copy | _]} = history_with_archive()

      backdate_engagement(engagement.id, DateTime.add(@now, -400, :day))

      just_before = DateTime.add(copy.delete_after, -1, :second)

      assert {:ok, run} = Lifecycle.sweep(just_before)
      assert run.own_message_copies == 0
      assert length(Lifecycle.list_retained_messages(person_at(person, just_before))) == 2
    end

    test "survive the venue's own copy of the same message being deleted" do
      # KTD16's reason for physically separate rows, made observable: thirty
      # days for the venue's shift history, ninety for the worker's archive of
      # the same words.
      %{person: person, shift_message: message} = history_with_archive()

      at = DateTime.add(@shift_closes, 31, :day)

      assert {:ok, run} = Lifecycle.sweep(at)
      assert run.shift_messages == 1
      assert Repo.get(RoomMessage, message.id) == nil

      bodies =
        person
        |> person_at(at)
        |> Lifecycle.list_retained_messages()
        |> Enum.map(& &1.body)

      assert "on the shift" in bodies
    end

    test "are written when the expiry is announced, once per message" do
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      Clock.Offset.set(@after_the_end)

      assert {:ok, :revoked} = perform_job(ExpireEngagement, expiry_args(engagement))
      assert length(Lifecycle.list_retained_messages(person_at(person, @after_the_end))) == 1

      assert {:ok, :revoked} = perform_job(ExpireEngagement, expiry_args(engagement))
      assert length(Lifecycle.list_retained_messages(person_at(person, @after_the_end))) == 1
    end

    test "are not written while the term is still open" do
      # The control for the test above: an announcement that archived
      # unconditionally would satisfy it, and would archive a working
      # engagement's messages every five minutes for as long as the sweeper ran.
      %{employer: employer, person: person, engagement: engagement} = engaged()

      {:ok, _} =
        Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "hello")

      assert {:ok, :still_active} = perform_job(ExpireEngagement, expiry_args(engagement))
      assert Lifecycle.list_retained_messages(person_at(person, @now)) == []
    end
  end

  ## Shift history

  describe "shift history" do
    test "deletes messages and roster entries on the shift's clock" do
      %{shift_message: message, entry: entry} = history()

      due = DateTime.add(@shift_closes, Lifecycle.history_retention_days(), :day)

      assert {:ok, run} = Lifecycle.sweep(due)
      assert {run.shift_messages, run.roster_entries} == {0, 0}
      assert Repo.get(RoomMessage, message.id)
      assert Repo.get(RosterEntry, entry.id)

      assert {:ok, run} = Lifecycle.sweep(DateTime.add(due, 1, :second))
      assert {run.shift_messages, run.roster_entries} == {1, 1}
      assert Repo.get(RoomMessage, message.id) == nil
      assert Repo.get(RosterEntry, entry.id) == nil
    end

    test "is unaffected by a shift room's term moved after the stamp" do
      %{room: room, shift_message: message, entry: entry} = history()

      backdate_shift_room(room.id, DateTime.add(@now, -400, :day))

      at = DateTime.add(@now, -300, :day)

      assert {:ok, run} = Lifecycle.sweep(at)
      assert {run.shift_messages, run.roster_entries} == {0, 0}
      assert Repo.get(RoomMessage, message.id)
      assert Repo.get(RosterEntry, entry.id)
    end
  end

  ## Venue-room history

  describe "venue-room history" do
    test "survives every sweep while the venue is open" do
      %{venue_message: message} = history()

      assert {:ok, run} = Lifecycle.sweep(DateTime.add(@now, 3650, :day))
      assert run.venue_room_messages == 0
      assert Repo.get(RoomMessage, message.id)
    end

    test "is deleted thirty days after the venue closes" do
      %{employer: employer, venue_message: message} = history()

      closed_at = DateTime.add(@now, 100, :day)
      assert {:ok, %{messages_stamped: 1}} = Lifecycle.close_venue(employer.venue_id, closed_at)

      due = DateTime.add(closed_at, Lifecycle.history_retention_days(), :day)

      assert {:ok, run} = Lifecycle.sweep(due)
      assert run.venue_room_messages == 0
      assert Repo.get(RoomMessage, message.id)

      assert {:ok, run} = Lifecycle.sweep(DateTime.add(due, 1, :second))
      assert run.venue_room_messages == 1
      assert Repo.get(RoomMessage, message.id) == nil
    end

    test "closing a venue stamps only the deadlines that were null" do
      # The control that makes the test above about *nullness* rather than about
      # the window: a closure that stamped every message would move a shift
      # message's already-fixed deadline, and the shorter of the two would win —
      # which is the failure KTD16 rejects one table over.
      %{employer: employer, shift_message: message} = history()

      stamped = Repo.get!(RoomMessage, message.id).delete_after

      assert {:ok, %{messages_stamped: 1}} =
               Lifecycle.close_venue(employer.venue_id, DateTime.add(@now, 100, :day))

      assert DateTime.compare(Repo.get!(RoomMessage, message.id).delete_after, stamped) == :eq
    end
  end

  ## The ceiling

  describe "the blast-radius ceiling" do
    test "rolls every trigger back, not only the one that overflowed" do
      %{shift_message: message, entry: entry, person: person} = history_with_archive()

      at = DateTime.add(@shift_closes, 3650, :day)

      assert {:ok, run} = with_limits([ceiling: 1], fn -> Lifecycle.sweep(at) end)

      assert run.outcome == :refused
      assert Repo.get(RoomMessage, message.id)
      assert Repo.get(RosterEntry, entry.id)
      assert Lifecycle.list_retained_messages(person_at(person, at)) != []
    end

    test "records what it would have deleted" do
      %{} = history_with_archive()

      at = DateTime.add(@shift_closes, 3650, :day)

      assert {:ok, run} = with_limits([ceiling: 1], fn -> Lifecycle.sweep(at) end)

      assert run.ceiling == 1
      assert run.shift_messages == 1
      assert run.roster_entries == 1
      assert run.own_message_copies == 2
      assert Repo.get(RetentionRun, run.id).outcome == :refused
    end

    test "permits a run at exactly the ceiling" do
      # The control: a guard that always rolled back satisfies both tests above.
      %{shift_message: message} = history()

      at = DateTime.add(@shift_closes, 3650, :day)

      assert {:ok, run} = with_limits([ceiling: 2], fn -> Lifecycle.sweep(at) end)

      assert run.outcome == :completed
      assert run.shift_messages + run.roster_entries == 2
      assert Repo.get(RoomMessage, message.id) == nil
    end
  end

  ## The record, and the bound

  describe "every run" do
    test "writes a record carrying the instant it used and the four counts" do
      %{} = history()

      at = DateTime.add(@shift_closes, 3650, :day)

      assert {:ok, run} = Lifecycle.sweep(at)

      assert DateTime.compare(run.ran_at, DateTime.truncate(at, :second)) == :eq
      assert run.outcome == :completed
      assert run.shift_messages == 1
      assert run.roster_entries == 1
      assert run.venue_room_messages == 0
      assert run.own_message_copies == 0
    end

    test "writes one even when nothing is due" do
      # A recorded zero and no record at all are different facts, and only one
      # of them says the deleter ran.
      before = Repo.aggregate(RetentionRun, :count)

      assert {:ok, run} = Lifecycle.sweep(@now)
      assert run.shift_messages == 0
      assert Repo.aggregate(RetentionRun, :count) == before + 1
    end

    test "deletes at most one batch per trigger and finishes on the next run" do
      %{person: person} = history_with_archive()

      at = DateTime.add(@in_a_month, 3650, :day)

      assert {:ok, run} = with_limits([batch_size: 1], fn -> Lifecycle.sweep(at) end)
      assert run.own_message_copies == 1
      assert length(Lifecycle.list_retained_messages(person_at(person, at))) == 1

      assert {:ok, run} = with_limits([batch_size: 1], fn -> Lifecycle.sweep(at) end)
      assert run.own_message_copies == 1
      assert Lifecycle.list_retained_messages(person_at(person, at)) == []
    end

    test "takes its instant from the clock when the worker drives it" do
      # KTD5 at a new unit-of-work boundary. Moving the offset moves the sweep,
      # with nothing else changing — which is also what U11's demo control needs.
      %{shift_message: message} = history()

      Clock.Offset.set(@now)
      assert {:ok, %RetentionRun{shift_messages: 0}} = perform_job(RetentionSweeper, %{})
      assert Repo.get(RoomMessage, message.id)

      Clock.Offset.set(DateTime.add(@shift_closes, 3650, :day))
      assert {:ok, %RetentionRun{shift_messages: 1}} = perform_job(RetentionSweeper, %{})
      assert Repo.get(RoomMessage, message.id) == nil
    end
  end

  ## Helpers

  defp person_at(%PersonScope{person: %Person{} = person}, %DateTime{} = instant) do
    PersonScope.for_person(person, instant)
  end

  defp expiry_args(%Engagement{} = engagement) do
    %{
      "engagement_id" => engagement.id,
      "venue_id" => engagement.venue_id,
      "ends_at" => DateTime.to_iso8601(engagement.ends_at)
    }
  end

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

  # One venue-room message with no deadline, one shift-room message and one
  # roster entry on the shift's clock. The shape every trigger needs.
  defp history do
    %{employer: employer, person: person, engagement: engagement} = engaged()

    shift_type = shift_type_fixture(employer, @grace_minutes)
    room = shift_room_fixture(employer, shift_type, @shift_starts, @shift_ends)
    entry = Rosters.add_to_roster(employer, room.id, engagement.id) |> unwrap()

    {:ok, venue_message} =
      Rooms.send_venue_room_message(person_at(person, @now), employer.venue_id, "in the venue")

    {:ok, shift_message} =
      Rooms.send_shift_room_message(person_at(person, @during_shift), room.id, "on the shift")

    %{
      employer: employer,
      person: person,
      engagement: engagement,
      room: room,
      entry: entry,
      venue_message: venue_message,
      shift_message: shift_message
    }
  end

  # …plus the worker's archive of both, written when the term closed.
  defp history_with_archive do
    context = history()

    {:ok, 2} = Lifecycle.retain_own_messages(context.engagement.id, @after_the_end)

    copies =
      Repo.all(
        from(c in RetainedMessageCopy,
          where: c.engagement_id == ^context.engagement.id,
          order_by: [asc: c.sent_at, asc: c.id]
        )
      )

    Map.put(context, :copies, copies)
  end

  defp unwrap({:ok, value}), do: value

  # Stands in for a backdating path the application does not expose. See the
  # moduledoc: the deadline is stamped precisely so that whether one exists
  # later is not a question the deleter's correctness depends on.
  defp backdate_engagement(engagement_id, instant) do
    Repo.update_all(
      from(e in Engagement, where: e.id == ^engagement_id),
      set: [
        starts_at: DateTime.add(instant, -1, :day) |> DateTime.truncate(:second),
        ends_at: DateTime.truncate(instant, :second)
      ]
    )
  end

  defp backdate_shift_room(room_id, instant) do
    Repo.update_all(
      from(r in ShiftRoom, where: r.id == ^room_id),
      set: [
        starts_at: DateTime.add(instant, -8, :hour) |> DateTime.truncate(:second),
        ends_at: DateTime.truncate(instant, :second)
      ]
    )
  end

  defp with_limits(opts, fun) do
    previous = Application.get_env(:hospitality_coms, Lifecycle, [])
    Application.put_env(:hospitality_coms, Lifecycle, Keyword.merge(previous, opts))

    try do
      fun.()
    after
      Application.put_env(:hospitality_coms, Lifecycle, previous)
    end
  end
end
