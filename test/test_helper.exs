# `assert_receive`'s default budget is 100ms, and every one of the suite's
# fifty-odd `assert_reply` calls inherits it. That is not a latency allowance —
# **measured, a venue-room send replies in 1.2ms median and 2.4ms worst of
# twenty samples**, so the margin is forty-fold and the number is only ever
# reached when the scheduler stops running this process at all. Which is what
# a shared two-core CI runner does while Postgres is busy in a container beside
# it: `revocation_test.exs`'s *control* send — the one asserting the transport
# works before the test does anything — timed out on a tree whose Elixir half
# had passed forty minutes earlier, unchanged.
#
# So the failure this raises the bound against is starvation, not slowness, and
# 500ms buys nothing a correct run spends. A passing `assert_receive` returns
# the instant its message lands and never consults the timeout; only a failing
# one waits it out, and a run with a failure in it is not one whose duration is
# being optimised. `refute_receive` is deliberately **not** raised — it has its
# own `:refute_receive_timeout`, it waits the full budget on the path where it
# passes, and it is the one this would genuinely slow down.
ExUnit.start(assert_receive_timeout: 500)

# Credo.Test.Case drives checks through Credo's own services.
{:ok, _apps} = Application.ensure_all_started(:credo)

# Before the sandbox is put in `:manual` mode, and therefore before any test.
# The sandbox pool defaults to `:auto`, so the guard's statements commit like
# the fixtures' own do; after `mode(:manual)` it would need a checkout of its
# own and its DELETEs would roll back with the transaction that owned them.
:ok = HospitalityComs.TestDatabaseGuard.sweep()

Ecto.Adapters.SQL.Sandbox.mode(HospitalityComs.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(HospitalityComs.EmployerRepo, :manual)
