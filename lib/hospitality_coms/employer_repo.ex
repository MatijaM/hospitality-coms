defmodule HospitalityComs.EmployerRepo do
  @moduledoc """
  The employer zone's connection to the database.

  It addresses the same database as `HospitalityComs.Repo` and differs in one
  respect that matters: its connections run as the Postgres role
  `employer_role`, which will hold no privilege on person-zone tables. That
  makes the zone boundary a privilege error rather than a convention — the only
  tier of the boundary whose violation produces an error instead of a leak.

  The role is assumed on connection rather than logged in as, so no second set
  of credentials has to be managed. Everything else about the boundary — the
  zone grants, the transaction wrapper that carries the employer id and the
  instant, and the query backstop that refuses a person-zone source — belongs
  to a later unit. This repo exists, connects, and does nothing clever yet.

  It is deliberately absent from `:ecto_repos`, because migrations belong to
  `HospitalityComs.Repo` alone.
  """

  use Ecto.Repo,
    otp_app: :hospitality_coms,
    adapter: Ecto.Adapters.Postgres
end
