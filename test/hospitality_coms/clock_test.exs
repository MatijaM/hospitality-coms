defmodule HospitalityComs.ClockTest do
  @moduledoc """
  The clock is the only source of the current instant in the application, so
  these tests pin both halves of that claim: the real implementation reports a
  usable instant, and the non-production implementation is controllable and
  lives outside the production compile path.
  """

  # The offsettable clock is process-independent global state, so tests that
  # move it cannot run concurrently with each other.
  use ExUnit.Case, async: false

  alias HospitalityComs.Clock

  @fixed ~U[2026-03-01 12:00:00.000000Z]

  setup do
    Clock.Offset.reset()
    on_exit(&Clock.Offset.reset/0)
  end

  describe "now/0" do
    test "returns a DateTime with microsecond precision" do
      assert %DateTime{microsecond: {_microseconds, 6}} = Clock.now()
    end

    test "returns an instant in UTC" do
      assert %DateTime{time_zone: "Etc/UTC"} = Clock.now()
    end

    test "delegates to the implementation configured for the environment" do
      assert Clock.impl() == Clock.Offset
    end
  end

  describe "the system implementation" do
    test "returns the current instant with microsecond precision" do
      before = DateTime.from_unix!(System.os_time(:microsecond), :microsecond)
      now = Clock.System.now()

      assert %DateTime{microsecond: {_microseconds, 6}} = now
      assert DateTime.compare(now, before) in [:eq, :gt]
    end
  end

  describe "the offsettable implementation" do
    test "returns the fixed instant on repeated calls" do
      :ok = Clock.Offset.set(@fixed)

      assert Clock.now() == @fixed
      assert Clock.now() == @fixed
      assert Clock.now() == @fixed
    end

    test "advancing moves the returned instant by exactly that duration" do
      :ok = Clock.Offset.set(@fixed)
      :ok = Clock.Offset.advance(day: 30)

      assert Clock.now() == ~U[2026-03-31 12:00:00.000000Z]
    end

    test "advancing accepts a Duration struct" do
      :ok = Clock.Offset.set(@fixed)
      :ok = Clock.Offset.advance(Duration.new!(hour: 6, minute: 30))

      assert Clock.now() == ~U[2026-03-01 18:30:00.000000Z]
    end

    test "successive advances accumulate" do
      :ok = Clock.Offset.set(@fixed)
      :ok = Clock.Offset.advance(day: 30)
      :ok = Clock.Offset.advance(minute: 15)

      assert Clock.now() == ~U[2026-03-31 12:15:00.000000Z]
    end

    test "advancing without a fixed instant offsets the system instant" do
      :ok = Clock.Offset.advance(day: 30)

      assert DateTime.diff(Clock.now(), Clock.System.now(), :second) in 2_591_990..2_592_000
    end

    test "reset returns the clock to the system instant" do
      :ok = Clock.Offset.set(@fixed)
      :ok = Clock.Offset.reset()

      assert abs(DateTime.diff(Clock.now(), Clock.System.now(), :millisecond)) < 100
    end

    test "is not compiled into the production build" do
      source = Clock.Offset.module_info(:compile)[:source] |> List.to_string()

      refute source =~ ~r{/lib/hospitality_coms/}
      assert source =~ ~r{/dev_support/hospitality_coms/}
    end
  end
end
