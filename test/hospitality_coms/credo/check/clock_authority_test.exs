defmodule HospitalityComs.Credo.Check.ClockAuthorityTest do
  @moduledoc """
  The clock authority check is the mechanism that keeps a single instant per
  unit of work from decaying into many. It has to flag the two ways that
  decays — reading the wall clock directly, and reading the application clock
  somewhere other than a unit-of-work boundary — without flagging the clock
  itself.
  """

  use Credo.Test.Case, async: true

  alias HospitalityComs.Credo.Check.ClockAuthority

  describe "DateTime.utc_now/0" do
    test "is flagged outside the clock" do
      """
      defmodule HospitalityComs.Engagements do
        def stamp do
          DateTime.utc_now()
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue(fn issue ->
        assert issue.trigger == "DateTime.utc_now"
        assert issue.message =~ "HospitalityComs.Clock"
      end)
    end

    test "is flagged at any arity outside the clock" do
      """
      defmodule HospitalityComs.Engagements do
        def stamp do
          DateTime.utc_now(:microsecond)
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue()
    end

    test "is not flagged inside the clock itself" do
      """
      defmodule HospitalityComs.Clock do
        def now do
          DateTime.utc_now(:microsecond)
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> refute_issues()
    end

    test "is not flagged inside a module nested under the clock" do
      """
      defmodule HospitalityComs.Clock.System do
        @behaviour HospitalityComs.Clock

        @impl HospitalityComs.Clock
        def now do
          DateTime.utc_now(:microsecond)
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> refute_issues()
    end
  end

  describe "Clock.now/0" do
    test "is flagged outside a boundary module" do
      """
      defmodule HospitalityComs.Engagements do
        alias HospitalityComs.Clock

        def active?(engagement) do
          engagement.period
          |> Enum.member?(Clock.now())
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Clock.now"
        assert issue.message =~ "unit of work"
      end)
    end

    test "is flagged when called by its fully qualified name" do
      """
      defmodule HospitalityComs.Engagements do
        def active? do
          HospitalityComs.Clock.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue()
    end

    test "is not flagged inside a configured boundary module" do
      """
      defmodule HospitalityComsWeb.Plugs.CarryInstant do
        alias HospitalityComs.Clock

        def call(conn, _opts) do
          assign(conn, :now, Clock.now())
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority, boundary_modules: [HospitalityComsWeb.Plugs.CarryInstant])
      |> refute_issues()
    end

    test "is not flagged inside the clock itself" do
      """
      defmodule HospitalityComs.Clock do
        def now do
          impl().now()
        end

        def today do
          HospitalityComs.Clock.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> refute_issues()
    end

    test "is not flagged when the module is not named Clock" do
      """
      defmodule HospitalityComs.Engagements do
        alias HospitalityComs.Payroll.Cutoff

        def active? do
          Cutoff.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> refute_issues()
    end
  end

  describe "Ecto.Query.ago/2 and from_now/2" do
    test "ago/2 is flagged" do
      """
      defmodule HospitalityComs.Accounts.PersonToken do
        import Ecto.Query

        def live(query) do
          from t in query, where: t.inserted_at > ago(14, "day")
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue(fn issue ->
        assert issue.trigger == "ago"
        assert issue.message =~ "unit of work"
      end)
    end

    test "from_now/2 is flagged" do
      """
      defmodule HospitalityComs.Engagements do
        import Ecto.Query

        def upcoming(query) do
          from e in query, where: e.starts_at < from_now(7, "day")
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue(fn issue -> assert issue.trigger == "from_now" end)
    end

    test "is flagged when called by its fully qualified name" do
      """
      defmodule HospitalityComs.Engagements do
        def live(query) do
          Ecto.Query.where(query, [e], e.inserted_at > Ecto.Query.ago(14, "day"))
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> assert_issue(fn issue -> assert issue.trigger == "ago" end)
    end

    test "is not flagged when the boundary is an instant the caller passed in" do
      """
      defmodule HospitalityComs.Accounts.PersonToken do
        import Ecto.Query

        def live(query, horizon) do
          from t in query, where: t.inserted_at > ^horizon
        end
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> refute_issues()
    end

    test "does not flag unrelated two-argument calls" do
      """
      defmodule HospitalityComs.Engagements do
        def summarise(entries, scope) do
          entries
          |> Enum.take(2)
          |> overlap(scope.now)
        end

        defp overlap(entries, now), do: Enum.filter(entries, &covers?(&1, now))
      end
      """
      |> to_source_file()
      |> run_check(ClockAuthority)
      |> refute_issues()
    end
  end
end
