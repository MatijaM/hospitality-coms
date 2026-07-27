defmodule HospitalityComs.Repo.Migrations.AddObanJobs do
  @moduledoc """
  Oban's own tables, which is the liveness half of KTD6.

  Correctness is derived: an engagement is active when the unit of work's
  instant falls in its period, so an expired engagement is refused on the next
  request whether or not anything ran. What a derivation cannot do is *tell*
  anybody — an open socket lingers until something pushes to it — and that is
  what a job queue is for here.

  `Process.send_after/3` was rejected in the plan for a reason worth restating
  next to the migration that replaces it: it does not survive a deploy, and
  engagements outlive release cadence by months.

  ## These tables belong to no zone

  `oban_jobs` and `oban_peers` are the library's, not the application's, and
  neither is classified in `HospitalityComs.Zones` — there is no Ecto schema for
  them in this application, so the totality check in
  `HospitalityComs.ZonesTest` never sees them, and `HospitalityComs.BoundaryTest`
  names them in its infrastructure exclusion list.

  Two facts make that exclusion honest rather than a hole, and both are
  asserted in that file rather than described here:

    * `employer_role` holds no privilege on either table. Nothing grants it any
      — Postgres default-denies on a table owned by another role — and the same
      sweep that audits the person zone is pointed at these two.
    * No job this application enqueues carries a `person_id` in its args. The
      expiry worker takes an engagement id and a venue id, which is the same
      discipline KTD2 puts on the employer zone: name the bridge, not the human.

  `down` rolls every version back, which takes both tables with it.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
