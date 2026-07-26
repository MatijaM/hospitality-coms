defmodule HospitalityComs.Repo do
  use Ecto.Repo,
    otp_app: :hospitality_coms,
    adapter: Ecto.Adapters.Postgres
end
