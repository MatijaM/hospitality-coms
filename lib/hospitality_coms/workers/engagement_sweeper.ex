defmodule HospitalityComs.Workers.EngagementSweeper do
  @moduledoc """
  The periodic half of KTD6: a backstop for expiry jobs that never arrived.

  Correctness does not depend on this running. An engagement is active when the
  unit of work's instant falls in its term, so the request after an expiry is
  refused whether or not anything swept — the sweeper is a *liveness* mechanism,
  and if it is late the only consequence is that an already-powerless socket
  stays open a while longer. That is a bounded liveness bug rather than a data
  leak, which is why the plan is content to have one at all.

  What it covers is the gap the scheduled job cannot: a claim whose job was
  purged, an engagement written by seeds, a queue that was drained during an
  incident. It finds terms that have closed and inserts *the same*
  `HospitalityComs.Workers.ExpireEngagement` changeset the claim would have
  inserted — identical args, so Oban's uniqueness makes the ordinary case a
  no-op rather than a second revocation.

  ## Idempotence is Oban's, not a column's

  Nothing here marks an engagement swept, because nothing in this unit may write
  to `engagements` on an expiry path (see `ExpireEngagement`). Two runs over one
  expired engagement produce one revocation because the second insert conflicts
  on `[:worker, :args]` across every job state with `period: :infinity`, and the
  args are `{engagement_id, venue_id, ends_at}`. A renewal changes `ends_at`, so
  the *next* expiry of the same engagement is a different job and is not
  suppressed by the last one.

  ## It sees every venue, which is the point and the limit

  The sweeper is the application acting for itself rather than for an employer,
  so it reads through `HospitalityComs.Repo` and is scoped to no venue. No
  employer session can do this, and that asymmetry is why the sweep lives in a
  worker rather than behind an endpoint.

  Bounded to `batch_size/0` per run. An unattended query over a table that grows
  with every engagement ever held is a query that eventually stops finishing,
  and a run that finds a full batch will find the rest on the next tick.

  ## The instant is this run's

  One job attempt is one unit of work (KTD5), which is why this module is in
  `.credo.exs`'s `:boundary_modules` alongside `ExpireEngagement` and the HTTP
  boundary.
  """

  use Oban.Worker,
    queue: :engagements,
    max_attempts: 3,
    # One sweep in flight at a time. `:incomplete` is Oban's name for every
    # state a job can still run from, which is the set that matters: two sweeps
    # overlapping would do the same work twice and get the same answer, since
    # the insert each of them attempts is itself idempotent.
    unique: [period: 60, states: :incomplete]

  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Workers.ExpireEngagement

  @batch_size 500

  @doc """
  How many expired engagements one run will look at.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc """
  Enqueues an expiry announcement for every term that has closed.

  Returns the number swept and the number of jobs the insert actually created —
  the difference is Oban's uniqueness suppressing work that was already
  scheduled or already done, which is the ordinary case rather than the
  exception.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, %{swept: non_neg_integer(), enqueued: non_neg_integer()}}
  def perform(%Oban.Job{}) do
    expired = Clock.now() |> Engagements.list_expired(@batch_size)

    {:ok, %{swept: length(expired), enqueued: Enum.count(expired, &enqueue/1)}}
  end

  # `conflict?` is Oban's way of saying the uniqueness rule matched an existing
  # job and this insert produced nothing. It is counted rather than logged
  # because it is the measure of the sweeper doing no harm.
  @spec enqueue(Engagement.t()) :: boolean()
  defp enqueue(%Engagement{} = engagement) do
    engagement |> ExpireEngagement.schedule_for() |> Oban.insert() |> inserted?()
  end

  @spec inserted?({:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t(Oban.Job.t())}) :: boolean()
  defp inserted?({:ok, %Oban.Job{conflict?: conflict?}}), do: not conflict?
  defp inserted?({:error, _changeset}), do: false
end
