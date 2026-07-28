defmodule HospitalityComs.Workers.RetentionSweeper do
  @moduledoc """
  The unattended half of KTD16: one pass over the stamped deadlines.

  It reads `delete_after` columns and nothing else. There is no join to
  `engagements`, to `shift_rooms` or to `venues` anywhere behind this worker,
  and that absence is the unit's central decision rather than an optimisation —
  a manager entering a backdated end date would otherwise move a deletion
  deadline into the past, and this job, running with nobody watching, would
  destroy a worker's messages with no notice and no way back.

  Everything it actually does is `HospitalityComs.Lifecycle.sweep/1`. This
  module is the schedule and the unit-of-work boundary, and nothing more.

  ## The instant is this attempt's, and Oban's is not

  One job attempt is one unit of work (KTD5), which is why this module is listed
  in `.credo.exs`'s `:boundary_modules` alongside
  `HospitalityComs.Workers.ExpireEngagement` and
  `HospitalityComs.Workers.EngagementSweeper` rather than working around the
  check. A retry is a new unit of work and reads the clock again, which is
  correct: a deadline that had not passed when the attempt failed may have
  passed by the time it is retried, and the retry should answer for now.

  **It does not move Oban.** Oban's staging query asks `scheduled_at <=
  DateTime.utc_now()` inside its own engine, against the real wall clock, and no
  injected clock reaches it. Advancing `HospitalityComs.Clock.Offset` changes
  every deadline comparison in this sweep instantly while a scheduled job still
  waits for real time to arrive. The suite runs this through
  `Oban.Testing.perform_job/2`; U11's demo controls have to drive it the same
  way rather than advancing the clock and waiting for the queue.

  ## One sweep at a time, and no idempotence column

  `unique: [period: 60, states: :incomplete]` — `:incomplete` is Oban's name for
  every state a job can still run from, which is the set that matters here. Two
  overlapping sweeps would take the same batch twice; the second would find the
  rows gone and delete nothing, which is harmless but is work nobody asked for
  and a second `retention_runs` row that means nothing.

  Nothing marks a row swept, because a deleted row needs no mark and a surviving
  one is decided by its own column. That is the same property
  `HospitalityComs.Workers.EngagementSweeper` has for the opposite reason.

  ## Failure is a rollback, not a raise

  A run whose total exceeds `HospitalityComs.Lifecycle.ceiling/0` rolls every
  trigger back and records itself as `:refused`. The worker still answers
  `{:ok, run}`: a blast-radius refusal is an outcome the sweep reports rather
  than an error the queue should retry with the same input, and the record is
  the trace an unattended deleter owes. Whoever raised the ceiling, or fixed the
  batch bound, gets the next tick.
  """

  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  alias HospitalityComs.Clock
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Lifecycle.RetentionRun

  @doc """
  Deletes everything whose stamped deadline has passed at this attempt's
  instant, and records the run.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, RetentionRun.t()}
  def perform(%Oban.Job{}), do: Lifecycle.sweep(Clock.now())
end
