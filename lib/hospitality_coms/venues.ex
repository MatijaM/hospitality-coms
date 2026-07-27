defmodule HospitalityComs.Venues do
  @moduledoc """
  The employer zone's root context: venues, the grants that make them
  administrable, and the shift types their rooms are built from.

  ## A person creates a venue, and no employer-zone row records which person

  This is the crux of the unit and it is worth stating before the API.

  `create_venue/2` takes a `HospitalityComs.Accounts.PersonScope` carrying a
  real person, and seeds exactly one grant in the same transaction. That
  resolves the origin document's bootstrap circularity — a venue cannot exist
  without a grant-holder, and a grant cannot be issued by a venue that does not
  exist — by making the two one write.

  What it deliberately does **not** do is write the creator's id anywhere in
  the employer zone. KTD2 permits exactly one crossing between the zones,
  `engagements.person_id`, and forbids every employer-zone table from carrying
  a person key; `HospitalityComs.BoundaryTest` asserts that against
  `pg_constraint` rather than against this paragraph. A `venues.created_by` or
  an `employer_grants.person_id` would be a second crossing, and it would put a
  worker's identity — a manager is a worker too — into rows the employer role
  can read in bulk.

  So the association is made from the other side. U5's `engagements` is the
  bridge: it carries `person_id` today by design and will carry `grant_id`
  referencing `employer_grants (id, venue_id)`, which is why this unit ships
  the composite unique index KTD2 asks for. The arrow points *from* the bridge
  *into* the employer zone, never back, and that direction is also what lets
  these three tables exist before the bridge does.

  Two consequences follow, and both are honest limitations of U4 rather than
  properties of the design:

    * The person half of "seeds one grant for the creating person" is enforced
      at the entrance — the function refuses any caller that is not an
      authenticated person — and materialised in U5. Between the two units, a
      grant is an authority nobody is yet recorded as holding.
    * There is no path here that derives an employer session from a person's
      login, because deriving one means reading the bridge. The caller supplies
      the scope; the transport that will mint it is U7's.

  ## Everything else runs under a grant

  Every other function takes a `HospitalityComs.Accounts.EmployerScope` whose
  `grant_id` is set, and refuses a scope without one by function clause rather
  than by a check in the body. The grant is then resolved against the database
  on every call: it must be live at the scope's instant and belong to the
  scope's venue. A revoked grant is refused on the next call with nothing
  having run, which is the same derived-from-time discipline engagements use.

  All reads and writes go through `HospitalityComs.EmployerRepo` inside
  `scoped_transaction/2`, including venue creation. The employer zone is the
  employer role's to write; routing the bootstrap through the application's own
  role instead would mean the one table nobody could reach as `employer_role`
  is the one at the root of the zone.

  ## The last-grant-holder invariant lives here

  `revoke_grant/2` refuses to close a venue's last live grant (KTD17, R22). It
  is enforced in the context rather than only in U11's demo control, so no code
  path reaches an unadministrable venue. It binds *voluntary* removal only:
  erasure is exempt, because gating a data-subject right on operational
  convenience is the wrong trade, and erasure lives in U10's lifecycle context
  where the exemption can be stated once.

  The check is taken under `FOR UPDATE` on the venue's live grants, ordered by
  `(granted_at, id)`. Two managers each revoking a different one of two grants
  would otherwise both read two, both decide they are not the last, and both
  commit — leaving the venue orphaned with every individual decision correct.

  It counts survivors that carry no revocation rather than survivors that are
  live at this instant, because those are different sets: a grant revoked at
  13:00 is live at 12:00, and a unit of work running at 12:00 that counted it
  would leave the venue unadministrable from 13:00.

  The invariant counts grant *rows*, not holders anybody can name — an honest
  limitation between units, since who holds a grant is recorded on U5's
  `engagements.grant_id` and that is what will make "holder" mean anything.

  ## And so does the one thing lineage is for

  `revoke_grant/2` restricts what a grant may close to itself and its
  transitive descendants. Recording lineage in a composite foreign key and then
  letting any grant close any other would make the key decoration and let a
  subordinate close the authority that appointed them. Revocation is not
  transitive in the other direction: closing a grant leaves the grants it
  issued live. See `revoke_grant/2`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @typedoc """
  What venue creation produces: the venue, and the one grant seeded with it.
  """
  @type creation() :: %{venue: Venue.t(), grant: EmployerGrant.t()}

  @typedoc """
  A failed venue creation, naming the step that failed.

  `Ecto.Multi`'s shape rather than a flattened `{:error, reason}`, because the
  two steps fail for unrelated reasons — a rejected timezone is the caller's
  problem and a rejected grant is this module's — and collapsing them would
  lose which.
  """
  @type creation_failure() ::
          {:error, :venue, Ecto.Changeset.t(Venue.t()), map()}
          | {:error, :grant, Ecto.Changeset.t(EmployerGrant.t()), map()}

  ## Creating a venue

  @doc """
  Creates a venue and seeds the one grant that makes it administrable.

  Both in one transaction: a venue with no grant is a venue nobody can
  administer, and a grant with no venue is not a row the schema can hold.

  Refuses anything but an authenticated person by function clause. An
  `EmployerScope` has no matching head at all, and an anonymous `PersonScope`
  has none either — a venue created by nobody is the bootstrap hole this
  function exists to close.

  The venue's timezone must be an IANA name Postgres knows (KTD20); see
  `HospitalityComs.Venues.Venue`.
  """
  @spec create_venue(PersonScope.t(), map()) :: {:ok, creation()} | creation_failure()
  def create_venue(%PersonScope{person: %Person{}, now: now}, attrs) when is_map(attrs) do
    venue_id = Ecto.UUID.generate()
    grant_id = Ecto.UUID.generate()

    venue_id
    |> EmployerScope.for_grant(grant_id, now)
    |> seed(venue_id, grant_id, attrs)
  end

  @spec seed(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, creation()} | creation_failure()
  defp seed(scope, venue_id, grant_id, attrs) do
    scope
    |> EmployerRepo.scoped_transaction(&run_seed(&1, venue_id, grant_id, attrs))
    |> unwrap_multi()
  end

  @spec run_seed(EmployerScope.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, creation()} | {:error, {atom(), term(), map()}}
  defp run_seed(scope, venue_id, grant_id, attrs) do
    Multi.new()
    |> Multi.insert(:venue, venue_changeset(venue_id, attrs, scope.now))
    |> Multi.insert(:grant, EmployerGrant.founding_changeset(grant_id, venue_id, scope.now))
    # A savepoint, so a rejected changeset rolls back the two inserts and
    # leaves the enclosing scoped transaction able to report why. Without it
    # the rollback poisons the transaction the wrapper opened.
    |> EmployerRepo.transaction(mode: :savepoint)
    |> wrap_multi()
  end

  @spec venue_changeset(Ecto.UUID.t(), map(), DateTime.t()) :: Ecto.Changeset.t(Venue.t())
  defp venue_changeset(venue_id, attrs, now) do
    Venue.changeset(%Venue{id: venue_id}, attrs, now, &known_timezone?/1)
  end

  # Postgres's own copy of the IANA database. Elixir's default time zone
  # database knows only `Etc/UTC`, and adding a real one is a dependency this
  # application needs for nothing else while it is already inside a
  # transaction on a server that has one.
  @spec known_timezone?(String.t()) :: boolean()
  defp known_timezone?(timezone) do
    EmployerRepo.exists?(from zone in "pg_timezone_names", where: zone.name == ^timezone)
  end

  @spec wrap_multi({:ok, creation()} | {:error, atom(), term(), map()}) ::
          {:ok, creation()} | {:error, {atom(), term(), map()}}
  defp wrap_multi({:ok, changes}), do: {:ok, changes}
  defp wrap_multi({:error, step, value, changes}), do: {:error, {step, value, changes}}

  @spec unwrap_multi({:ok, creation()} | {:error, {atom(), term(), map()}}) ::
          {:ok, creation()} | creation_failure()
  defp unwrap_multi({:ok, changes}), do: {:ok, changes}
  defp unwrap_multi({:error, {step, value, changes}}), do: {:error, step, value, changes}

  ## Reading the venue

  @doc """
  The venue the scope is for.

  There is no id argument, which is the point: a scope cannot ask for a venue
  other than its own, so cross-venue reads are unrepresentable rather than
  filtered out.
  """
  @spec fetch_venue(EmployerScope.t()) :: {:ok, Venue.t()} | {:error, :no_grant | :not_found}
  def fetch_venue(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_venue/1)
  end

  @spec read_venue(EmployerScope.t()) :: {:ok, Venue.t()} | {:error, :no_grant | :not_found}
  defp read_venue(scope) do
    with {:ok, _grant} <- authorize(scope) do
      Venue |> EmployerRepo.get(scope.venue_id) |> found()
    end
  end

  @spec found(Venue.t() | nil) :: {:ok, Venue.t()} | {:error, :not_found}
  defp found(%Venue{} = venue), do: {:ok, venue}
  defp found(nil), do: {:error, :not_found}

  ## Grants

  @doc """
  The venue's grants that are live at the scope's instant, oldest first.

  Oldest by `granted_at`, with `id` breaking ties. Ordering by `id` alone is
  random on a `binary_id` schema, so "oldest first" would be a sentence the
  query did not implement — and `(granted_at, id)` is still a total order, so
  the `FOR UPDATE` in `revoke_grant/2` keeps acquiring locks deterministically.
  """
  @spec list_grants(EmployerScope.t()) ::
          {:ok, [EmployerGrant.t()]} | {:error, :no_grant}
  def list_grants(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_grants/1)
  end

  @spec read_grants(EmployerScope.t()) :: {:ok, [EmployerGrant.t()]} | {:error, :no_grant}
  defp read_grants(scope) do
    with {:ok, _grant} <- authorize(scope) do
      {:ok, EmployerRepo.all(live_grants(scope))}
    end
  end

  @doc """
  Issues another grant at the venue, descending from the scope's own.

  The new grant names no holder, for the reason the moduledoc gives. What makes
  it a second *holder* is the engagement U5 attaches to it.
  """
  @spec issue_grant(EmployerScope.t()) ::
          {:ok, EmployerGrant.t()}
          | {:error, :no_grant | Ecto.Changeset.t(EmployerGrant.t())}
  def issue_grant(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &write_grant/1)
  end

  @spec write_grant(EmployerScope.t()) ::
          {:ok, EmployerGrant.t()} | {:error, :no_grant | Ecto.Changeset.t(EmployerGrant.t())}
  defp write_grant(scope) do
    with {:ok, authority} <- authorize(scope) do
      scope.venue_id
      |> EmployerGrant.issued_changeset(authority.id, scope.now)
      |> EmployerRepo.insert()
    end
  end

  @doc """
  Revokes a grant, unless it is outside the acting grant's reach or the venue's
  last live one.

  ## What a grant may revoke

  Its own row, and every grant descended from it through `granted_by_grant_id`
  — transitively, and through links that have themselves been revoked, because
  a revoked row is still the record of who issued whom. Anything else comes
  back `{:error, :not_found}`: the grant that issued the acting one, a peer
  issued alongside it, a grant belonging to another venue, and an id that names
  nothing all get the same answer, so the refusal discloses nothing about which
  grants exist.

  That is the lineage the schema pays a composite foreign key to record, spent
  on the one thing it can be spent on. The alternative — any grant may close
  any other — makes the key pure provenance and lets a subordinate close the
  authority that appointed them.

  ## Revocation is not transitive

  Closing a grant leaves every grant it issued live. Authority at a venue is
  not a delegation that evaporates when its issuer leaves: the people a
  departing manager engaged are still engaged, and one call that closes an
  unbounded number of authorities is the shape of an accident rather than of an
  administrative act. The lineage foreign key is `ON DELETE RESTRICT`, so
  lineage is a hard dependency for *deletion* and pure provenance for
  revocation.

  An orphaned descendant is still reachable: the revoked link is a row, so the
  walk through it still resolves and an ancestor keeps its reach.

  ## What it refuses

  Refusing the venue's last live grant is the invariant KTD17 puts in the
  context rather than only in the demo control: a venue nobody can administer
  is not a state any code path may reach. It binds voluntary removal; erasure
  is exempt and lives in U10.

  A survivor only counts if it carries no revocation at all. One that is live
  at *this* instant but already stamped with a later `revoked_at` stops being
  live the moment that instant passes, so counting it leaves the venue
  unadministrable from then on — reachable whenever two units of work run with
  instants either side of a second boundary, which is as fine as the columns
  are.

  A grant that already carries a revocation is `{:error, :not_found}` whichever
  instant asks, rather than a second write moving `revoked_at` backwards.

  Revocation writes `revoked_at` and derives nothing — the grant stops being
  live because the instant has passed its upper bound, not because a flag was
  flipped.
  """
  @spec revoke_grant(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, EmployerGrant.t()}
          | {:error,
             :no_grant
             | :not_found
             | :last_grant_holder
             | Ecto.Changeset.t(EmployerGrant.t())}
  def revoke_grant(%EmployerScope{grant_id: authority_id} = scope, grant_id)
      when is_binary(authority_id) and is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &close_grant(&1, grant_id))
  end

  # Everything here is decided from the locked set, the acting grant included.
  # Resolving the authority through a separate unlocked read — which is what
  # this used to do — meant the grant a revocation was authorised by was not
  # the grant the `FOR UPDATE` was holding, so a concurrent revocation of the
  # acting grant could land between the two.
  @spec close_grant(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, EmployerGrant.t()}
          | {:error,
             :no_grant
             | :not_found
             | :last_grant_holder
             | Ecto.Changeset.t(EmployerGrant.t())}
  defp close_grant(scope, grant_id) do
    live = locked_live_grants(scope)

    with {:ok, _authority} <- acting_grant(scope, live) do
      live
      |> Enum.split_with(&(&1.id == grant_id))
      |> close(scope, grant_id)
    end
  end

  # `FOR UPDATE` on every live grant of the venue, oldest first. The count and
  # the write have to be one atomic decision: two managers revoking two
  # different grants of two would each read two, each conclude they are not
  # removing the last, and together leave the venue unadministrable. A total
  # order — `(granted_at, id)` — makes the lock acquisition deterministic, so
  # the two block rather than deadlock.
  @spec locked_live_grants(EmployerScope.t()) :: [EmployerGrant.t()]
  defp locked_live_grants(scope) do
    scope
    |> live_grants()
    |> lock("FOR UPDATE")
    |> EmployerRepo.all()
  end

  @spec acting_grant(EmployerScope.t(), [EmployerGrant.t()]) ::
          {:ok, EmployerGrant.t()} | {:error, :no_grant}
  defp acting_grant(%EmployerScope{grant_id: grant_id}, live) do
    live |> Enum.find(&(&1.id == grant_id)) |> held()
  end

  @spec close({[EmployerGrant.t()], [EmployerGrant.t()]}, EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, EmployerGrant.t()}
          | {:error, :not_found | :last_grant_holder | Ecto.Changeset.t(EmployerGrant.t())}
  defp close({[%EmployerGrant{revoked_at: %DateTime{}}], _survivors}, _scope, _grant_id) do
    {:error, :not_found}
  end

  defp close({[target], survivors}, scope, grant_id) do
    scope |> revocable?(grant_id) |> within_reach(target, survivors, scope.now)
  end

  defp close({[], _survivors}, _scope, _grant_id), do: {:error, :not_found}

  @spec within_reach(boolean(), EmployerGrant.t(), [EmployerGrant.t()], DateTime.t()) ::
          {:ok, EmployerGrant.t()}
          | {:error, :not_found | :last_grant_holder | Ecto.Changeset.t(EmployerGrant.t())}
  defp within_reach(false, _target, _survivors, _now), do: {:error, :not_found}

  defp within_reach(true, target, survivors, now) do
    survivors |> Enum.any?(&is_nil(&1.revoked_at)) |> revoke(target, now)
  end

  @spec revoke(boolean(), EmployerGrant.t(), DateTime.t()) ::
          {:ok, EmployerGrant.t()} | {:error, Ecto.Changeset.t(EmployerGrant.t())}
  defp revoke(true, target, now) do
    target |> EmployerGrant.revocation_changeset(now) |> EmployerRepo.update()
  end

  defp revoke(false, _target, _now), do: {:error, :last_grant_holder}

  # Whether `grant_id` is the acting grant or descends from it.
  #
  # Walked in the database rather than over the locked live set, because a live
  # descendant may hang off a link that has itself been revoked — and a walk
  # over live rows alone would drop that link and the whole subtree under it,
  # stranding grants nobody could close.
  @spec revocable?(EmployerScope.t(), Ecto.UUID.t()) :: boolean()
  defp revocable?(scope, grant_id) do
    scope |> lineage() |> where([grant], grant.id == ^grant_id) |> EmployerRepo.exists?()
  end

  @spec lineage(EmployerScope.t()) :: Ecto.Query.t()
  defp lineage(%EmployerScope{venue_id: venue_id, grant_id: grant_id}) do
    acting =
      from grant in EmployerGrant,
        where: grant.venue_id == ^venue_id and grant.id == ^grant_id,
        select: %{id: grant.id}

    issued =
      from grant in EmployerGrant,
        join: ancestor in "lineage",
        on: grant.granted_by_grant_id == ancestor.id,
        where: grant.venue_id == ^venue_id,
        select: %{id: grant.id}

    {"lineage", EmployerGrant}
    |> recursive_ctes(true)
    |> with_cte("lineage", as: ^union_all(acting, ^issued))
  end

  ## Shift types

  @doc """
  Creates a shift type at `venue_id`.

  `venue_id` is passed explicitly rather than taken from the scope so that
  attaching a shift type to somebody else's venue is a thing the API can be
  *asked* to do and refuse. A scope whose grant is not live at that venue gets
  `:no_grant`, whether the mismatch is the venue's or the grant's.
  """
  @spec create_shift_type(EmployerScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, ShiftType.t()} | {:error, :no_grant | Ecto.Changeset.t(ShiftType.t())}
  def create_shift_type(%EmployerScope{grant_id: grant_id} = scope, venue_id, attrs)
      when is_binary(grant_id) and is_binary(venue_id) and is_map(attrs) do
    EmployerRepo.scoped_transaction(scope, &write_shift_type(&1, venue_id, attrs))
  end

  @spec write_shift_type(EmployerScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, ShiftType.t()} | {:error, :no_grant | Ecto.Changeset.t(ShiftType.t())}
  defp write_shift_type(scope, venue_id, attrs) do
    with {:ok, _grant} <- authorize(scope, venue_id) do
      %ShiftType{}
      |> ShiftType.changeset(venue_id, attrs, scope.now)
      |> EmployerRepo.insert()
    end
  end

  @doc """
  The venue's shift types, oldest first.
  """
  @spec list_shift_types(EmployerScope.t()) :: {:ok, [ShiftType.t()]} | {:error, :no_grant}
  def list_shift_types(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_shift_types/1)
  end

  @spec read_shift_types(EmployerScope.t()) :: {:ok, [ShiftType.t()]} | {:error, :no_grant}
  defp read_shift_types(scope) do
    with {:ok, _grant} <- authorize(scope) do
      {:ok, EmployerRepo.all(ShiftType.of_venue(scope.venue_id))}
    end
  end

  ## Authority

  # The scope's grant, resolved against the database at the scope's instant.
  #
  # Never cached and never trusted from the struct: the scope says which grant
  # the session claims, and the row says whether that claim is still true. A
  # grant revoked a second ago is refused here with no job having run, which is
  # the same property engagements get from their period.
  @spec authorize(EmployerScope.t()) :: {:ok, EmployerGrant.t()} | {:error, :no_grant}
  defp authorize(%EmployerScope{venue_id: venue_id} = scope), do: authorize(scope, venue_id)

  # The venue is matched against the scope's own in the head, so a request for
  # another venue has no clause that reaches the database at all.
  @spec authorize(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, EmployerGrant.t()} | {:error, :no_grant}
  defp authorize(%EmployerScope{venue_id: venue_id} = scope, venue_id) do
    scope
    |> live_grants()
    |> where([grant], grant.id == ^scope.grant_id)
    |> EmployerRepo.one()
    |> held()
  end

  defp authorize(%EmployerScope{}, _other_venue_id), do: {:error, :no_grant}

  @spec held(EmployerGrant.t() | nil) :: {:ok, EmployerGrant.t()} | {:error, :no_grant}
  defp held(%EmployerGrant{} = grant), do: {:ok, grant}
  defp held(nil), do: {:error, :no_grant}

  @spec live_grants(EmployerScope.t()) :: Ecto.Query.t()
  defp live_grants(%EmployerScope{venue_id: venue_id, now: now}) do
    venue_id
    |> EmployerGrant.live_at(now)
    |> order_by([grant], asc: grant.granted_at, asc: grant.id)
  end
end
