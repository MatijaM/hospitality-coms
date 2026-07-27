defmodule HospitalityComs.VenuesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `HospitalityComs.Venues` context.

  Every fixture takes the instant explicitly, for the same reason
  `HospitalityComs.AccountsFixtures` does: a test asserting on a revocation
  boundary has to be able to place a grant on one side of it, and a test that
  does not care should not have to move global state to say so.

  `sandbox_owners/1` is here rather than in `HospitalityComs.DataCase` because
  the employer zone needs a second one. `Repo` and `EmployerRepo` address the
  same database through different pools, so each gets its own sandbox
  transaction and neither can see the other's uncommitted rows. That is not an
  obstacle for this context — no employer-zone table references `people`, so
  nothing in the employer zone ever joins across the two — and the fact that it
  is not is itself the architecture working.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.AccountsFixtures
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @doc """
  An instant to hang a test off, shared with the accounts fixtures so that a
  test spanning both zones has one clock to reason about.
  """
  @spec fixed_instant() :: DateTime.t()
  def fixed_instant, do: AccountsFixtures.fixed_instant()

  @doc """
  Checks out a sandbox connection for both repos and releases them on exit.

  Returns `:ok`; the owners are stopped by `on_exit`.
  """
  @spec sandbox_owners(boolean()) :: :ok
  def sandbox_owners(async?) do
    repo_owner = Sandbox.start_owner!(Repo, shared: not async?)
    employer_owner = Sandbox.start_owner!(EmployerRepo, shared: not async?)

    ExUnit.Callbacks.on_exit(fn ->
      Sandbox.stop_owner(employer_owner)
      Sandbox.stop_owner(repo_owner)
    end)

    :ok
  end

  @spec unique_venue_name() :: String.t()
  def unique_venue_name, do: "Venue #{System.unique_integer([:positive])}"

  @spec valid_venue_attributes(map()) :: map()
  def valid_venue_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{name: unique_venue_name(), timezone: "Europe/Zagreb"})
  end

  @doc """
  A person scope for somebody who could create a venue.

  The person is registered for real through `HospitalityComs.Accounts`, because
  "the creating person" in this unit's scenarios is meant to be an
  authenticated human rather than a struct.
  """
  @spec creator_scope(DateTime.t()) :: PersonScope.t()
  def creator_scope(now \\ fixed_instant()) do
    PersonScope.for_person(AccountsFixtures.person_fixture(%{}, now), now)
  end

  @doc """
  A venue and the grant seeded with it.
  """
  @spec venue_fixture(map(), DateTime.t()) :: %{venue: Venue.t(), grant: EmployerGrant.t()}
  def venue_fixture(attrs \\ %{}, now \\ fixed_instant()) do
    {:ok, creation} = Venues.create_venue(creator_scope(now), valid_venue_attributes(attrs))
    creation
  end

  @doc """
  An employer scope acting under a venue's grant.
  """
  @spec employer_scope_fixture(%{venue: Venue.t(), grant: EmployerGrant.t()}, DateTime.t()) ::
          EmployerScope.t()
  def employer_scope_fixture(%{venue: venue, grant: grant}, now \\ fixed_instant()) do
    EmployerScope.for_grant(venue.id, grant.id, now)
  end

  @doc """
  A venue together with an employer scope for it, which is what most tests
  actually want.
  """
  @spec scoped_venue_fixture(map(), DateTime.t()) ::
          {EmployerScope.t(), %{venue: Venue.t(), grant: EmployerGrant.t()}}
  def scoped_venue_fixture(attrs \\ %{}, now \\ fixed_instant()) do
    creation = venue_fixture(attrs, now)
    {employer_scope_fixture(creation, now), creation}
  end

  @spec valid_shift_type_attributes(map()) :: map()
  def valid_shift_type_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "Shift type #{System.unique_integer([:positive])}",
      grace_period_minutes: 30
    })
  end

  @spec shift_type_fixture(EmployerScope.t(), map()) :: ShiftType.t()
  def shift_type_fixture(%EmployerScope{} = scope, attrs \\ %{}) do
    {:ok, shift_type} =
      Venues.create_shift_type(scope, scope.employer_id, valid_shift_type_attributes(attrs))

    shift_type
  end

  @doc """
  A person that was never persisted.

  The employer zone holds no foreign key to `people`, so nothing in it can tell
  the difference — which is exactly the property worth having a fixture for.
  """
  @spec unpersisted_person() :: Person.t()
  def unpersisted_person, do: %Person{id: Ecto.UUID.generate(), email: "nobody@example.com"}
end
