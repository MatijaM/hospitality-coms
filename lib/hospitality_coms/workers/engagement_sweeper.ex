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
  on `[:worker, :args]` with `period: :infinity`, and the args are
  `{engagement_id, venue_id, ends_at}`. A renewal changes `ends_at`, so the
  *next* expiry of the same engagement is a different job and is not suppressed
  by the last one.

  The uniqueness spans every job state except `:discarded` and `:cancelled`, and
  those two exclusions are what make this a backstop at all — see
  `ExpireEngagement`. A job that failed permanently used to suppress this
  sweeper's replacement for it.

  ## What it does cover, and the one thing it does not

  It covers more than the moduledoc above claims, and the extra case is worth
  naming because a reviewer looked for it and concluded it was missing.

  **A crash between `Engagements.end_engagement/2`'s commit and its broadcast is
  recovered by this sweep.** Closing a term rewrites `ends_at` to the closing
  instant, so the engagement lands inside this window; and `ends_at` is one of
  `ExpireEngagement`'s uniqueness args, so the insert does not collide with the
  job scheduled for the term's *original* upper bound. The same is true of a
  broadcast that was simply lost — including the one U7 records against
  `HospitalityComsWeb.VenueRoomChannel`, where a channel subscribes a statement
  after the read that admitted it and can therefore miss the first announcement.
  Worst case is one tick, five minutes.

  **The gap is the second loss, and it is permanent.** Once this sweep's
  `ExpireEngagement` job completes, `period: :infinity` over a state list that
  keeps `:completed` means every later insert with those args is suppressed for
  as long as `Oban.Plugins.Pruner` keeps the row. So if *that* announcement is
  also lost — the broadcast reaches no subscriber, or the node holding them
  drops between the commit and the delivery — nothing announces the expiry
  again. The engagement stays outside its term for ever and no socket is ever
  told.

  That is survivable for the reason at the top of this file: correctness does
  not depend on the announcement. The rejoin is refused whether or not anything
  swept, so what is lost is a socket noticing promptly rather than a socket
  keeping access. It is written down because "the sweeper is the backstop" reads
  like the backstop has no bottom, and it has one.

  ## It sees every venue, which is the point and the limit

  The sweeper is the application acting for itself rather than for an employer,
  so it reads through `HospitalityComs.Repo` and is scoped to no venue. No
  employer session can do this, and that asymmetry is why the sweep lives in a
  worker rather than behind an endpoint.

  ## The window moves, and a limit alone would not have

  Bounded to `batch_size/0` per run, over the terms that closed in the last
  `@lookback_seconds`. Both bounds are load bearing and the second is the one
  that is easy to leave out: `ends_at <= now` matches every term that ever
  closed, so a limit on its own pins the sweep to the same oldest rows for ever
  once more than a batch of engagements have ended — it keeps running, keeps
  reporting success, and never reaches a term that closed this morning. The
  lower bound and the newest-first ordering are what make "a run that finds a
  full batch will find the rest on the next tick" true rather than aspirational.

  ## The instant is this run's, and Oban's is not

  One job attempt is one unit of work (KTD5), which is why this module is in
  `.credo.exs`'s `:boundary_modules` alongside `ExpireEngagement` and the HTTP
  boundary. `Clock.now/0` is what decides the window, so moving
  `HospitalityComs.Clock.Offset` moves the sweep.

  **It does not move Oban.** Oban's staging query asks
  `scheduled_at <= DateTime.utc_now()` inside its own engine, against the real
  wall clock, and no injected clock reaches it. So advancing the offset changes
  every membership query in the application instantly while a job scheduled for
  a future upper bound still waits for real time to arrive. Running a worker
  through `Oban.Testing.perform_job/2` — which is what the suite does — steps
  around it; a demo that advanced the clock and waited for the queue would not.
  U11's demo controls have to drive the sweep directly for that reason.
  """

  use Oban.Worker,
    queue: :engagements,
    max_attempts: 3,
    # One sweep in flight at a time. `:incomplete` is Oban's name for every
    # state a job can still run from, which is the set that matters: two sweeps
    # overlapping would do the same work twice and get the same answer, since
    # the insert each of them attempts is itself idempotent.
    unique: [period: 60, states: :incomplete]

  require Logger

  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Workers.ExpireEngagement

  @batch_size 500

  # How far back one run looks. The cron entry is every five minutes, so this is
  # that interval plus a very generous outage: a day of the queue being down,
  # or of this worker failing every attempt, still leaves every term that closed
  # in the meantime inside the window of the first run that succeeds.
  #
  # **The assumption is that nothing needs announcing after a day.** A term that
  # closed longer ago than this is never swept again, and that is deliberate
  # rather than an oversight: correctness does not depend on the announcement at
  # all — the request after an expiry is refused whether or not anything ran —
  # and the only thing the announcement buys is that a socket which is already
  # powerless notices. A socket that has been open for a day past its
  # engagement's upper bound is not a case worth keeping an unbounded scan for.
  #
  # It must also stay comfortably *shorter* than `Oban.Plugins.Pruner`'s
  # `max_age` in `config/config.exs`. The completed announcement is what stops
  # the sweep re-announcing the same expiry every five minutes, and a pruner
  # that removed it while the term was still inside this window would do exactly
  # that.
  @lookback_seconds 24 * 60 * 60

  @doc """
  How many expired engagements one run will look at.
  """
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @typedoc """
  What one run did, by outcome. `swept` is the size of the window's batch, and
  the other three add up to it.

  `suppressed` and `failed` are counted apart on purpose. Collapsed into one
  "not enqueued" they read identically, and they mean opposite things: a
  suppressed insert is the sweeper doing no harm on the ordinary path, and a
  failed one is the backstop not working.
  """
  @type sweep() :: %{
          swept: non_neg_integer(),
          enqueued: non_neg_integer(),
          suppressed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Enqueues an expiry announcement for every term that closed inside the window.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, sweep()}
  def perform(%Oban.Job{}) do
    instant = Clock.now()

    instant
    |> Engagements.list_expired(lookback_from(instant), @batch_size)
    |> Enum.reduce(%{swept: 0, enqueued: 0, suppressed: 0, failed: 0}, &tally/2)
    |> then(&{:ok, &1})
  end

  @doc """
  The oldest upper bound one run will look back to.

  Public so a test can ask for the window the worker will actually use rather
  than restating the lookback, which is how the two would drift.
  """
  @spec lookback_from(DateTime.t()) :: DateTime.t()
  def lookback_from(%DateTime{} = instant), do: DateTime.add(instant, -@lookback_seconds, :second)

  @spec tally(Engagement.t(), sweep()) :: sweep()
  defp tally(%Engagement{} = engagement, counts) do
    counts |> Map.update!(:swept, &(&1 + 1)) |> Map.update!(enqueue(engagement), &(&1 + 1))
  end

  @spec enqueue(Engagement.t()) :: :enqueued | :suppressed | :failed
  defp enqueue(%Engagement{} = engagement) do
    engagement |> ExpireEngagement.schedule_for() |> Oban.insert() |> outcome(engagement)
  end

  # `conflict?` is Oban's way of saying the uniqueness rule matched an existing
  # job and this insert produced nothing, which is the measure of the sweeper
  # doing no harm.
  #
  # It also covers a second case worth naming: an insert that lost the advisory
  # lock guarding the uniqueness check comes back `{:ok, job}` with `conflict?`
  # set and *nothing written*. That is indistinguishable from suppression here
  # and does not need to be — the next run sweeps the same window and inserts it
  # then, which is what a window with a lower edge rather than a fixed floor
  # buys.
  @spec outcome({:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t(Oban.Job.t())}, Engagement.t()) ::
          :enqueued | :suppressed | :failed
  defp outcome({:ok, %Oban.Job{conflict?: true}}, _engagement), do: :suppressed
  defp outcome({:ok, %Oban.Job{}}, _engagement), do: :enqueued

  defp outcome({:error, changeset}, %Engagement{} = engagement) do
    Logger.warning(
      "engagement sweep could not enqueue an expiry announcement " <>
        "engagement_id=#{engagement.id} venue_id=#{engagement.venue_id} " <>
        "errors=#{inspect(changeset.errors)}"
    )

    :failed
  end
end
