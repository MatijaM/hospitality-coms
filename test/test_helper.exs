ExUnit.start()

# Credo.Test.Case drives checks through Credo's own services.
{:ok, _apps} = Application.ensure_all_started(:credo)

# Before the sandbox is put in `:manual` mode, and therefore before any test.
# The sandbox pool defaults to `:auto`, so the guard's statements commit like
# the fixtures' own do; after `mode(:manual)` it would need a checkout of its
# own and its DELETEs would roll back with the transaction that owned them.
:ok = HospitalityComs.TestDatabaseGuard.sweep()

Ecto.Adapters.SQL.Sandbox.mode(HospitalityComs.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(HospitalityComs.EmployerRepo, :manual)
