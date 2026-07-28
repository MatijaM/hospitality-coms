# Writes U11's demo manifest: two employers, four people, two shift types with
# differing graces, a past roster, a live shift, a closed shift, an accepted
# peer connection with messages, a pending request, and a hidden concurrent
# entry.
#
#     mix ecto.setup      # create, migrate, and run this
#     mix run priv/repo/seeds.exs
#
# Everything is in `HospitalityComs.Demo`, which compiles from `dev_support/`
# and is therefore absent from a production build (KTD5b). This file is a
# script rather than a module, so nothing here is compiled at all and both
# refusals below are checks a reader can see rather than an
# `UndefinedFunctionError` they have to interpret.

env = Mix.env()

if env == :prod do
  raise """
  There is no demo manifest in a production build.

  `HospitalityComs.Demo` compiles from `dev_support/`, which `mix.exs` excludes
  from the production compile path. That exclusion is KTD5b: the same controls
  that seed this manifest advance a clock that reaches irreversible retention
  deletion, so they are absent from the build rather than guarded inside it.
  """
end

if env == :test do
  raise """
  Do not seed the test database.

  `HospitalityComs.TestDatabaseGuard` clears leftover rows before the first test
  rather than refusing to run, and its whole argument for doing so is that the
  correct contents of that database before the first test are *empty*. Seeding
  it makes every non-sandboxed file start against rows nobody wrote, and makes
  the guard's report — which separates fixture residue from things written by
  nothing in this tree — say the opposite of what is true.

  `mix test` never reaches this file: the alias is `ecto.create --quiet`,
  `ecto.migrate --quiet`, `test`. Only `ecto.setup` and `ecto.reset` run it, and
  both are development commands.

  A test that wants the manifest calls `HospitalityComs.Demo.seed/0` itself,
  from a file that purges what it wrote.
  """
end

case HospitalityComs.Demo.seed() do
  {:ok, %{status: :created, instant: instant}} ->
    IO.puts("Seeded the demo manifest. Its clock opens at #{instant}.")

  {:ok, %{status: :present, instant: instant}} ->
    IO.puts("The demo manifest is already here; nothing was written. The clock reads #{instant}.")

  {:error, :partial_manifest} ->
    raise """
    This database holds part of a demo manifest.

    Some of the six anchors — two venues, four people — are present and some are
    not, which is what an interrupted seed run leaves behind. Completing it step
    by step would silently skip whatever the interrupted run had already
    written, so this refuses instead.

        mix ecto.reset
    """
end
