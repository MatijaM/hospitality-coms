defmodule HospitalityComs.Accounts.EmployerScopeTest do
  @moduledoc """
  The employer scope refuses to be built out of something that is not an
  employer id.

  `employer_id` is not an inert field. It is written into the transaction as
  `app.employer_id` and read back by `app_current_employer_id()`, which casts
  it to `uuid` — so a scope carrying `""` or `"nope"` is a scope that fails
  three layers away from whoever built it, inside the qualifier of the view
  U9 reads the employer zone through, with a Postgres message about a cast.
  """

  use ExUnit.Case, async: true

  alias HospitalityComs.Accounts.EmployerScope

  @now ~U[2026-03-01 12:00:00.000000Z]

  describe "for_employer/2" do
    test "builds a scope from a UUID and the unit of work's instant" do
      employer_id = Ecto.UUID.generate()

      assert %EmployerScope{employer_id: ^employer_id, now: @now} =
               EmployerScope.for_employer(employer_id, @now)
    end

    test "normalises an uppercase UUID to the form Postgres hands back" do
      employer_id = Ecto.UUID.generate()

      assert EmployerScope.for_employer(String.upcase(employer_id), @now).employer_id ==
               employer_id
    end

    test "refuses the empty string" do
      assert_raise ArgumentError, ~r/is not an employer id/, fn ->
        EmployerScope.for_employer("", @now)
      end
    end

    test "refuses a string that is not a UUID" do
      assert_raise ArgumentError, ~r/is not an employer id/, fn ->
        EmployerScope.for_employer("nope", @now)
      end
    end

    test "refuses sixteen raw bytes, which Ecto.UUID.cast/1 would have encoded" do
      # `Ecto.UUID.cast/1` accepts the binary form and hex-encodes it, so
      # relying on it alone would turn any sixteen-character string into a
      # valid-looking employer.
      assert_raise ArgumentError, ~r/is not an employer id/, fn ->
        EmployerScope.for_employer("0123456789abcdef", @now)
      end
    end

    test "refuses a UUID-shaped string with a character that is not hex" do
      assert_raise ArgumentError, ~r/is not an employer id/, fn ->
        EmployerScope.for_employer("zzzzzzzz-0000-0000-0000-000000000000", @now)
      end
    end
  end
end
