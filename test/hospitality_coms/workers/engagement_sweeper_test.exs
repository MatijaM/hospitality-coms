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
  alias HospitalityComs.Repo
  alias HospitalityComs.Workers.EngagementSweeper
  alias HospitalityComs.Workers.ExpireEngagement

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_month DateTime.add(@now, 30, :day)
  @in_two_months DateTime.add(@now, 60, :day)
  @after_expiry DateTime.add(@in_a_month, 1, :day)

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

      Clock.Offset.set(DateTime.add(@in_two_months, 1, :day))
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

  defp reloaded(%Engagement{id: id}), do: Repo.one!(from e in Engagement, where: e.id == ^id)
end
