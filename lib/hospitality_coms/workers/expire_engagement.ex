defmodule HospitalityComs.Workers.ExpireEngagement do
  @moduledoc """
  Announces that an engagement's term has closed, and writes nothing.

  ## The contract is the absence of a write

  This worker performs **no** update to `engagements`. It reads the row,
  re-derives activeness at its own instant, and broadcasts only if the answer is
  false. Everything else about the design depends on that:

    * A job scheduled for an upper bound that a renewal has since moved is
      *inert*. It fires, finds the engagement active, and stops. A worker that
      wrote `ends_at` — or a status column, or anything at all — would truncate
      a renewed term because of a queue's latency and nothing a manager did.
    * Because a stale job is inert, `HospitalityComs.Engagements.renew_engagement/3`
      does not have to find and cancel one. That matters more than it looks:
      renewal runs inside an `EmployerRepo` transaction and Oban writes through
      `Repo`, so a cancellation there would commit even if the renewal rolled
      back.
    * Running it twice is harmless. The revocation is not this broadcast — it is
      the rejoin that `join/3` refuses once the period no longer contains the
      instant (KTD8, U7). This is the nudge that makes an open socket notice.

  ## The instant is this job attempt's

  One attempt is one unit of work, which is one of the three boundaries KTD5
  allows to read the clock; the module is listed in `.credo.exs`'s
  `:boundary_modules` for that reason rather than by working around the check.
  A retry is a new unit of work and reads the clock again, which is correct: an
  engagement that was active when the attempt failed may not be when it is
  retried, and the retry should say what is true now.

  ## What travels in the args, and what does not

  `engagement_id`, `venue_id` and `ends_at`. **No `person_id`** — a job's args
  are a `jsonb` column in a table in `public`, and KTD2's rule about where a
  human may be named does not stop at the schemas this application owns.

  `ends_at` is a uniqueness discriminator and nothing else. The worker never
  reads it; activeness comes from the row. What it buys is that a renewal
  produces a job with *different* args, so it does not collide with the stale
  one under the uniqueness below, while two sweeps over the same unrenewed
  engagement do collide and produce one revocation rather than two.

  ## Uniqueness spans every state except the two terminal failures

  One revocation per engagement per upper bound, for as long as the queue
  remembers the job. `HospitalityComs.Engagements.claim_invitation/2` schedules
  it at the term's upper bound inside the claim's transaction;
  `HospitalityComs.Workers.EngagementSweeper` is the backstop for the case where
  that job was lost, and it inserts the same args on purpose so that the
  ordinary case costs nothing.

  `:discarded` and `:cancelled` are excluded, and that exclusion is the whole
  point of writing the list out. Spanning *every* state — which is what
  `Oban.Job.states()` does — means a job that exhausted its attempts suppresses
  its own replacement for ever, and suppresses the sweeper's identical insert
  too, so the backstop cannot substitute for the mechanism it exists to back up.
  A permanent failure became a permanent silence.

  `:completed` is deliberately *kept*, which is where this parts company with
  Oban's `:incomplete` shorthand. Under `:incomplete` a finished announcement
  stops suppressing as well, and the sweeper re-announces every expiry inside
  its lookback window on every five-minute tick. The rule wanted is "do not
  repeat work that succeeded, do repeat work that failed", and that is this list
  rather than either shorthand.

  `period: :infinity` means the rule is bounded by retention rather than by a
  clock, and `Oban.Plugins.Pruner` in `config/config.exs` is what makes that a
  bound at all. A pruned announcement can be re-enqueued and re-broadcast once;
  running twice is harmless, which is the property in the first section.
  """

  # Every state a job can reach except the two it reaches by failing. Written as
  # a subtraction from Oban's own list rather than as five literals: Oban
  # validates at compile time that the set covers every `:incomplete` state, and
  # a literal list is one Oban release away from silently missing one.
  @unique_states Oban.Job.states() -- [:discarded, :cancelled]

  use Oban.Worker,
    queue: :engagements,
    max_attempts: 3,
    unique: [fields: [:worker, :args], states: @unique_states, period: :infinity]

  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle

  @doc """
  The job that announces `engagement`'s expiry, scheduled at its upper bound.

  Used by the claim, which inserts it inside its own `Ecto.Multi`, and by the
  sweeper, which inserts the identical changeset so that the two deduplicate
  rather than both firing.
  """
  @spec schedule_for(Engagement.t()) :: Ecto.Changeset.t(Oban.Job.t())
  def schedule_for(%Engagement{id: id, venue_id: venue_id, ends_at: %DateTime{} = ends_at})
      when is_binary(id) and is_binary(venue_id) do
    new(
      %{
        engagement_id: id,
        venue_id: venue_id,
        ends_at: DateTime.to_iso8601(ends_at)
      },
      scheduled_at: ends_at
    )
  end

  @doc """
  Re-derives the engagement's activeness and broadcasts if it has ended.

  Always `{:ok, _}`. A job that fires against an engagement which turns out to
  be active is not a failure — it is a renewal that happened first — and
  retrying it would only ask the same question again.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, Engagements.expiry()}
  def perform(%Oban.Job{args: %{"engagement_id" => engagement_id}}) do
    instant = Clock.now()

    engagement_id
    |> Engagements.revoke_if_expired(instant)
    |> retain(engagement_id, instant)
  end

  # **The one write on this path, and it is not to `engagements`.** KTD16 asks
  # for the worker's own copy of their messages to be written "inside the
  # engagement-end transaction", and that is not available: `end_engagement/2`
  # runs inside `EmployerRepo.scoped_transaction/2` and `employer_role` holds no
  # privilege on any person-zone table, so the transaction that closes the term
  # structurally cannot write the archive. An after-commit write through `Repo`
  # would be a second connection's transaction with no backstop.
  #
  # This is the one event in the system that means "the term has closed", and it
  # already has a scheduled trigger, a periodic backstop, and idempotence. It
  # covers explicit ending too, because `end_engagement/2` rewrites `ends_at` to
  # the closing instant and `EngagementSweeper`'s window then finds it.
  #
  # It runs only on `:revoked`. `:still_active` is a renewal that happened first
  # and there is nothing to archive; `:gone` is an engagement that no longer
  # exists. `HospitalityComs.Lifecycle.retain_own_messages/2` is idempotent, so a
  # retry after a failure here writes no second copy.
  @spec retain(Engagements.expiry(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Engagements.expiry()}
  defp retain(:revoked, engagement_id, instant) do
    {:ok, _written} = Lifecycle.retain_own_messages(engagement_id, instant)
    {:ok, :revoked}
  end

  defp retain(expiry, _engagement_id, _instant), do: {:ok, expiry}
end
