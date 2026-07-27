defmodule HospitalityComs.Workers.EngagementSweeperTest do
  @moduledoc """
  The two workers, and the one thing both of them must not do.

  Correctness does not depend on either of these running: an engagement is
  active when the unit of work's instant falls in its term, so the request after
  an expiry is refused whether or not anything swept.
  `HospitalityComs.EngagementsTest` asserts that directly, with the job sitting
  unexecuted while the membership query changes its answer. What is asserted
  here is the liveness half — that somebody is told — and the constraint that
  makes it safe.

  ## The constraint is the absence of a write

  `HospitalityComs.Workers.ExpireEngagement` re-derives activeness and
  broadcasts; it never touches `engagements`. Every test below that runs the
  worker reloads the row afterwards and asserts it is byte-for-byte what it was,
  because the failure this prevents is invisible otherwise: a job scheduled for
  an upper bound that a renewal has since moved, firing late and truncating a
  renewed term — a revocation caused by a queue's latency and nothing a manager
  did.

  That is also why nothing has to cancel a stale job. The test for it does not
  assert that the job was removed; it asserts that running it changes nothing.

  ## Idempotence is Oban's

  Nothing marks an engagement swept, because nothing may write on this path. Two
  sweeps produce one revocation because the second `Oban.insert/1` conflicts on
  `[:worker, :args]` across every state, and the args carry the term's upper
  bound — so a renewal produces a *different* job rather than being suppressed
  by the last one. Both halves are asserted, because the first without the
  second is a sweeper that goes permanently quiet after one run.

  ## Why the clock is set rather than waited for

  `HospitalityComs.Clock.Offset` is global and process-independent, which is
  what lets a worker running in its own process see the instant a test chose.
  It is also why this file is `async: false` and resets the clock on exit.

  Jobs never execute on their own here: `config/test.exs` sets Oban's
  `testing: :manual`, so the queue is empty of runners and every worker in this
  file is invoked directly by `Oban.Testing.perform_job/2`. A job that ran for
  real would run on a process the sandbox never lent a connection to, at an
  instant this file did not choose.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: HospitalityComs.Repo

  import Ecto.Query
  import HospitalityComs.EngagementsFixtures

  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Repo
  alias HospitalityComs.Workers.EngagementSweeper
  alias HospitalityComs.Workers.ExpireEngagement

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_month DateTime.add(@now, 30, :day)
  @in_two_months DateTime.add(@now, 60, :day)

  # Inside the sweep's lookback window rather than merely after the term, which
  # are different things now that the window has a lower edge. An instant a day
  # and a half past the upper bound is past expiry *and* past the window, and a
  # test that used one would be asserting the lookback while claiming to assert
  # the sweep.
  @after_expiry DateTime.add(@in_a_month, 1, :hour)

  # After every term `ended_engagements/4` writes and well inside the lookback,
  # so the whole batch is in one window.
  @sweep_at DateTime.add(@now, 12, :hour)

  setup do
    real_connections()
    Clock.Offset.set(@now)
    on_exit(&Clock.Offset.reset/0)
    :ok
  end

  describe "ExpireEngagement" do
    test "broadcasts once the term no longer contains the instant" do
      engagement = expired_engagement()
      :ok = Engagements.subscribe(engagement.id)

      Clock.Offset.set(@after_expiry)

      assert perform_job(ExpireEngagement, args_for(engagement)) == {:ok, :revoked}
      assert_receive {:engagement_revoked, %{engagement_id: id, venue_id: venue_id}}

      assert id == engagement.id
      assert venue_id == engagement.venue_id
    end

    test "writes nothing to the engagement it announces" do
      # The contract, asserted as the absence it is. `updated_at` and
      # `lock_version` are the two columns a write of any kind would move.
      engagement = expired_engagement()

      Clock.Offset.set(@after_expiry)
      assert perform_job(ExpireEngagement, args_for(engagement)) == {:ok, :revoked}

      assert reloaded(engagement) == engagement
    end

    test "does nothing at all while the term still contains the instant" do
      # The control for the broadcast above: a worker that announced
      # unconditionally would pass every other test in this block.
      engagement = expired_engagement()
      :ok = Engagements.subscribe(engagement.id)

      Clock.Offset.set(@now)

      assert perform_job(ExpireEngagement, args_for(engagement)) == {:ok, :still_active}
      refute_receive {:engagement_revoked, _payload}
    end

    test "leaves a renewed engagement untouched when it fires late" do
      # The failure this whole design is arranged around. The job was scheduled
      # for the *old* upper bound and is delivered after a renewal moved it; a
      # worker that wrote anything would truncate the renewed term, revoking a
      # person's access because a queue was slow.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      stale = args_for(engagement)

      {:ok, renewed} = Engagements.renew_engagement(employer, engagement.id, @in_two_months)
      :ok = Engagements.subscribe(engagement.id)

      Clock.Offset.set(@after_expiry)

      assert perform_job(ExpireEngagement, stale) == {:ok, :still_active}
      refute_receive {:engagement_revoked, _payload}

      assert reloaded(engagement) == renewed
      assert DateTime.compare(reloaded(engagement).ends_at, @in_two_months) == :eq

      # And the person is still a member at the instant the stale job named.
      later = PersonScope.for_person(scope.person, @after_expiry)
      assert Enum.map(Engagements.list_person_engagements(later), & &1.id) == [engagement.id]
    end

    test "reports an engagement that no longer exists rather than failing" do
      # A job outliving its row is the ordinary end of an erasure (U10), not an
      # error worth retrying three times.
      Clock.Offset.set(@after_expiry)

      args = %{
        "engagement_id" => Ecto.UUID.generate(),
        "venue_id" => Ecto.UUID.generate(),
        "ends_at" => DateTime.to_iso8601(@in_a_month)
      }

      assert perform_job(ExpireEngagement, args) == {:ok, :gone}
    end

    test "carries no person in the args it is scheduled with" do
      engagement = expired_engagement()
      changeset = ExpireEngagement.schedule_for(engagement)
      args = Ecto.Changeset.get_field(changeset, :args)

      refute Enum.any?(Map.keys(args), &(&1 |> to_string() |> String.contains?("person")))
      refute engagement.person_id in Map.values(args)
    end
  end

  describe "EngagementSweeper" do
    test "enqueues one announcement for an expired engagement" do
      # The control for the idempotence test below: a sweeper that enqueued
      # nothing would satisfy "two runs produce one revocation" trivially.
      engagement = expired_engagement()
      discard_scheduled_jobs()

      Clock.Offset.set(@after_expiry)
      assert {:ok, %{enqueued: _count}} = perform_job(EngagementSweeper, %{})

      assert length(announcements_for(engagement)) == 1
    end

    test "running twice over one expired engagement produces one revocation" do
      engagement = expired_engagement()
      discard_scheduled_jobs()

      Clock.Offset.set(@after_expiry)
      assert {:ok, _first} = perform_job(EngagementSweeper, %{})
      assert {:ok, second} = perform_job(EngagementSweeper, %{})

      assert length(announcements_for(engagement)) == 1
      assert second.enqueued == 0
    end

    test "adds nothing when the claim already scheduled the announcement" do
      # The ordinary case, and the reason the sweeper is a backstop rather than
      # the mechanism: the job it would insert is the one the claim already
      # inserted, down to the args, so Oban's uniqueness suppresses it.
      engagement = expired_engagement()

      assert length(announcements_for(engagement)) == 1

      Clock.Offset.set(@after_expiry)
      assert {:ok, %{enqueued: 0}} = perform_job(EngagementSweeper, %{})

      assert length(announcements_for(engagement)) == 1
    end

    test "enqueues again for the next expiry after a renewal" do
      # The half that uniqueness would otherwise break. Suppressing on
      # `engagement_id` alone would make the sweeper permanently silent about
      # an engagement it had already announced once; the term's upper bound is
      # in the args so that a renewal produces a different job.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      {:ok, renewed} = Engagements.renew_engagement(employer, engagement.id, @in_two_months)

      # One announcement so far, for the term the claim scheduled against.
      assert bounds_announced_for(engagement) == [DateTime.to_iso8601(engagement.ends_at)]

      Clock.Offset.set(DateTime.add(@in_two_months, 1, :hour))
      assert {:ok, %{enqueued: enqueued}} = perform_job(EngagementSweeper, %{})

      assert enqueued >= 1

      assert bounds_announced_for(engagement) ==
               Enum.sort([
                 DateTime.to_iso8601(engagement.ends_at),
                 DateTime.to_iso8601(renewed.ends_at)
               ])
    end

    test "leaves an engagement that has not expired alone" do
      engagement = expired_engagement()
      discard_scheduled_jobs()

      Clock.Offset.set(@now)
      assert {:ok, %{enqueued: 0}} = perform_job(EngagementSweeper, %{})

      assert announcements_for(engagement) == []
    end

    test "writes nothing to the engagements it sweeps" do
      engagement = expired_engagement()
      discard_scheduled_jobs()

      Clock.Offset.set(@after_expiry)
      assert {:ok, _swept} = perform_job(EngagementSweeper, %{})

      assert reloaded(engagement) == engagement
    end

    test "enqueues again once the announcement it made was discarded" do
      # The trap the uniqueness rule used to set for itself. Spanning *every*
      # job state means a job that exhausted its attempts and reached
      # `:discarded` suppresses its own replacement for ever — and suppresses
      # the sweeper's identical insert too, so the backstop cannot substitute
      # for the mechanism it exists to back up.
      #
      # `discard_scheduled_jobs/0` deletes, which is a purge rather than a
      # failure; this leaves the row where a failed job leaves it.
      engagement = expired_engagement()
      move_announcements_to("discarded")

      Clock.Offset.set(@after_expiry)
      assert {:ok, %{enqueued: 1}} = perform_job(EngagementSweeper, %{})

      # `all_enqueued/1` only sees runnable states, so this counts the
      # replacement and not the job it replaced.
      assert length(announcements_for(engagement)) == 1
    end

    test "enqueues again once the announcement it made was cancelled" do
      engagement = expired_engagement()
      move_announcements_to("cancelled")

      Clock.Offset.set(@after_expiry)
      assert {:ok, %{enqueued: 1}} = perform_job(EngagementSweeper, %{})
      assert length(announcements_for(engagement)) == 1
    end

    test "adds nothing once the announcement it made has completed" do
      # The control for the two above, and the reason the uniqueness states are
      # "every state except the terminal failures" rather than Oban's
      # `:incomplete`. Under `:incomplete` a *completed* announcement stops
      # suppressing too, and every expired engagement inside the sweep's window
      # is re-announced on every five-minute tick.
      engagement = expired_engagement()
      move_announcements_to("completed")

      Clock.Offset.set(@after_expiry)
      assert {:ok, %{enqueued: 0}} = perform_job(EngagementSweeper, %{})
      assert announcements_for(engagement) == []
    end

    test "reports an insert it could not make separately from one it did not need" do
      # `conflict?` and `{:error, changeset}` used to collapse into the same
      # `false`, so a sweep whose every insert failed reported the same
      # `enqueued: 0` as a sweep that had nothing to do.
      engagement = expired_engagement()

      Clock.Offset.set(@after_expiry)
      assert {:ok, tally} = perform_job(EngagementSweeper, %{})

      assert tally.swept == 1
      assert tally.enqueued == 0
      assert tally.suppressed == 1
      assert tally.failed == 0
      assert length(announcements_for(engagement)) == 1
    end
  end

  describe "the sweep's window" do
    test "reaches terms that closed after a whole batch of older ones" do
      # The stall. Ordered oldest-first under a limit, the sweep examines the
      # same `batch_size/0` rows on every tick once that many terms have ever
      # closed, and never reaches one that closed this morning — while
      # continuing to run and to report success.
      %{venue: venue, grant: grant} = venue_fixture(@now)
      person = person_fixture(@now)
      count = EngagementSweeper.batch_size() + 1

      ids = ended_engagements(venue, grant, person, count)
      newest = List.last(ids)

      swept =
        Engagements.list_expired(
          @sweep_at,
          EngagementSweeper.lookback_from(@sweep_at),
          EngagementSweeper.batch_size()
        )

      assert length(swept) == EngagementSweeper.batch_size()
      assert newest in Enum.map(swept, & &1.id)
    end

    test "leaves out a term that closed before the window opened" do
      # The other half of the bound. A window with no lower edge is the
      # unbounded scan the limit was supposed to replace.
      %{venue: venue, grant: grant} = venue_fixture(@now)
      person = person_fixture(@now)

      [ancient, recent] = ended_engagements(venue, grant, person, 2)

      since = DateTime.add(@now, 60, :second)
      swept = @sweep_at |> Engagements.list_expired(since, 10) |> Enum.map(& &1.id)

      assert recent in swept
      refute ancient in swept
    end

    test "sweeps nothing at all once every term is older than the lookback" do
      engagement = expired_engagement()
      discard_scheduled_jobs()

      Clock.Offset.set(DateTime.add(@in_a_month, 2, :day))
      assert {:ok, %{swept: 0, enqueued: 0}} = perform_job(EngagementSweeper, %{})

      assert announcements_for(engagement) == []

      # The control: a day earlier the same term is inside the window, so the
      # silence above is the lookback rather than the sweep being broken.
      Clock.Offset.set(@after_expiry)
      assert {:ok, %{swept: 1, enqueued: 1}} = perform_job(EngagementSweeper, %{})
    end
  end

  ## Helpers

  # An engagement whose term has closed by `@after_expiry`, created through the
  # context so that the job the claim schedules exists exactly as it would in
  # production.
  defp expired_engagement do
    {employer, _creation} = scoped_venue_fixture(@now)

    engagement_fixture(employer, person_scope_fixture(@now), %{
      starts_at: @now,
      ends_at: @in_a_month
    })
  end

  defp args_for(%Engagement{} = engagement) do
    %{
      "engagement_id" => engagement.id,
      "venue_id" => engagement.venue_id,
      "ends_at" => DateTime.to_iso8601(engagement.ends_at)
    }
  end

  # The announcements queued for one engagement at one particular upper bound,
  # which is what "one revocation" counts.
  defp announcements_for(%Engagement{} = engagement) do
    Enum.filter(all_enqueued(worker: ExpireEngagement), fn job ->
      job.args["engagement_id"] == engagement.id
    end)
  end

  # The upper bounds one engagement has had an announcement queued for. Two
  # entries means the renewal produced a second job rather than being suppressed
  # by the first, which is the property `ends_at`-in-the-args exists for.
  defp bounds_announced_for(%Engagement{} = engagement) do
    engagement |> announcements_for() |> Enum.map(& &1.args["ends_at"]) |> Enum.sort()
  end

  # The claim schedules an announcement of its own, which is the ordinary case.
  # The sweeper's job is the one that covers a lost one, so a test about the
  # sweeper has to lose it first.
  defp discard_scheduled_jobs do
    Repo.query!("DELETE FROM oban_jobs WHERE worker = $1", [inspect(ExpireEngagement)])
  end

  # Deleting a job is a purge and not a failure, so it proves the backstop only
  # against a row that is gone. These are the states a job actually reaches:
  # `discarded` when it exhausts its attempts, `cancelled` when somebody stops
  # it, `completed` when it worked. The uniqueness rule has to treat the first
  # two differently from the third and nothing said so until now.
  defp move_announcements_to(state) do
    Repo.query!(
      "UPDATE oban_jobs SET state = $1, completed_at = now() WHERE worker = $2",
      [state, inspect(ExpireEngagement)]
    )
  end

  # `count` engagements whose terms have all closed, packed a minute apart so
  # that more than a whole batch of them fits inside the sweep's lookback.
  #
  # Written with two `insert_all`s rather than `count` claims: the exclusion
  # constraint keys on `(person_id, venue_id, period)` and these terms do not
  # overlap, so one person at one venue is enough, and 501 claims through the
  # context would be 501 transactions to prove one ordering.
  defp ended_engagements(venue, grant, person, count) do
    stamped_at = DateTime.truncate(@now, :second)

    terms =
      Enum.map(0..(count - 1), fn index ->
        starts_at = DateTime.add(stamped_at, index * 60, :second)

        %{
          id: Ecto.UUID.generate(),
          invitation_id: Ecto.UUID.generate(),
          starts_at: starts_at,
          ends_at: DateTime.add(starts_at, 30, :second)
        }
      end)

    Repo.insert_all(Invitation, Enum.map(terms, &invitation_row(&1, venue, grant, stamped_at)))
    Repo.insert_all(Engagement, Enum.map(terms, &engagement_row(&1, venue, person, stamped_at)))

    Enum.map(terms, & &1.id)
  end

  defp invitation_row(term, venue, grant, stamped_at) do
    %{
      id: term.invitation_id,
      venue_id: venue.id,
      issued_by_grant_id: grant.id,
      role_label: "Bartender",
      starts_at: term.starts_at,
      ends_at: term.ends_at,
      claim_code_digest: :crypto.strong_rand_bytes(32),
      code_expires_at: DateTime.add(stamped_at, 1, :day),
      issued_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    }
  end

  defp engagement_row(term, venue, person, stamped_at) do
    %{
      id: term.id,
      person_id: person.id,
      venue_id: venue.id,
      invitation_id: term.invitation_id,
      role_label: "Bartender",
      starts_at: term.starts_at,
      ends_at: term.ends_at,
      accepted_at: stamped_at,
      lock_version: 0,
      inserted_at: stamped_at,
      updated_at: stamped_at
    }
  end

  defp reloaded(%Engagement{id: id}), do: Repo.one!(from e in Engagement, where: e.id == ^id)
end
