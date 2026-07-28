defmodule HospitalityComsWeb.ChannelCase do
  @moduledoc """
  The setup a channel test needs, and the three reasons it is not the default.

  ## Real connections, shared with the channel process

  `HospitalityComs.EngagementsFixtures` explains why anything spanning the
  bridge commits for real: `HospitalityComs.Repo` and
  `HospitalityComs.EmployerRepo` address one database through two pools, so
  under the sandbox each holds its own transaction and neither can see the
  other's rows. A channel test writes a venue and an invitation through the
  employer's repo and reads a membership through the application's, so it is in
  that category.

  A channel adds a second problem the room tests do not have: `join/3` runs in a
  **process of its own**, started by `Phoenix.ChannelTest`, and that process has
  no connection checked out. Ownership is therefore made shared for the length
  of the test. Getting this wrong does not look like a failure — it looks like
  `DBConnection.OwnershipError` raised inside `join/3`, which the channel
  reports as a crash, which reads like the join being refused. That is a failure
  mode that could be mistaken for the feature working, which is why it is set up
  in one place rather than in five.

  ## The clock is pinned

  A channel reads the clock — that is the whole of KTD5 — so a test whose
  fixtures hang off `EngagementsFixtures.fixed_instant/0` and whose channel asks
  `HospitalityComs.Clock.now/0` would be comparing March against whatever today
  is. `HospitalityComs.Clock.Offset` is pinned to the fixtures' instant for the
  length of the test and reset afterwards. Tests that want to cross a boundary
  move it with `at/1`, which is the same control the demo uses.

  ## Presence fetchers are drained

  `Phoenix.Presence` invokes `fetch/2` from a process of its own. Ours does no
  database work, so it cannot raise an owner-exited error today, but a fetcher
  outliving the test that spawned it is exactly the shape that starts failing
  the moment somebody adds a preload. They are awaited before the connections
  are checked in.

  ## Callback order

  `on_exit` runs last-registered-first, and the order here is load-bearing:
  drain the fetchers, unpin the clock, return the pools to `:manual` — which
  checks the shared connections in — and only then let
  `EngagementsFixtures.real_connections/0`'s own callback check fresh ones out
  to purge with.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Clock
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Repo
  alias HospitalityComsWeb.PersonAuth
  alias HospitalityComsWeb.Presence

  @drain_timeout 2_000

  using do
    quote do
      @endpoint HospitalityComsWeb.Endpoint

      import HospitalityComs.EngagementsFixtures
      import HospitalityComs.RoomsFixtures
      import HospitalityComsWeb.ChannelCase
      # `import`, not `use`: `use Phoenix.ChannelTest` is deprecated in
      # Phoenix 1.8 and the endpoint attribute above is all it added.
      import Phoenix.ChannelTest
    end
  end

  setup do
    EngagementsFixtures.real_connections()
    share_connections()
    pin_clock(EngagementsFixtures.fixed_instant())
    drain_fetchers_on_exit()
    :ok
  end

  @doc """
  Moves the pinned clock to `instant`.

  What every "advance and ask again" in a channel test does. It is global state
  by design — a demo control has to move the clock for every process at once —
  which is why every case using this module is synchronous.
  """
  @spec at(DateTime.t()) :: :ok
  def at(%DateTime{} = instant), do: Clock.Offset.set(instant)

  @doc """
  A live session token for `person`, encoded exactly as a client would carry it.

  A real row in `people_tokens`, so a test that deletes it is exercising the
  real revocation path, and the socket id derived from it is the real one.
  """
  @spec session_token(Person.t(), DateTime.t()) :: String.t()
  def session_token(%Person{} = person, %DateTime{} = now) do
    person
    |> PersonScope.for_person(now)
    |> Accounts.generate_person_session_token()
    |> PersonAuth.encode_token()
  end

  @doc """
  The `connect/3` options that carry a token the way `auth_token: true` does.

  The websocket transport puts it on `Sec-WebSocket-Protocol` and Phoenix hands
  it to `connect/3` as `connect_info[:auth_token]`; this is that, without a
  socket.
  """
  @spec auth(String.t()) :: keyword()
  def auth(token) when is_binary(token), do: [connect_info: %{auth_token: token}]

  @doc """
  Waits for every presence fetcher to exit, and says so.

  Used by `HospitalityComsWeb.PresenceTest` as an assertion and by this module
  as a teardown.
  """
  @spec drained_fetchers?(timeout()) :: boolean()
  def drained_fetchers?(timeout \\ @drain_timeout) do
    Enum.all?(Presence.fetchers_pids(), &awaited?(&1, timeout))
  end

  @spec awaited?(pid(), timeout()) :: boolean()
  defp awaited?(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  @spec share_connections() :: :ok
  defp share_connections do
    :ok = Sandbox.mode(Repo, {:shared, self()})
    :ok = Sandbox.mode(EmployerRepo, {:shared, self()})

    ExUnit.Callbacks.on_exit(fn ->
      Sandbox.mode(Repo, :manual)
      Sandbox.mode(EmployerRepo, :manual)
    end)

    :ok
  end

  @spec pin_clock(DateTime.t()) :: :ok
  defp pin_clock(instant) do
    :ok = Clock.Offset.set(instant)
    ExUnit.Callbacks.on_exit(&Clock.Offset.reset/0)
    :ok
  end

  @spec drain_fetchers_on_exit() :: :ok
  defp drain_fetchers_on_exit do
    ExUnit.Callbacks.on_exit(fn -> drained_fetchers?() end)
    :ok
  end
end
