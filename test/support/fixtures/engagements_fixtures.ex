defmodule HospitalityComs.EngagementsFixtures do
  @moduledoc """
  Test helpers for the bridge, and the reason they commit for real.

  ## Why nothing here is sandboxed

  `HospitalityComs.Repo` and `HospitalityComs.EmployerRepo` address one database
  through two pools, so under the sandbox each holds its own transaction and
  neither can see the other's uncommitted rows.
  `HospitalityComs.VenuesFixtures` says that is not an obstacle for U4 and that
  its absence *is* the architecture working — no employer-zone table references
  `people`, so nothing in that context spans the two.

  U5 is the unit where that stops being true, and deliberately so.
  `HospitalityComs.Engagements.claim_invitation/2` reads an invitation written
  through `EmployerRepo`, writes an engagement referencing both `venues` and
  `people`, and runs as the application's own role because no session on either
  side holds the privileges for all of it. Under two sandbox transactions the
  foreign keys cannot resolve — not because the design is wrong, but because the
  test harness has split one database into two views of it.

  So this file's fixtures check out real connections and commit, and every row
  they write carries a name prefix no other test uses. `purge/0` removes them
  before and after each test, so a failure mid-test cannot leave rows behind for
  the rest of the suite to trip over. `HospitalityComs.VenuesConcurrencyTest`
  established the pattern for a different reason; this is the second.

  The cost is real: these tests are `async: false` and slower. The alternative
  was to make the claim run as `employer_role`, which would mean granting that
  role `INSERT` on `attested_entries` — the one table KTD3 says it must hold
  nothing on — to make a test harness happier.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Peers.Connection, as: PeerConnection
  alias HospitalityComs.Peers.ConnectionRequest
  alias HospitalityComs.Peers.PeerMessage
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Repo
  alias HospitalityComs.Rooms.RoomMessage
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Rooms.VenueRoomSuspension
  alias HospitalityComs.Rosters.RosterEntry
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @venue_prefix "u5-venue"
  @person_prefix "u5-person"

  # `purge/0` runs through the application's own role, which carries no
  # `statement_timeout`, so cleanup blocked on a row somebody else is holding
  # would wait for the VM to die rather than fail.
  @purge_timeout "10s"

  @doc """
  The instant these fixtures hang off, shared with the other zones' fixtures so
  a test spanning them has one clock to reason about.
  """
  @spec fixed_instant() :: DateTime.t()
  def fixed_instant, do: ~U[2026-03-01 12:00:00.000000Z]

  @doc """
  The venue-name prefix every fixture here writes and `purge/0` removes.
  """
  @spec venue_prefix() :: String.t()
  def venue_prefix, do: @venue_prefix

  @doc """
  Checks out a real connection on both repos and purges before and after.

  Returns `:ok`. Not a sandbox: see the moduledoc.
  """
  @spec real_connections() :: :ok
  def real_connections do
    Sandbox.checkout(Repo, sandbox: false)
    Sandbox.checkout(EmployerRepo, sandbox: false)
    purge()
    ExUnit.Callbacks.on_exit(fn -> with_connections(&purge/0) end)
    :ok
  end

  @doc """
  Runs `fun` with a real connection on both repos, checking them back in after.

  For `on_exit` callbacks and for tasks, which run in processes of their own and
  therefore have no connection checked out.
  """
  @spec with_connections((-> result)) :: result when result: var
  def with_connections(fun) when is_function(fun, 0) do
    Sandbox.checkout(Repo, sandbox: false)
    Sandbox.checkout(EmployerRepo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(EmployerRepo)
      Sandbox.checkin(Repo)
    end
  end

  @doc """
  Removes every row this module's fixtures could have written.

  In foreign-key order, and grants get their revocation attributions cleared
  first: `employer_grants.revoked_by_grant_id` and `granted_by_grant_id` are both
  `ON DELETE RESTRICT`, so a single statement removing a lineage is refused row
  by row rather than reconciled at the end of the statement.
  """
  @spec purge() :: :ok
  def purge do
    {:ok, :purged} = Repo.transaction(&purge_committed/0)
    :ok
  end

  @spec purge_committed() :: :purged
  defp purge_committed do
    Repo.query!("SET LOCAL statement_timeout = '#{@purge_timeout}'")

    venue_ids =
      Repo.all(
        from venue in Venue, where: like(venue.name, ^"#{@venue_prefix}%"), select: venue.id
      )

    Repo.query!("DELETE FROM oban_jobs WHERE args->>'venue_id' = ANY($1::text[])", [venue_ids])

    # U6's tables, in foreign-key order and ahead of the bridge, because every
    # one of them references `engagements` with `ON DELETE RESTRICT`. The
    # suspension is keyed on the engagement alone — it is a person-zone table
    # and carries no venue — so it is reached through the bridge rather than by
    # `venue_id`.
    Repo.delete_all(from message in RoomMessage, where: message.venue_id in ^venue_ids)
    Repo.delete_all(from entry in RosterEntry, where: entry.venue_id in ^venue_ids)

    Repo.delete_all(
      from suspension in VenueRoomSuspension,
        join: engagement in Engagement,
        on: engagement.id == suspension.engagement_id,
        where: engagement.venue_id in ^venue_ids
    )

    Repo.delete_all(from room in ShiftRoom, where: room.venue_id in ^venue_ids)

    purge_peer_graph()

    Repo.delete_all(from entry in AttestedEntry, where: entry.venue_id in ^venue_ids)
    Repo.delete_all(from engagement in Engagement, where: engagement.venue_id in ^venue_ids)
    Repo.delete_all(from invitation in Invitation, where: invitation.venue_id in ^venue_ids)
    Repo.delete_all(from shift_type in ShiftType, where: shift_type.venue_id in ^venue_ids)

    Repo.update_all(from(grant in EmployerGrant, where: grant.venue_id in ^venue_ids),
      set: [revoked_at: nil, revoked_by_grant_id: nil]
    )

    Repo.delete_all(
      from grant in EmployerGrant,
        where: grant.venue_id in ^venue_ids and not is_nil(grant.granted_by_grant_id)
    )

    Repo.delete_all(from grant in EmployerGrant, where: grant.venue_id in ^venue_ids)
    Repo.delete_all(from venue in Venue, where: venue.id in ^venue_ids)

    people = from person in Person, where: like(person.email, ^"#{@person_prefix}%")

    Repo.query!(
      "DELETE FROM people_tokens WHERE person_id IN (SELECT id FROM people WHERE email LIKE $1)",
      ["#{@person_prefix}%"]
    )

    Repo.delete_all(people)

    :purged
  end

  # U8's three, and they are reached from the *person* rather than from the
  # venue: a peer connection records no venue and no engagement, which is the
  # whole of why it is person zone. Every one of them references `people` with
  # `ON DELETE RESTRICT`, so they come off before the people do — the same
  # growth U6 forced on U5's purge, one unit further along.
  #
  # In foreign-key order among themselves: messages, then connections, then the
  # requests connections hang off.
  @spec purge_peer_graph() :: :ok
  defp purge_peer_graph do
    people = from person in Person, where: like(person.email, ^"#{@person_prefix}%")
    person_ids = Repo.all(from person in people, select: person.id)

    Repo.delete_all(from message in PeerMessage, where: message.author_id in ^person_ids)

    Repo.delete_all(
      from connection in PeerConnection,
        where:
          connection.person_a_id in ^person_ids or
            connection.person_b_id in ^person_ids
    )

    Repo.delete_all(
      from request in ConnectionRequest,
        where:
          request.requester_id in ^person_ids or
            request.addressee_id in ^person_ids
    )

    :ok
  end

  ## People

  @doc """
  A registered person, whose email carries the prefix `purge/0` removes.

  Registered for real rather than built as a struct, because an engagement holds
  a foreign key to `people` and the claim is what has to resolve it.

  Wrapped in a transaction because `HospitalityComs.Accounts.register_person/2`
  inserts with `mode: :savepoint`, which needs one to open a savepoint inside.
  Every other test in the suite gets that for free from the sandbox; this file
  has no sandbox, so it supplies its own.
  """
  @spec person_fixture(DateTime.t()) :: Person.t()
  def person_fixture(now \\ fixed_instant()) do
    email = "#{@person_prefix}-#{System.unique_integer([:positive])}@example.com"

    {:ok, person} =
      Repo.transaction(fn ->
        {:ok, person} = Accounts.register_person(%{email: email}, now)
        person
      end)

    person
  end

  @doc """
  A person scope for a registered person.
  """
  @spec person_scope_fixture(DateTime.t()) :: PersonScope.t()
  def person_scope_fixture(now \\ fixed_instant()) do
    PersonScope.for_person(person_fixture(now), now)
  end

  ## Venues

  @doc """
  A venue and the grant seeded with it, committed, named for the purge.
  """
  @spec venue_fixture(DateTime.t()) :: %{venue: Venue.t(), grant: EmployerGrant.t()}
  def venue_fixture(now \\ fixed_instant()) do
    attrs = %{
      name: "#{@venue_prefix}-#{System.unique_integer([:positive])}",
      timezone: "Europe/Zagreb"
    }

    {:ok, creation} =
      Venues.create_venue(PersonScope.for_person(person_fixture(now), now), attrs)

    creation
  end

  @doc """
  A venue together with an employer scope acting under its founding grant.
  """
  @spec scoped_venue_fixture(DateTime.t()) ::
          {EmployerScope.t(), %{venue: Venue.t(), grant: EmployerGrant.t()}}
  def scoped_venue_fixture(now \\ fixed_instant()) do
    creation = venue_fixture(now)
    {employer_scope_fixture(creation, now), creation}
  end

  @doc """
  An employer scope acting under a venue's grant, at `now`.
  """
  @spec employer_scope_fixture(%{venue: Venue.t(), grant: EmployerGrant.t()}, DateTime.t()) ::
          EmployerScope.t()
  def employer_scope_fixture(%{venue: venue, grant: grant}, now \\ fixed_instant()) do
    EmployerScope.for_grant(venue.id, grant.id, now)
  end

  ## Invitations and claims

  @doc """
  Attributes for an invitation: a month-long term opening at `now`, and a code
  good for a week.
  """
  @spec valid_invitation_attributes(map(), DateTime.t()) :: map()
  def valid_invitation_attributes(attrs \\ %{}, now \\ fixed_instant()) do
    Enum.into(attrs, %{
      role_label: "Bartender",
      starts_at: now,
      ends_at: DateTime.add(now, 30, :day),
      code_expires_at: DateTime.add(now, 7, :day)
    })
  end

  @doc """
  An issued invitation and the code that redeems it.
  """
  @spec invitation_fixture(EmployerScope.t(), map()) :: Engagements.issued()
  def invitation_fixture(%EmployerScope{} = scope, attrs \\ %{}) do
    {:ok, issued} =
      Engagements.issue_invitation(scope, valid_invitation_attributes(attrs, scope.now))

    issued
  end

  @doc """
  An invitation issued and immediately claimed, returning the claim's changes.
  """
  @spec claim_fixture(EmployerScope.t(), PersonScope.t(), map()) :: Engagements.claim()
  def claim_fixture(%EmployerScope{} = employer, %PersonScope{} = person, attrs \\ %{}) do
    %{claim_code: code} = invitation_fixture(employer, attrs)
    {:ok, claim} = Engagements.claim_invitation(person, code)
    claim
  end

  @doc """
  An engagement, which is what most tests actually want.
  """
  @spec engagement_fixture(EmployerScope.t(), PersonScope.t(), map()) :: Engagement.t()
  def engagement_fixture(%EmployerScope{} = employer, %PersonScope{} = person, attrs \\ %{}) do
    %{engagement: engagement} = claim_fixture(employer, person, attrs)
    engagement
  end
end
