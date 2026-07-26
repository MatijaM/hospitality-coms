defmodule HospitalityComs.Accounts.PersonTest do
  @moduledoc """
  The `people` table's erasure shape, asserted at the database rather than at
  the changeset.

  U10 pseudonymises a person by nulling `email` and stamping `erased_at`. It
  cannot do that against what `mix phx.gen.auth` generates: `email` is
  `NOT NULL`, so the second erasure has nowhere to go, and the constraint that
  would keep an erased row from carrying an address does not exist. These four
  tests are what makes that unit possible, and they are written now because
  discovering the collision in U10 means a migration against live rows.

  They go through `Repo.insert` on raw changesets on purpose. The guarantee has
  to hold for whatever writes the row — the erasure path lives in a different
  context (KTD21) and will not be going through `Person.email_changeset/3`.
  """

  use HospitalityComs.DataCase, async: true

  alias Ecto.Changeset
  alias HospitalityComs.Accounts.Person

  @erased_at ~U[2026-03-01 12:00:00Z]

  defp insert_person(attrs) do
    %Person{}
    |> Changeset.change(attrs)
    |> Repo.insert()
  end

  defp insert_person!(attrs) do
    {:ok, person} = insert_person(attrs)
    person
  end

  describe "the partial unique index on email" do
    test "two erased people with no address do not collide" do
      first = insert_person!(%{email: nil, erased_at: @erased_at})
      second = insert_person!(%{email: nil, erased_at: @erased_at})

      refute first.id == second.id
      assert Repo.aggregate(Person, :count) == 2
    end

    test "two live people cannot hold the same address" do
      insert_person!(%{email: "shared@example.com"})

      assert_raise Ecto.ConstraintError, ~r/people_email_index/, fn ->
        insert_person!(%{email: "shared@example.com"})
      end
    end

    test "an erased row does not reserve the address it used to hold" do
      insert_person!(%{email: nil, erased_at: @erased_at})

      assert insert_person!(%{email: "reused@example.com"})
    end
  end

  describe "the erasure check constraints" do
    test "an erased person cannot keep their address" do
      assert_raise Ecto.ConstraintError, ~r/people_erased_email_removed/, fn ->
        insert_person!(%{email: "still-here@example.com", erased_at: @erased_at})
      end
    end

    test "a person who has not been erased must have an address" do
      assert_raise Ecto.ConstraintError, ~r/people_present_email_required/, fn ->
        insert_person!(%{email: nil, erased_at: nil})
      end
    end
  end

  describe "email_changeset/3" do
    test "rejects a change that does not change anything" do
      person = insert_person!(%{email: "same@example.com"})

      changeset = Person.email_changeset(person, %{email: "same@example.com"})

      assert %{email: ["did not change"]} = errors_on(changeset)
    end

    test "skips the uniqueness work when asked to" do
      insert_person!(%{email: "taken@example.com"})

      changeset =
        Person.email_changeset(%Person{}, %{email: "taken@example.com"}, validate_unique: false)

      assert changeset.valid?
    end
  end

  describe "confirm_changeset/2" do
    test "stamps confirmation with the instant it was given, not with now" do
      person = insert_person!(%{email: "confirming@example.com"})

      changeset = Person.confirm_changeset(person, ~U[2026-03-01 12:00:00.654321Z])

      assert Changeset.get_change(changeset, :confirmed_at) == ~U[2026-03-01 12:00:00Z]
    end
  end
end
