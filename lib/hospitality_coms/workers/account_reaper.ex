defmodule HospitalityComs.Workers.AccountReaper do
  @moduledoc """
  Issue #15's unattended half: one pass over the horizons `people_tokens` and
  unconfirmed `people` already had, and which nothing enforced.

  Both tables grew monotonically. A token was removed only when it was consumed
  — redemption claims the link, log-out ends the session, an email change
  expires the lot — so every abandoned magic link, every session nobody logged
  out of, and every unconfirmed row `POST /api/log-in` wrote for an address
  somebody typed once stayed for the life of the installation. The endpoint that
  writes them is reachable by any anonymous caller, which is what makes this a
  reaper rather than housekeeping.

  Everything it actually does is `HospitalityComs.Lifecycle.reap/1`. This module
  is the schedule and the unit-of-work boundary, and nothing more — the shape
  `HospitalityComs.Workers.RetentionSweeper` already has, and for the same
  reason: KTD21 confines deletion to `HospitalityComs.Lifecycle`, and a worker
  is a `lib/` module like any other.

  ## The instant is this attempt's

  One job attempt is one unit of work (KTD5), which is why this module joins
  `ExpireEngagement`, `EngagementSweeper` and `RetentionSweeper` in
  `.credo.exs`'s `:boundary_modules` rather than working around the check. A
  retry is a new unit of work and reads the clock again, which is correct: a
  token that had a minute left when the attempt failed may have none by the time
  it is retried.

  **It does not move Oban.** Oban's staging query asks
  `scheduled_at <= DateTime.utc_now()` inside its own engine, against the real
  wall clock, and no injected clock reaches it — so advancing
  `HospitalityComs.Clock.Offset` moves every horizon in this reap instantly
  while a scheduled job still waits for real time to arrive. The suite runs this
  through `Oban.Testing.perform_job/2` for that reason.

  ## One reap at a time, and no idempotence column

  `unique: [period: 60, states: :incomplete]`, which is `RetentionSweeper`'s.
  Two overlapping reaps would take the same bounded batch twice and the second
  would find the rows gone — harmless, and work nobody asked for.

  Nothing marks a row reaped, because a deleted row needs no mark and a
  surviving one is decided by its own `inserted_at`. That is the property both
  other sweepers have, for their own reasons.

  ## The counts are logged and nothing else records them

  `HospitalityComs.Lifecycle.RetentionRun` exists because the retention sweep
  destroys the only surviving copy of a person's words. This deletes a
  credential the authenticator had already stopped honouring at the same instant
  and a row whose owner recovers it by registering the same address again, so
  the trace it owes is a log line rather than a table. See
  `HospitalityComs.Lifecycle.reap/1`.
  """

  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 3,
    unique: [period: 60, states: :incomplete]

  require Logger

  alias HospitalityComs.Clock
  alias HospitalityComs.Lifecycle

  @doc """
  Deletes every token past its own context's validity and every unconfirmed
  person past theirs, at this attempt's instant.
  """
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, Lifecycle.reaping()}
  def perform(%Oban.Job{}) do
    {:ok, reaped} = Lifecycle.reap(Clock.now())

    Logger.info(
      "account reap: #{reaped.expired_tokens} expired credentials, " <>
        "#{reaped.unconfirmed_people} unconfirmed registrations"
    )

    {:ok, reaped}
  end
end
