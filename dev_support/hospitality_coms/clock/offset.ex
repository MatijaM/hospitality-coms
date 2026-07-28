defmodule HospitalityComs.Clock.Offset do
  @moduledoc """
  A clock that can be pinned to a fixed instant and advanced by a duration.

  This exists so that a demo can walk an engagement through its lifecycle —
  the grace window opening and closing, a peer connection lapsing thirty days
  after co-rostering — without waiting for wall-clock time, and so that tests
  can assert on boundary instants rather than approximate them.

  It is compiled only in `:dev` and `:test`. The file lives outside `lib/` and
  the production compile path does not include this directory, so the module
  is absent from a production build rather than present and guarded. The same
  control that advances the clock thirty days is the control that would make
  an unattended retention sweep delete a worker's records early; structural
  absence is cheaper to trust than a runtime check.

  State is global and process-independent, because a demo control has to move
  the clock for every process at once. Tests that move it must therefore run
  with `async: false`.
  """

  @behaviour HospitalityComs.Clock

  alias HospitalityComs.Clock

  defstruct fixed: nil, shift: %Duration{}

  @type t() :: %__MODULE__{fixed: DateTime.t() | nil, shift: Duration.t()}

  @key {__MODULE__, :state}

  @doc """
  Returns the current instant, honouring the fixed instant and accumulated
  advance.
  """
  @impl Clock
  @spec now() :: DateTime.t()
  def now, do: instant(state())

  @doc """
  Pins the clock to `instant` and clears any accumulated advance.
  """
  @spec set(DateTime.t()) :: :ok
  def set(%DateTime{} = instant), do: put(%__MODULE__{fixed: instant})

  @doc """
  Moves the instant this clock reports forward by `duration`.

  Accepts a `Duration` or a keyword list of unit pairs (`day: 30`). Successive
  calls accumulate. Advancing a clock that has not been pinned offsets the
  system instant instead, so the clock keeps ticking while running ahead.
  """
  @spec advance(Duration.t() | [{atom(), integer()}]) :: :ok
  def advance(duration) do
    %__MODULE__{} = state = state()
    put(%{state | shift: Duration.add(state.shift, to_duration(duration))})
  end

  @doc """
  Returns the clock to the system instant, discarding the fixed instant and
  the accumulated advance.
  """
  @spec reset() :: :ok
  def reset, do: put(%__MODULE__{})

  @doc """
  Returns the clock's current control state.
  """
  @spec state() :: t()
  def state, do: :persistent_term.get(@key, %__MODULE__{})

  @spec instant(t()) :: DateTime.t()
  defp instant(%__MODULE__{fixed: nil, shift: shift}),
    do: DateTime.shift(Clock.System.now(), shift)

  defp instant(%__MODULE__{fixed: fixed, shift: shift}), do: DateTime.shift(fixed, shift)

  @spec put(t()) :: :ok
  defp put(%__MODULE__{} = state), do: :persistent_term.put(@key, state)

  @spec to_duration(Duration.t() | [{atom(), integer()}]) :: Duration.t()
  defp to_duration(%Duration{} = duration), do: duration
  defp to_duration(unit_pairs) when is_list(unit_pairs), do: Duration.new!(unit_pairs)
end
