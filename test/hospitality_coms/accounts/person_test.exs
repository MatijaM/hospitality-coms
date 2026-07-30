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

  import Ecto.Query

  alias Ecto.Changeset
  alias HospitalityComs.Accounts.DisplayName
  alias HospitalityComs.Accounts.Person

  @erased_at ~U[2026-03-01 12:00:00Z]
  @now ~U[2026-03-01 12:00:00.000000Z]

  # `display_name` is `NOT NULL` since #66 and is *given* rather than cast, so a
  # raw changeset has to supply one. It defaults here rather than at each call
  # site because none of these tests is about the name; the two that are live in
  # the display-name block below and pass their own.
  defp insert_person(attrs) do
    %Person{}
    |> Changeset.change(Map.merge(%{display_name: "Captain Nemo"}, Map.new(attrs)))
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

      changeset = Person.email_changeset(person, %{email: "same@example.com"}, @now)

      assert %{email: ["did not change"]} = errors_on(changeset)
    end

    test "skips the uniqueness work when asked to" do
      insert_person!(%{email: "taken@example.com"})

      changeset =
        Person.email_changeset(%Person{}, %{email: "taken@example.com"}, @now,
          validate_unique: false
        )

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

  describe "the display-name constraints" do
    # These are the file's own posture applied to #66's column, and here it is
    # load-bearing rather than stylistic. The one write in the tree that reaches
    # `display_name` outside `Person` is `Lifecycle.Records.pseudonymise/3`, an
    # `update_all` with no changeset in front of it — so a bound enforced only
    # by `display_name_changeset/3` would not be enforced on the erasure path at
    # all. Written raw, the way erasure writes it.

    test "refuse a blank name whatever wrote it" do
      assert_raise Ecto.ConstraintError, ~r/people_display_name_present/, fn ->
        insert_person!(%{email: "blank-name@example.com", display_name: "   "})
      end
    end

    test "refuse a name past the bound whatever wrote it" do
      too_long = String.duplicate("a", DisplayName.max_length() + 1)

      assert_raise Ecto.ConstraintError, ~r/people_display_name_within_bound/, fn ->
        insert_person!(%{email: "long-name@example.com", display_name: too_long})
      end
    end

    test "accept a name at exactly the bound" do
      # The control for both tests above: a CHECK refusing everything satisfies
      # them, and `insert_person!/1` would then be raising for its own reasons.
      at_bound = String.duplicate("a", DisplayName.max_length())

      assert %Person{display_name: ^at_bound} =
               insert_person!(%{email: "bound-name@example.com", display_name: at_bound})
    end

    test "refuse a null name outright" do
      # `NOT NULL`, which is what makes every read path free of a coalesce.
      assert_raise Postgrex.Error, ~r/not_null_violation/, fn ->
        insert_person!(%{email: "no-name@example.com", display_name: nil})
      end
    end

    test "refuse the update_all that erasure itself uses" do
      # The sharpest form of the two above, and the reason the CHECKs exist at
      # all. `Lifecycle.Records.pseudonymise/3` is an `update_all`: no changeset,
      # so no validation, so nothing in `Person` is consulted. This is that write
      # with a bad value in it.
      person = insert_person!(%{email: "erasing@example.com"})
      query = from(p in Person, where: p.id == ^person.id)

      assert_raise Postgrex.Error, ~r/people_display_name_present/, fn ->
        Repo.update_all(query, set: [display_name: " "])
      end
    end
  end
end
