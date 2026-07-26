ExUnit.start()

# Credo.Test.Case drives checks through Credo's own services.
{:ok, _apps} = Application.ensure_all_started(:credo)

Ecto.Adapters.SQL.Sandbox.mode(HospitalityComs.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(HospitalityComs.EmployerRepo, :manual)
