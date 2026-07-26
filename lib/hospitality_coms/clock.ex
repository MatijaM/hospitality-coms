defmodule HospitalityComs.Clock do
  @moduledoc """
  The single source of the current instant.

  Every time-dependent behaviour in this application — engagement activeness,
  the grace window, the lapse of a peer connection, retention deletion — reads
  its instant from here. Nothing else calls `DateTime.utc_now/0`; a project
  Credo check enforces that.

  The reason is not tidiness. An instant is captured once per unit of work and
  carried as a bound parameter, so that two queries in one transaction cannot
  disagree about whether a period has closed. A second source of the current
  instant reintroduces exactly that disagreement.

  `Clock` is a behaviour and a facade over it. The implementation is chosen by
  application config:

      config :hospitality_coms, clock: HospitalityComs.Clock.System

  `HospitalityComs.Clock.System` is the production implementation and the
  default. `HospitalityComs.Clock.Offset` is settable and advanceable, and is
  compiled only outside `:prod` — a control that can advance the clock thirty
  days is also a control that can trigger irreversible retention deletion, so
  it is absent from the production build rather than guarded inside it.
  """

  @default_impl HospitalityComs.Clock.System

  @doc """
  Returns the current instant in UTC with microsecond precision.
  """
  @callback now() :: DateTime.t()

  @doc """
  Returns the current instant in UTC with microsecond precision.

  Callable only from a unit-of-work boundary — an HTTP request, one inbound
  channel message, or one job attempt. Everywhere else, take the instant from
  the scope it was carried on.
  """
  @spec now() :: DateTime.t()
  def now, do: impl().now()

  @doc """
  Returns the clock implementation configured for the current environment.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:hospitality_coms, :clock, @default_impl)
end
