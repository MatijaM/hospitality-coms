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

  ## Uniqueness is total, deliberately

  Every state, `period: :infinity`. One revocation per engagement per upper
  bound, for the life of the queue. `HospitalityComs.Engagements.claim_invitation/2`
  schedules the job at the term's upper bound inside the claim's transaction;
  `HospitalityComs.Workers.EngagementSweeper` is the backstop for the case where
  that job was lost, and it inserts the same args on purpose so that the
  ordinary case costs nothing.
  """

  use Oban.Worker,
    queue: :engagements,
    max_attempts: 3,
    unique: [fields: [:worker, :args], states: Oban.Job.states(), period: :infinity]

  alias HospitalityComs.Clock
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement

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
    {:ok, Engagements.revoke_if_expired(engagement_id, Clock.now())}
  end
end
