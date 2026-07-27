defmodule HospitalityComs.VenuesTest do
  @moduledoc """
  The employer zone's first context: a venue with a timezone, at least one
  grant-holder, and shift types carrying grace periods.

  Three things are being asserted here and they answer different questions.

  **That the bootstrap closes.** The origin document has a circularity — a
  venue is administered by a grant-holder, and a grant is issued at a venue —
  and the resolution is that venue creation seeds the grant in the same
  transaction. What that has to buy is the absence of a state: no sequence of
  calls reaches a venue nobody can administer. So the last-grant-holder tests
  are not about an error message, they are about that state being unreachable.

  **That activeness is derived.** A grant is live when the unit of work's
  instant falls in `[granted_at, revoked_at)` and at no other time. Every test
  that revokes and then reads passes a different instant rather than waiting,
  and the revocation instant itself is asserted to fall on the revoked side —
  half-open, matching every other period in the application.

  **That the venue filter is real.** "Readable only through its own employer
  scope" is vacuous with one venue in the database, so every read test here
  builds two and asserts the second is absent from the first's results.

  ## The controls

  Several assertions could pass for the wrong reason and ship with something
  that fails when they do:

    * the grace-period bound and the timezone requirement are asserted through
      the changeset *and* against the check constraint behind it, by writing
      raw SQL with the changeset bypassed. A validation the database does not
      also hold is one that an `insert_all` walks around.
    * the timezone rejection has a control asserting a real IANA name is
      accepted, so it cannot be a validation that refuses everything.
    * `list_shift_types/1` is asserted alongside a second venue whose rows it
      must not return.
    * venue creation's atomicity is asserted by making a step fail and looking
      for the absence of both rows.

  ## Two repos, two sandbox transactions

  `Repo` and `EmployerRepo` address the same database through different pools,
  so each test holds two sandbox transactions that cannot see each other's
  uncommitted rows. Nothing here needs them to: no employer-zone table
  references `people`, so no query in this context spans the two. The raw-SQL
  constraint tests build their own venues through `Repo` for that reason.
  """

  use ExUnit.Case, async: true

  import Ecto.Query
  import HospitalityComs.DataCase, only: [errors_on: 1]
  import HospitalityComs.VenuesFixtures

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.ShiftType
  alias HospitalityComs.Venues.Venue

  @earlier ~U[2026-03-01 11:00:00.000000Z]
  @now ~U[2026-03-01 12:00:00.000000Z]
  @later ~U[2026-03-01 13:00:00.000000Z]
  @even_later ~U[2026-03-01 14:00:00.000000Z]

  setup do
    sandbox_owners(true)
  end

  describe "create_venue/2" do
    test "rejects a venue with no timezone" do
      # KTD20: engagement end is end-of-day in venue time, so a venue whose
      # zone is unknown has no defined expiry instant at all.
      assert {:error, :venue, changeset, changes} =
               Venues.create_venue(creator_scope(@now), %{name: "The Anchor"})

      assert "can't be blank" in errors_on(changeset).timezone
      assert changes == %{}
    end

    test "rejects a timezone that is not an IANA name" do
      assert {:error, :venue, changeset, _changes} =
               Venues.create_venue(
                 creator_scope(@now),
                 valid_venue_attributes(%{timezone: "Europe/Atlantis"})
               )

      assert "is not an IANA time zone name" in errors_on(changeset).timezone
    end

    test "accepts an IANA name the database knows" do
      # The control for the two above. Without it they pass on a validation
      # that rejects every timezone, which would make the field required in the
      # most useless possible way.
      assert {:ok, %{venue: %Venue{timezone: "Pacific/Auckland"}}} =
               Venues.create_venue(
                 creator_scope(@now),
                 valid_venue_attributes(%{timezone: "Pacific/Auckland"})
               )
    end

    test "rejects a venue with no name" do
      assert {:error, :venue, changeset, _changes} =
               Venues.create_venue(creator_scope(@now), %{timezone: "Europe/Zagreb"})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "does not let the caller choose the venue's id" do
      # `id` used to be castable, so an id arriving in user attributes became
      # the venue's while the grant was seeded against the id this function
      # minted — two different venues, one of which does not exist.
      chosen = Ecto.UUID.generate()

      assert {:ok, %{venue: venue, grant: grant}} =
               Venues.create_venue(creator_scope(@now), valid_venue_attributes(%{id: chosen}))

      refute venue.id == chosen
      assert grant.venue_id == venue.id
    end

    test "reports no error for an id that is already taken, because it never reaches the row" do
      # The other half. A castable primary key also made a colliding caller
      # id raise `Ecto.ConstraintError` out of a function whose contract is
      # `{:ok, _} | {:error, _}` — an exception where the caller was promised
      # a tuple.
      {_scope, %{venue: existing}} = scoped_venue_fixture(%{}, @now)

      assert {:ok, %{venue: venue}} =
               Venues.create_venue(
                 creator_scope(@now),
                 valid_venue_attributes(%{id: existing.id})
               )

      refute venue.id == existing.id
    end

    test "seeds exactly one grant for the venue it creates" do
      assert {:ok, %{venue: venue, grant: grant}} =
               Venues.create_venue(creator_scope(@now), valid_venue_attributes())

      assert %EmployerGrant{venue_id: venue_id, granted_by_grant_id: nil} = grant
      assert venue_id == venue.id
      assert DateTime.compare(grant.granted_at, @now) == :eq
      assert is_nil(grant.revoked_at)

      # Exactly one, which is the half of "seeds a grant" that an assertion on
      # the returned struct cannot see.
      assert live_grant_ids(venue.id) == [grant.id]
    end

    test "records nobody as the holder, because no employer-zone row may name a person" do
      # The crux of the unit. A person creates the venue — `create_venue/2`
      # refuses any other caller — and the employer zone comes out of it with
      # no column that could hold who they were. The association is made from
      # the bridge in U5, which points into the employer zone rather than out
      # of it.
      %{grant: grant, venue: venue} = venue_fixture(%{}, @now)

      Enum.each([Venue, EmployerGrant, ShiftType], fn schema ->
        assert Enum.filter(schema.__schema__(:fields), &person_naming?/1) == []
      end)

      assert %EmployerGrant{venue_id: venue_id, granted_by_grant_id: nil} = grant
      assert venue_id == venue.id
    end

    test "does not need the creating person to exist in the database" do
      # The same point from the other side, and the reason the two repos'
      # sandbox transactions never have to see each other. There is no foreign
      # key from the employer zone to `people`, so a person the employer zone
      # has never heard of creates a venue exactly as well as a registered one.
      scope = PersonScope.for_person(unpersisted_person(), @now)

      assert {:ok, %{venue: %Venue{}, grant: %EmployerGrant{}}} =
               Venues.create_venue(scope, valid_venue_attributes())
    end

    test "refuses an anonymous person scope by function clause" do
      # A venue created by nobody is the bootstrap hole this function closes.
      anonymous = scope_of(:anonymous)

      assert_raise FunctionClauseError, fn ->
        Venues.create_venue(anonymous, valid_venue_attributes())
      end
    end

    test "refuses an employer scope by function clause" do
      employer = scope_of(:granted)

      assert_raise FunctionClauseError, fn ->
        Venues.create_venue(employer, valid_venue_attributes())
      end
    end

    test "writes neither row when a step fails" do
      # The control for the Multi. Two bare inserts would leave the venue
      # behind when the grant failed, and a grantless venue is the state the
      # whole invariant exists to prevent; the direction that can be forced
      # from outside is the other one.
      before = employer_count(Venue)

      assert {:error, :venue, _changeset, %{}} =
               Venues.create_venue(creator_scope(@now), %{name: "The Anchor"})

      assert employer_count(Venue) == before
      assert employer_count(EmployerGrant) == 0
    end
  end

  describe "the last-grant-holder invariant" do
    test "refuses to revoke the last live grant" do
      {scope, %{grant: grant}} = scoped_venue_fixture(%{}, @now)

      assert Venues.revoke_grant(scope, grant.id) == {:error, :last_grant_holder}
    end

    test "leaves the refused grant live, so the venue stays administrable" do
      # The refusal is only worth anything if nothing was written on the way to
      # it. A revocation that failed *after* stamping `revoked_at` would return
      # this error and orphan the venue anyway.
      {scope, %{venue: venue, grant: grant}} = scoped_venue_fixture(%{}, @now)

      assert {:error, :last_grant_holder} = Venues.revoke_grant(scope, grant.id)

      assert live_grant_ids(venue.id) == [grant.id]
      assert {:ok, [%EmployerGrant{id: id}]} = Venues.list_grants(scope)
      assert id == grant.id
    end

    test "allows revoking a grant when two exist" do
      {scope, %{venue: venue, grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)

      assert {:ok, revoked} = Venues.revoke_grant(scope, second.id)
      assert DateTime.compare(revoked.revoked_at, @now) == :eq

      assert live_grant_ids(venue.id) == [founding.id]
    end

    test "refuses the survivor once the second grant is gone" do
      # The invariant is a live count rather than a row count, so revoking one
      # of two has to move the venue back into the state where the other cannot
      # be revoked. Nothing ran in between.
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)

      assert {:ok, _revoked} = Venues.revoke_grant(scope, second.id)
      assert Venues.revoke_grant(scope, founding.id) == {:error, :last_grant_holder}
    end

    test "counts only grants that are live at the unit of work's instant" do
      # Two grants exist as rows and one of them is revoked, so a count of rows
      # says two and a count of live grants says one. This is the assertion
      # that fails if the invariant is ever written against the table rather
      # than against the instant.
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)
      {:ok, _revoked} = Venues.revoke_grant(scope, second.id)

      later = EmployerScope.for_grant(scope.venue_id, founding.id, @later)

      assert employer_count(EmployerGrant) == 2
      assert Venues.revoke_grant(later, founding.id) == {:error, :last_grant_holder}
    end

    test "counts no survivor that already carries a revocation of its own" do
      # Two units of work whose instants fall either side of a second
      # boundary, which is all it takes: at 12:00 the second grant is still
      # live because its revocation is at 13:00, so a survivor count that only
      # asks "live now" says one and lets the founding grant go — leaving the
      # venue with nobody administering it from 13:00 onwards, and every
      # individual decision correct.
      {scope, %{venue: venue, grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)

      later = EmployerScope.for_grant(scope.venue_id, founding.id, @later)
      {:ok, _revoked} = Venues.revoke_grant(later, second.id)

      assert Venues.revoke_grant(scope, founding.id) == {:error, :last_grant_holder}
      assert live_grant_ids(venue.id) == [founding.id]
    end
  end

  describe "what a grant may revoke" do
    # The lineage the schema pays a composite foreign key to record, used for
    # the one thing it can be used for. Without this the key was provenance
    # nothing consulted, and any grant could close any other — including the
    # one that appointed it.

    test "includes its own row, so a holder can stand down" do
      # The control. A revocable set that excluded the acting grant would make
      # every test below pass and resignation impossible.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, child} = Venues.issue_grant(scope)
      child_scope = EmployerScope.for_grant(scope.venue_id, child.id, @now)

      assert {:ok, %EmployerGrant{id: id}} = Venues.revoke_grant(child_scope, child.id)
      assert id == child.id
    end

    test "includes a grant it issued" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, child} = Venues.issue_grant(scope)

      assert {:ok, %EmployerGrant{id: id}} = Venues.revoke_grant(scope, child.id)
      assert id == child.id
    end

    test "includes a grant its own descendant issued" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, middle} = Venues.issue_grant(scope)
      middle_scope = EmployerScope.for_grant(scope.venue_id, middle.id, @now)
      {:ok, leaf} = Venues.issue_grant(middle_scope)

      assert {:ok, %EmployerGrant{id: id}} = Venues.revoke_grant(scope, leaf.id)
      assert id == leaf.id
    end

    test "excludes the grant that issued it" do
      # A subordinate closing the authority that appointed them is the one
      # thing recording lineage and ignoring it made possible.
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, child} = Venues.issue_grant(scope)
      child_scope = EmployerScope.for_grant(scope.venue_id, child.id, @now)

      assert Venues.revoke_grant(child_scope, founding.id) == {:error, :not_found}
    end

    test "excludes a peer issued alongside it" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, first} = Venues.issue_grant(scope)
      {:ok, second} = Venues.issue_grant(scope)
      first_scope = EmployerScope.for_grant(scope.venue_id, first.id, @now)

      assert Venues.revoke_grant(first_scope, second.id) == {:error, :not_found}
    end

    test "reports a grant outside the set as not found, disclosing nothing" do
      # `:not_found` rather than an authorisation error, and the same answer a
      # grant belonging to another venue gets — so a caller cannot use the
      # refusal to learn which grants exist.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {_other_scope, %{grant: stranger}} = scoped_venue_fixture(%{}, @now)
      {:ok, child} = Venues.issue_grant(scope)
      child_scope = EmployerScope.for_grant(scope.venue_id, child.id, @now)

      assert Venues.revoke_grant(child_scope, stranger.id) == {:error, :not_found}
      assert Venues.revoke_grant(child_scope, Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "revocation is not transitive" do
    test "leaves the grants a revoked grant issued live" do
      # Authority at a venue is not a delegation that evaporates when its
      # issuer leaves: the people a departing manager engaged are still
      # engaged. The alternative is one call closing an unbounded number of
      # authorities, which is the shape of an accident.
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, middle} = Venues.issue_grant(scope)
      middle_scope = EmployerScope.for_grant(scope.venue_id, middle.id, @now)
      {:ok, leaf} = Venues.issue_grant(middle_scope)

      {:ok, _revoked} = Venues.revoke_grant(scope, middle.id)

      later = EmployerScope.for_grant(scope.venue_id, founding.id, @later)
      assert {:ok, grants} = Venues.list_grants(later)
      assert Enum.map(grants, & &1.id) == [founding.id, leaf.id]
    end

    test "leaves an ancestor's reach over the orphaned descendant intact" do
      # Which is what makes non-transitivity survivable rather than a way to
      # strand a live grant nobody can close. The revoked link is still a row,
      # so the walk through it still resolves.
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)
      {:ok, middle} = Venues.issue_grant(scope)
      middle_scope = EmployerScope.for_grant(scope.venue_id, middle.id, @now)
      {:ok, leaf} = Venues.issue_grant(middle_scope)

      {:ok, _revoked} = Venues.revoke_grant(scope, middle.id)

      later = EmployerScope.for_grant(scope.venue_id, founding.id, @later)

      assert {:ok, %EmployerGrant{id: id}} = Venues.revoke_grant(later, leaf.id)
      assert id == leaf.id
    end
  end

  describe "revoke_grant/2" do
    test "reports a grant that is not the venue's as not found" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {_other_scope, %{grant: other_grant}} = scoped_venue_fixture(%{}, @now)

      assert Venues.revoke_grant(scope, other_grant.id) == {:error, :not_found}
    end

    test "reports an already-revoked grant as not found rather than revoking it twice" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)
      {:ok, revoked} = Venues.revoke_grant(scope, second.id)

      later = EmployerScope.for_grant(scope.venue_id, scope.grant_id, @later)

      assert Venues.revoke_grant(later, second.id) == {:error, :not_found}

      assert DateTime.compare(reload_grant(later, second.id).revoked_at, revoked.revoked_at) ==
               :eq
    end

    test "reports one revoked at a later instant as not found, rather than moving it back" do
      # The other direction of the same rule, and the one an instant-ordered
      # check does not get for free: at 12:00 a grant revoked at 13:00 is
      # still live, so it matches the live set and a second revocation would
      # stamp `revoked_at` an hour earlier than the first one did.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)

      later = EmployerScope.for_grant(scope.venue_id, scope.grant_id, @later)
      {:ok, revoked} = Venues.revoke_grant(later, second.id)

      assert Venues.revoke_grant(scope, second.id) == {:error, :not_found}

      assert DateTime.compare(reload_grant(later, second.id).revoked_at, revoked.revoked_at) ==
               :eq
    end

    test "closes the grant half-open: the revocation instant is already outside it" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)

      revoking = EmployerScope.for_grant(scope.venue_id, scope.grant_id, @later)
      {:ok, _revoked} = Venues.revoke_grant(revoking, second.id)

      # At the revocation instant the grant is gone; a second before it, it is
      # not. No instant falls in both states, which is the property every
      # period in this application is built on.
      at_revocation = EmployerScope.for_grant(scope.venue_id, second.id, @later)
      just_before = EmployerScope.for_grant(scope.venue_id, second.id, a_second_before(@later))

      assert Venues.fetch_venue(at_revocation) == {:error, :no_grant}
      assert {:ok, %Venue{}} = Venues.fetch_venue(just_before)
    end
  end

  describe "the grant a scope acts under" do
    test "is resolved against the database rather than believed" do
      # A revoked grant stops working on the next call with no job having run
      # and no session having been torn down, which is the same derived-from-
      # time property engagements get from their period.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)

      acting = EmployerScope.for_grant(scope.venue_id, second.id, @now)
      assert {:ok, %Venue{}} = Venues.fetch_venue(acting)

      {:ok, _revoked} = Venues.revoke_grant(scope, second.id)

      after_revocation = EmployerScope.for_grant(scope.venue_id, second.id, @later)
      assert Venues.fetch_venue(after_revocation) == {:error, :no_grant}
    end

    test "must belong to the venue the scope names" do
      {_scope, %{venue: venue}} = scoped_venue_fixture(%{}, @now)
      {_other_scope, %{grant: other_grant}} = scoped_venue_fixture(%{}, @now)

      forged = EmployerScope.for_grant(venue.id, other_grant.id, @now)

      assert Venues.fetch_venue(forged) == {:error, :no_grant}
      assert Venues.list_grants(forged) == {:error, :no_grant}
      assert Venues.list_shift_types(forged) == {:error, :no_grant}
    end

    test "must be present at all, and its absence is a function clause" do
      # `for_employer/2` builds a scope with tenancy and no authority. Nothing
      # in this context has a head that matches it, so the refusal happens
      # before the body runs rather than inside it.
      {_scope, %{venue: venue}} = scoped_venue_fixture(%{}, @now)
      grantless = scope_of(:grantless, venue.id)

      assert_raise FunctionClauseError, fn -> Venues.fetch_venue(grantless) end
      assert_raise FunctionClauseError, fn -> Venues.list_grants(grantless) end
      assert_raise FunctionClauseError, fn -> Venues.issue_grant(grantless) end
      assert_raise FunctionClauseError, fn -> Venues.list_shift_types(grantless) end

      assert_raise FunctionClauseError, fn ->
        Venues.revoke_grant(grantless, Ecto.UUID.generate())
      end

      assert_raise FunctionClauseError, fn ->
        Venues.create_shift_type(grantless, venue.id, valid_shift_type_attributes())
      end
    end
  end

  describe "issue_grant/1" do
    test "records the grant it descended from" do
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)

      assert {:ok, %EmployerGrant{granted_by_grant_id: parent_id, venue_id: venue_id}} =
               Venues.issue_grant(scope)

      assert parent_id == founding.id
      assert venue_id == scope.venue_id
    end

    test "cannot descend from a grant at another venue" do
      {_scope, %{venue: venue}} = scoped_venue_fixture(%{}, @now)
      {_other, %{grant: other_grant}} = scoped_venue_fixture(%{}, @now)

      forged = EmployerScope.for_grant(venue.id, other_grant.id, @now)

      assert Venues.issue_grant(forged) == {:error, :no_grant}
    end
  end

  describe "list_grants/1" do
    test "returns live grants oldest first rather than in primary key order" do
      # "oldest first" was a docstring the query did not implement: it ordered
      # by `id`, which is random on a `binary_id` schema. Every other
      # assertion in this file matches a single-element list, which any order
      # satisfies — so this is the first one that can tell the two apart.
      #
      # The planted ids are chosen so that id order and instant order
      # disagree: the newest grant sorts first by id and the oldest sorts
      # last.
      {scope, %{grant: founding}} = scoped_venue_fixture(%{}, @now)

      newest = planted_grant(scope, "00000000-0000-4000-8000-000000000000", @later)
      oldest = planted_grant(scope, "ffffffff-ffff-4fff-bfff-ffffffffffff", @earlier)

      reading = EmployerScope.for_grant(scope.venue_id, founding.id, @even_later)

      assert {:ok, grants} = Venues.list_grants(reading)
      assert Enum.map(grants, & &1.id) == [oldest.id, founding.id, newest.id]
    end
  end

  describe "create_shift_type/3" do
    test "rejects a grace period above two hours" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)

      assert {:error, changeset} = create_shift_type(scope, %{grace_period_minutes: 121})
      assert ["must be less than or equal to 120"] = errors_on(changeset).grace_period_minutes
    end

    test "accepts a grace period of exactly two hours" do
      # The boundary. "Above two hours is rejected" is not "two hours is
      # rejected", and a `less_than` written where `less_than_or_equal_to`
      # belongs passes every other test in this block.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)

      assert {:ok, %ShiftType{grace_period_minutes: 120}} =
               create_shift_type(scope, %{grace_period_minutes: 120})
    end

    test "accepts a grace period of zero" do
      # Zero closes the room at shift end and is an ordinary configuration, not
      # a missing value — so `validate_required` must not treat it as absent.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)

      assert {:ok, %ShiftType{grace_period_minutes: 0}} =
               create_shift_type(scope, %{grace_period_minutes: 0})
    end

    test "rejects a negative grace period" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)

      assert {:error, changeset} = create_shift_type(scope, %{grace_period_minutes: -1})
      assert ["must be greater than or equal to 0"] = errors_on(changeset).grace_period_minutes
    end

    test "rejects a shift type with no name" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)

      assert {:error, changeset} =
               Venues.create_shift_type(scope, scope.venue_id, %{grace_period_minutes: 0})

      assert "can't be blank" in errors_on(changeset).name
    end

    test "cannot be attached to a venue the session does not hold a grant for" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {other_scope, %{venue: other_venue}} = scoped_venue_fixture(%{}, @now)

      assert Venues.create_shift_type(scope, other_venue.id, valid_shift_type_attributes()) ==
               {:error, :no_grant}

      # And nothing landed at the other venue either, which is the half a
      # refusal on its own does not prove.
      assert {:ok, []} = Venues.list_shift_types(other_scope)
    end

    test "cannot be attached by a session whose grant has been revoked" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {:ok, second} = Venues.issue_grant(scope)
      {:ok, _revoked} = Venues.revoke_grant(scope, second.id)

      revoked_scope = EmployerScope.for_grant(scope.venue_id, second.id, @later)

      assert Venues.create_shift_type(
               revoked_scope,
               scope.venue_id,
               valid_shift_type_attributes()
             ) == {:error, :no_grant}
    end

    test "refuses a second shift type with the same name at one venue" do
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      attrs = valid_shift_type_attributes(%{name: "Close"})

      assert {:ok, %ShiftType{}} = Venues.create_shift_type(scope, scope.venue_id, attrs)
      assert {:error, changeset} = Venues.create_shift_type(scope, scope.venue_id, attrs)
      assert "has already been taken" in errors_on(changeset).venue_id
    end

    test "allows the same name at a different venue" do
      # The control: the uniqueness is per venue, and a global one would be a
      # cross-tenant coupling nobody asked for.
      {scope, _creation} = scoped_venue_fixture(%{}, @now)
      {other, _other_creation} = scoped_venue_fixture(%{}, @now)
      attrs = valid_shift_type_attributes(%{name: "Close"})

      assert {:ok, %ShiftType{}} = Venues.create_shift_type(scope, scope.venue_id, attrs)
      assert {:ok, %ShiftType{}} = Venues.create_shift_type(other, other.venue_id, attrs)
    end
  end

  describe "the check constraints behind the validations" do
    # Written as raw SQL through the application's own role with every
    # changeset bypassed. A validation the database does not also hold is a
    # validation that an `insert_all`, a backfill, or a future context walks
    # around without noticing.

    test "reject a grace period above two hours" do
      venue_id = raw_venue()

      assert_raise Postgrex.Error, ~r/shift_types_grace_within_two_hours/, fn ->
        raw_shift_type(venue_id, 121)
      end
    end

    test "reject a negative grace period" do
      venue_id = raw_venue()

      assert_raise Postgrex.Error, ~r/shift_types_grace_within_two_hours/, fn ->
        raw_shift_type(venue_id, -1)
      end
    end

    test "accept a grace period inside the bound" do
      # The control. Without it the two above pass on a constraint that rejects
      # every value, which is a different bug with the same green ticks.
      venue_id = raw_venue()

      assert %{num_rows: 1} = raw_shift_type(venue_id, 0)
    end

    test "reject a blank timezone" do
      assert_raise Postgrex.Error, ~r/venues_timezone_present/, fn -> raw_venue("   ") end
    end

    test "reject a grant revoked before it was issued" do
      venue_id = raw_venue()

      assert_raise Postgrex.Error, ~r/employer_grants_revoked_after_granted/, fn ->
        raw_grant(venue_id, granted_at: @later, revoked_at: @now)
      end
    end

    test "reject a grant that issued itself" do
      venue_id = raw_venue()
      id = Ecto.UUID.generate()

      assert_raise Postgrex.Error, ~r/employer_grants_not_self_issued/, fn ->
        raw_grant(venue_id, id: id, granted_by_grant_id: id)
      end
    end

    test "reject a grant whose lineage belongs to another venue" do
      # The composite foreign key doing the job the plain one could not: with
      # `REFERENCES employer_grants (id)` this row would be accepted and a
      # venue's grant would descend from a stranger's.
      venue_id = raw_venue()
      other_venue_id = raw_venue()
      other_grant_id = Ecto.UUID.generate()

      raw_grant(other_venue_id, id: other_grant_id)

      assert_raise Postgrex.Error, ~r/employer_grants_granted_by_fkey/, fn ->
        raw_grant(venue_id, granted_by_grant_id: other_grant_id)
      end
    end

    test "accept a lineage inside one venue" do
      # The control for the one above.
      venue_id = raw_venue()
      parent_id = Ecto.UUID.generate()

      raw_grant(venue_id, id: parent_id)

      assert %{num_rows: 1} = raw_grant(venue_id, granted_by_grant_id: parent_id)
    end
  end

  describe "reading the employer zone" do
    test "a venue with two shift types and one grant-holder is readable through its own scope" do
      # The unit's verification, end to end.
      {scope, %{venue: venue, grant: grant}} = scoped_venue_fixture(%{name: "The Anchor"}, @now)

      open = shift_type_fixture(scope, %{name: "Open", grace_period_minutes: 0})
      close = shift_type_fixture(scope, %{name: "Close", grace_period_minutes: 120})

      assert {:ok, %Venue{id: id, name: "The Anchor", timezone: "Europe/Zagreb"}} =
               Venues.fetch_venue(scope)

      assert id == venue.id

      assert {:ok, [%EmployerGrant{id: grant_id}]} = Venues.list_grants(scope)
      assert grant_id == grant.id

      assert {:ok, shift_types} = Venues.list_shift_types(scope)
      assert Enum.sort(Enum.map(shift_types, & &1.id)) == Enum.sort([open.id, close.id])
    end

    test "and is absent from another venue's scope" do
      # The control that makes "its own scope" mean anything. With one venue in
      # the database every read test above passes on a query with no filter at
      # all.
      {scope, _creation} = scoped_venue_fixture(%{name: "The Anchor"}, @now)
      shift_type_fixture(scope, %{name: "Open"})

      {other, %{venue: other_venue}} = scoped_venue_fixture(%{name: "The Ship"}, @now)

      assert {:ok, %Venue{name: "The Ship"}} = Venues.fetch_venue(other)
      assert {:ok, []} = Venues.list_shift_types(other)
      assert {:ok, [%EmployerGrant{venue_id: venue_id}]} = Venues.list_grants(other)
      assert venue_id == other_venue.id
    end

    test "cannot be asked for a venue other than the scope's, because there is no argument" do
      # Structural rather than filtered: `fetch_venue/1` takes no id, so a
      # cross-venue read is unrepresentable instead of refused.
      assert function_exported?(Venues, :fetch_venue, 1)
      refute function_exported?(Venues, :fetch_venue, 2)
    end
  end

  ## Helpers

  # Scopes handed out of a map so that their type at the call site is the union
  # of every kind rather than the one kind the compiler can prove has no
  # matching clause. Written inline, Elixir 1.20 proves the refusal at compile
  # time and warns at the call site — which is the guarantee holding a step
  # earlier than this file can assert it, and is a good warning and a bad test:
  # a scope built at run time from a session carries no such proof, and it is
  # the run-time refusal the boundary rests on. `HospitalityComs.BoundaryTest`
  # does the same thing for the same reason.
  defp scope_of(kind, venue_id \\ Ecto.UUID.generate()) do
    Map.fetch!(
      %{
        person: PersonScope.for_person(unpersisted_person(), @now),
        anonymous: PersonScope.for_person(nil, @now),
        granted: EmployerScope.for_grant(venue_id, Ecto.UUID.generate(), @now),
        grantless: EmployerScope.for_employer(venue_id, @now)
      },
      kind
    )
  end

  defp create_shift_type(scope, attrs) do
    Venues.create_shift_type(scope, scope.venue_id, valid_shift_type_attributes(attrs))
  end

  # Live grant ids at a venue, read outside the context so the context's own
  # filter is not what is being asserted. The scope carries no grant: reading
  # the employer zone needs tenancy, and authority is the context's business.
  defp live_grant_ids(venue_id) do
    employer_work(venue_id, fn ->
      EmployerRepo.all(
        from grant in EmployerGrant,
          where: grant.venue_id == ^venue_id and is_nil(grant.revoked_at),
          order_by: [asc: grant.granted_at, asc: grant.id],
          select: grant.id
      )
    end)
  end

  defp employer_count(schema) do
    employer_work(Ecto.UUID.generate(), fn -> EmployerRepo.aggregate(schema, :count) end)
  end

  defp reload_grant(scope, id) do
    employer_work(scope.venue_id, fn -> EmployerRepo.get!(EmployerGrant, id) end)
  end

  defp employer_work(venue_id, fun) do
    scope = EmployerScope.for_employer(venue_id, @now)
    {:ok, result} = EmployerRepo.scoped_transaction(scope, fn _scope -> {:ok, fun.()} end)
    result
  end

  # A grant with a chosen id and a chosen instant, written through the employer
  # repo so the context can see it. Ordering by id and ordering by instant are
  # indistinguishable until the two disagree, and on a `binary_id` schema only
  # a chosen id can make them disagree.
  defp planted_grant(scope, id, granted_at) do
    employer_work(scope.venue_id, fn ->
      scope.venue_id
      |> EmployerGrant.issued_changeset(scope.grant_id, granted_at)
      |> Ecto.Changeset.put_change(:id, id)
      |> EmployerRepo.insert!()
    end)
  end

  defp a_second_before(instant), do: DateTime.add(instant, -1, :second)

  defp person_naming?(field) do
    field |> Atom.to_string() |> String.contains?("person")
  end

  ## Raw SQL, for the constraints underneath

  defp raw_venue(timezone \\ "Europe/Zagreb") do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO venues (id, name, timezone, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, now(), now())
        RETURNING id::text
        """,
        ["Raw #{System.unique_integer([:positive])}", timezone]
      )

    id
  end

  defp raw_shift_type(venue_id, grace) do
    Repo.query!(
      """
      INSERT INTO shift_types (id, venue_id, name, grace_period_minutes, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, $3, now(), now())
      """,
      [raw_uuid(venue_id), "Raw #{System.unique_integer([:positive])}", grace]
    )
  end

  defp raw_grant(venue_id, opts) do
    Repo.query!(
      """
      INSERT INTO employer_grants
        (id, venue_id, granted_by_grant_id, granted_at, revoked_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, now(), now())
      """,
      [
        opts |> Keyword.get(:id, Ecto.UUID.generate()) |> raw_uuid(),
        raw_uuid(venue_id),
        opts |> Keyword.get(:granted_by_grant_id) |> raw_uuid(),
        Keyword.get(opts, :granted_at, @now),
        Keyword.get(opts, :revoked_at)
      ]
    )
  end

  # Postgrex binds a `uuid` parameter as sixteen raw bytes, not as the hex form
  # the rest of the application passes around.
  defp raw_uuid(nil), do: nil
  defp raw_uuid(uuid), do: Ecto.UUID.dump!(uuid)
end
