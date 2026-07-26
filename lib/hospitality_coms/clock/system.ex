defmodule HospitalityComs.Clock.System do
  @moduledoc """
  The production clock: the system instant, in UTC, at microsecond precision.

  This is the only module in the application permitted to read the wall clock
  directly.
  """

  @behaviour HospitalityComs.Clock

  @impl HospitalityComs.Clock
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now(:microsecond)
end
