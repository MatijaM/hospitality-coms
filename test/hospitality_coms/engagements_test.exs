defmodule HospitalityComs.EngagementsTest do
  @moduledoc """
  The bridge: invitation, claim, fixed term, derived activeness, renewal, and
  ending.

  Four things are asserted here and they answer different questions.

  **That an invitation names nobody.** R1 says a person record is created by the
  person and by nobody else, and that an unclaimed invitation creates none. So
  the tests around issuance are about an *absence*: no person row, no person
  column, no access — and the code itself is asserted absent from the row that
  redeems it.

  **That activeness is derived.** Every test that ends or renews an engagement
  and then reads it passes a different instant rather than waiting, and the
  boundary instants are asserted on both sides. Advancing the injected clock
  past an upper bound excludes the person from membership with no job having
  run, and there is a test that says exactly that while looking at the job to
  confirm it has not.

  **That the three races have three different answers.** The exclusion
  constraint, the conditional consume, and the optimistic lock each guard a
  different failure, and none of them guards the other two.
  `HospitalityComs.EngagementsConcurrencyTest` holds the two that need real
  concurrency; what is here is the single-process half — that the constraint
  exists, that its violation is a tuple rather than a raise, and that a second
  redemption of one code is refused.

  **That the last grant-holding engagement cannot be ended.** U4 refuses to
  revoke a venue's last grant; this refuses to end the last engagement holding
  one. Neither invariant was weakened to make room for the other, and
  `HospitalityComs.VenuesTest` still asserts U4's exactly as it did.

  ## The controls

  Several assertions could pass for the wrong reason and ship with something
  that fails when they do:

    * the overlap rejection sits next to an adjacent-term acceptance, so a
      constraint that rejected everything would fail the pair.
    * `active_at/2` is asserted to *include* the lower bound, so an
      implementation that returned nothing would not pass.
    * the clock-advance test asserts membership *before* the advance.
    * the atomicity test asserts both rows are absent, having first asserted
      that a successful claim writes both.
    * every refusal that returns `:not_found` is paired with the call that
      succeeds, so a function that refused everything would fail.

  ## Why this file is not sandboxed

  The claim spans both repos' connections, and under the sandbox those are two
  transactions that cannot see each other. See
  `HospitalityComs.EngagementsFixtures`; the rows are committed and purged by a
  name prefix before and after every test.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: HospitalityComs.Repo

  import Ecto.Query
  import HospitalityComs.DataCase, only: [errors_on: 1]
  import HospitalityComs.EngagementsFixtures

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.EmployerRepo.ZoneViolationError
  alias HospitalityComs.Engagements
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Engagements.Records
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues
  alias HospitalityComs.Workers.ExpireEngagement

  @now ~U[2026-03-01 12:00:00.000000Z]
  @in_a_week DateTime.add(@now, 7, :day)
  @in_a_month DateTime.add(@now, 30, :day)
  @in_two_months DateTime.add(@now, 60, :day)

  setup do
    real_connections()
  end

  describe "issue_invitation/2" do
    test "creates no person record and grants no access" do
      # R1, stated as the absence it is. An invitation is an offer addressed to
      # whoever holds the code; until somebody claims it, the database knows of
      # no additional human and the venue has no additional member.
      {scope, _creation} = scoped_venue_fixture(@now)
      before = person_count()

      assert %{invitation: %Invitation{}} = invitation_fixture(scope)

      assert person_count() == before
      assert {:ok, []} = Engagements.list_engagements(scope)
    end

    test "records no contact identifier, because there is no column for one" do
      # The structural half. `HospitalityComs.VenuesTest` asserts the same rule
      # against the employer zone's three tables; this is the fourth, and it is
      # the one somebody would be most tempted to put an email on.
      fields = Invitation.__schema__(:fields)

      refute Enum.any?(fields, &person_naming?/1)
      refute Enum.any?(fields, &(&1 in [:email, :phone, :name]))
    end

    test "stores a digest of the claim code and never the code" do
      {scope, _creation} = scoped_venue_fixture(@now)

      %{invitation: invitation, claim_code: code} = invitation_fixture(scope)

      assert invitation.claim_code_digest == Invitation.digest(code)
      refute invitation.claim_code_digest == code
      assert byte_size(invitation.claim_code_digest) == 32
    end

    test "refuses a scope with no grant by function clause" do
      # Not a runtime check in the body. The refusal is the absence of a
      # matching head, so it happens whether or not whoever wrote the function
      # remembered to guard it.
      grantless = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      assert_raise FunctionClauseError, fn ->
        Engagements.issue_invitation(scope_of(:grantless, grantless), %{})
      end
    end

    test "refuses a scope whose grant has been revoked" do
      # Resolved against the database on every call rather than believed from
      # the struct, which is what makes revocation take effect with nothing
      # having run.
      {scope, %{venue: venue, grant: founding}} = scoped_venue_fixture(@now)
      {:ok, second} = Venues.issue_grant(scope)
      {:ok, _revoked} = Venues.revoke_grant(scope, second.id)

      revoked_scope = EmployerScope.for_grant(venue.id, second.id, @now)

      assert Engagements.issue_invitation(revoked_scope, valid_invitation_attributes(%{}, @now)) ==
               {:error, :no_grant}

      # The control: the founding grant still works, so the refusal above is
      # about the revoked grant rather than about the venue.
      assert %{invitation: %Invitation{}} =
               invitation_fixture(EmployerScope.for_grant(venue.id, founding.id, @now))
    end

    test "refuses to confer an authority that is not live" do
      {scope, %{venue: venue}} = scoped_venue_fixture(@now)
      {:ok, second} = Venues.issue_grant(scope)
      {:ok, _revoked} = Venues.revoke_grant(scope, second.id)

      attrs = valid_invitation_attributes(%{grant_id: second.id}, @now)

      assert Engagements.issue_invitation(scope, attrs) == {:error, :grant_not_live}

      # The control. A live grant is conferrable, so the refusal is about the
      # revocation rather than about conferring at all.
      live = valid_invitation_attributes(%{grant_id: venue_founding_grant_id(venue.id)}, @now)
      assert {:ok, %{invitation: %Invitation{}}} = Engagements.issue_invitation(scope, live)
    end

    test "rejects a term whose end does not follow its start" do
      {scope, _creation} = scoped_venue_fixture(@now)

      attrs = valid_invitation_attributes(%{starts_at: @in_a_month, ends_at: @now}, @now)

      assert {:error, changeset} = Engagements.issue_invitation(scope, attrs)
      assert "must be after the start" in errors_on(changeset).ends_at
    end

    test "rejects a claim code that expires before it is issued" do
      {scope, _creation} = scoped_venue_fixture(@now)

      attrs =
        valid_invitation_attributes(%{code_expires_at: DateTime.add(@now, -1, :hour)}, @now)

      assert {:error, changeset} = Engagements.issue_invitation(scope, attrs)
      assert "must be after the invitation is issued" in errors_on(changeset).code_expires_at
    end

    test "rejects a claim code good for longer than a code may be good for" do
      # A claim code is a bearer credential that grants a state change to
      # whoever presents it first, and its lifetime was whatever the caller
      # asked for — a year, a decade — with no way to withdraw it afterwards.
      # The bound mirrors `PersonToken.session_validity_in_days/0`, which is the
      # other bearer credential in the tree.
      {scope, _creation} = scoped_venue_fixture(@now)

      too_long = DateTime.add(@now, Invitation.max_code_validity_in_days() + 1, :day)
      attrs = valid_invitation_attributes(%{code_expires_at: too_long}, @now)

      assert {:error, changeset} = Engagements.issue_invitation(scope, attrs)

      assert "must be within #{Invitation.max_code_validity_in_days()} day(s) of issue" in errors_on(
               changeset
             ).code_expires_at
    end

    test "accepts a claim code good for exactly the maximum, which is the control" do
      {scope, _creation} = scoped_venue_fixture(@now)

      limit = DateTime.add(@now, Invitation.max_code_validity_in_days(), :day)
      attrs = valid_invitation_attributes(%{code_expires_at: limit}, @now)

      assert {:ok, %{invitation: invitation}} = Engagements.issue_invitation(scope, attrs)
      assert DateTime.compare(invitation.code_expires_at, limit) == :eq
    end

    test "keeps the code's lifetime bounded in the database, not only in the changeset" do
      # The pairing `invitations_code_expiry_after_issue` already has: a write
      # that never passed through the changeset cannot get around the rule.
      {scope, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)

      assert_raise Postgrex.Error, ~r/invitations_code_expiry_within_bound/, fn ->
        Repo.insert_all(Invitation, [
          unbounded_invitation_row(venue, grant, DateTime.add(@now, 365, :day))
        ])
      end

      # The control: the same row inside the bound goes in.
      assert {1, _returned} =
               Repo.insert_all(Invitation, [
                 unbounded_invitation_row(venue, grant, DateTime.add(@now, 1, :day))
               ])

      assert {:ok, [_invitation]} = Engagements.list_invitations(scope)
    end

    test "reports a malformed conferred grant as a field error rather than raising" do
      # The conferred grant used to be resolved against the database before it
      # was cast, so a `grant_id` that is not a UUID reached Ecto's query
      # builder and raised `Ecto.Query.CastError` — out of a function whose
      # `@spec` promises a changeset.
      {scope, _creation} = scoped_venue_fixture(@now)

      attrs = valid_invitation_attributes(%{grant_id: "not-a-uuid"}, @now)

      assert {:error, %Ecto.Changeset{} = changeset} = Engagements.issue_invitation(scope, attrs)
      assert errors_on(changeset).grant_id == ["is invalid"]
    end

    test "rejects a blank role label" do
      {scope, _creation} = scoped_venue_fixture(@now)

      attrs = valid_invitation_attributes(%{role_label: "   "}, @now)

      assert {:error, changeset} = Engagements.issue_invitation(scope, attrs)
      assert "can't be blank" in errors_on(changeset).role_label
    end
  end

  describe "claim_invitation/2" do
    test "attaches an engagement to the claiming person's existing record" do
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      person = person_fixture(@now)
      scope = PersonScope.for_person(person, @now)
      before = person_count()

      %{claim_code: code} = invitation_fixture(employer)

      assert {:ok, %{engagement: engagement}} = Engagements.claim_invitation(scope, code)

      assert engagement.person_id == person.id
      assert engagement.venue_id == venue.id
      assert engagement.role_label == "Bartender"

      # The claim attached to a record that already existed rather than
      # creating one, which is R1 from the person's side.
      assert person_count() == before
      assert Repo.get!(Person, person.id).id == person.id
    end

    test "writes the engagement and the attested entry in one transaction" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      %{claim_code: code} = invitation_fixture(employer)

      assert {:ok, claim} = Engagements.claim_invitation(scope, code)

      assert %Engagement{} = claim.engagement
      assert %AttestedEntry{} = claim.attested_entry
      assert claim.attested_entry.engagement_id == claim.engagement.id
      assert claim.attested_entry.venue_id == claim.engagement.venue_id
      assert claim.consume.claimed_at
    end

    test "leaves neither row behind when a step after the engagement fails" do
      # A crash between the engagement and its attested entry would leave an
      # engagement with no portable history, which is the product. The failure
      # is manufactured with a constraint the attested entry cannot satisfy;
      # what is being asserted is the rollback, not the cause.
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      with_failing_attestation(fn ->
        assert_raise Ecto.ConstraintError, fn -> Engagements.claim_invitation(scope, code) end
      end)

      assert engagement_count(venue.id) == 0
      assert attested_entry_count(venue.id) == 0

      # And the invitation was not consumed either, so the code still works.
      assert Repo.get!(Invitation, invitation.id).claimed_at == nil
      assert {:ok, _claim} = Engagements.claim_invitation(scope, code)
    end

    test "cannot be redeemed twice" do
      {employer, _creation} = scoped_venue_fixture(@now)
      first = person_scope_fixture(@now)
      second = person_scope_fixture(@now)

      %{claim_code: code} = invitation_fixture(employer)

      assert {:ok, _claim} = Engagements.claim_invitation(first, code)

      assert {:error, :consume, :already_claimed, _changes} =
               Engagements.claim_invitation(second, code)
    end

    test "rejects a claim code that has expired" do
      {employer, _creation} = scoped_venue_fixture(@now)

      %{claim_code: code} =
        invitation_fixture(employer, %{code_expires_at: DateTime.add(@now, 1, :hour)})

      late = person_scope_fixture(DateTime.add(@now, 2, :hour))

      assert {:error, :consume, :code_expired, _changes} =
               Engagements.claim_invitation(late, code)

      # The control: the same code at an instant inside its validity works, so
      # the refusal is about the expiry rather than about the code.
      assert {:ok, _claim} =
               Engagements.claim_invitation(person_scope_fixture(@now), code)
    end

    test "rejects a claim code at exactly its expiry, because bounds are half-open" do
      {employer, _creation} = scoped_venue_fixture(@now)
      expires_at = DateTime.add(@now, 1, :hour)

      %{claim_code: code} = invitation_fixture(employer, %{code_expires_at: expires_at})

      assert {:error, :consume, :code_expired, _changes} =
               Engagements.claim_invitation(person_scope_fixture(expires_at), code)
    end

    test "rejects a code that names nothing, and says so without disclosing" do
      scope = person_scope_fixture(@now)

      assert {:error, :consume, :unknown_code, _changes} =
               Engagements.claim_invitation(scope, "not-a-code")
    end

    test "refuses an anonymous person scope by function clause" do
      anonymous = PersonScope.for_person(nil, @now)

      assert_raise FunctionClauseError, fn ->
        Engagements.claim_invitation(scope_of(:anonymous, anonymous), "anything")
      end
    end

    test "refuses to mint an engagement holding an authority revoked since issue" do
      # `issue_invitation/2` checks the conferred grant is live when the offer
      # is written, and an offer is good for as long as its code is. Without
      # this the claim mints a manager whose authority was revoked in between —
      # an engagement that counts as a holder and can do nothing, which is the
      # same unadministrable venue from the other side.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      {:ok, conferred} = Venues.issue_grant(employer)
      %{claim_code: code} = invitation_fixture(employer, %{grant_id: conferred.id})

      {:ok, _closed} = Venues.revoke_grant(employer, conferred.id)

      assert {:error, :conferrable, :grant_not_live, _changes} =
               Engagements.claim_invitation(scope, code)
    end

    test "mints one holding an authority that is still live, which is the control" do
      {employer, %{grant: founding}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      %{claim_code: code} = invitation_fixture(employer, %{grant_id: founding.id})

      assert {:ok, %{engagement: engagement}} = Engagements.claim_invitation(scope, code)
      assert engagement.grant_id == founding.id
    end

    test "schedules the expiry announcement at the term's upper bound" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      %{claim_code: code} = invitation_fixture(employer)
      {:ok, %{engagement: engagement}} = Engagements.claim_invitation(scope, code)

      assert_enqueued(
        worker: ExpireEngagement,
        args: %{engagement_id: engagement.id, venue_id: engagement.venue_id}
      )
    end

    test "puts no person in the job's arguments" do
      # A job's args are a `jsonb` column in a table in `public`, and KTD2's
      # rule about where a human may be named does not stop at the schemas this
      # application owns.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      %{claim_code: code} = invitation_fixture(employer)
      {:ok, %{engagement: engagement}} = Engagements.claim_invitation(scope, code)

      [job] = all_enqueued(worker: ExpireEngagement)

      refute Enum.any?(Map.keys(job.args), &person_naming?/1)
      refute engagement.person_id in Map.values(job.args)
    end
  end

  describe "the exclusion constraint" do
    test "rejects two overlapping terms for one person at one venue" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      _first = engagement_fixture(employer, scope)

      %{claim_code: code} =
        invitation_fixture(employer, %{
          starts_at: DateTime.add(@now, 5, :day),
          ends_at: DateTime.add(@now, 10, :day)
        })

      assert {:error, :engagement, changeset, _changes} =
               Engagements.claim_invitation(scope, code)

      assert changeset.errors[:period]
    end

    test "returns a tuple rather than raising, which is what naming it buys" do
      # Without the constraint's name on both the migration and the changeset,
      # the violation arrives as a `Postgrex.Error` raised through the
      # transaction and the enumerated-error convention is a lie at the one
      # place it is load bearing.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      _first = engagement_fixture(employer, scope)
      %{claim_code: code} = invitation_fixture(employer)

      result = Engagements.claim_invitation(scope, code)

      assert {:error, :engagement, %Ecto.Changeset{}, _changes} = result

      assert "overlaps an engagement this person already holds at this venue" in errors_on(
               elem(result, 2)
             ).period
    end

    test "accepts two adjacent terms sharing a boundary instant" do
      # The control for both tests above: a constraint that rejected everything
      # would satisfy them and fail this. `[a, b)` and `[b, c)` do not overlap,
      # which is the half-open convention doing the work it was chosen for.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      first = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      %{claim_code: code} =
        invitation_fixture(employer, %{starts_at: @in_a_month, ends_at: @in_two_months})

      assert {:ok, %{engagement: second}} = Engagements.claim_invitation(scope, code)

      refute second.id == first.id
      assert DateTime.compare(second.starts_at, first.ends_at) == :eq
    end

    test "does not stop one person holding terms at two venues at once" do
      # The key is `(person_id, venue_id, period)`, so concurrent engagements
      # at different employers are ordinary — and they are what U9's
      # concurrency-hiding default is about.
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      assert %Engagement{} = engagement_fixture(first_employer, scope)
      assert %Engagement{} = engagement_fixture(second_employer, scope)

      assert length(Engagements.list_person_engagements(scope)) == 2
    end
  end

  describe "activeness, which nothing stores" do
    test "includes the lower bound and excludes the upper" do
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @in_a_week, ends_at: @in_a_month})

      assert active_ids_at(venue, grant, @in_a_week) == [engagement.id]

      assert active_ids_at(venue, grant, DateTime.add(@in_a_month, -1, :second)) ==
               [engagement.id]

      assert active_ids_at(venue, grant, @in_a_month) == []
    end

    test "excludes an engagement accepted before its start date" do
      # KTD13. Acceptance and the start are different instants, and an
      # engagement claimed before the term opens is confirmed and not yet
      # active — which falls out of the predicate rather than needing a rule.
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @in_a_week, ends_at: @in_a_month})

      assert DateTime.compare(engagement.accepted_at, @now) == :eq
      assert DateTime.compare(engagement.starts_at, @in_a_week) == :eq

      assert active_ids_at(venue, grant, @now) == []
      assert active_ids_at(venue, grant, @in_a_week) == [engagement.id]
    end

    test "stops including a person once the clock passes the upper bound, with no job having run" do
      # The unit's verification condition. The membership query is the same
      # query at both instants; what changed is the instant.
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      assert active_ids_at(venue, grant, @now) == [engagement.id]
      assert active_ids_at(venue, grant, DateTime.add(@in_a_month, 1, :day)) == []

      # And the person's own view of it moved too, at the same instant and for
      # the same reason.
      later = PersonScope.for_person(scope.person, DateTime.add(@in_a_month, 1, :day))
      assert Engagements.list_person_engagements(later) == []

      # Nothing ran. The expiry job the claim scheduled is still waiting, and
      # the engagement's row is exactly as it was written.
      [job] = all_enqueued(worker: ExpireEngagement)
      assert job.state in ["scheduled", "available"]
      assert job.attempt == 0

      reloaded = Repo.get!(Engagement, engagement.id)
      assert DateTime.compare(reloaded.ends_at, engagement.ends_at) == :eq
      assert reloaded.lock_version == engagement.lock_version
    end

    test "keeps the whole history readable even once none of it is active" do
      # KTD16 gives engagements and attested entries no retention deadline at
      # all, deliberately: they are the person's record rather than the
      # employer's.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})
      later = PersonScope.for_person(scope.person, DateTime.add(@in_a_month, 1, :day))

      assert Engagements.list_person_engagements(later) == []
      assert Enum.map(Engagements.list_person_history(later), & &1.id) == [engagement.id]
      assert length(Engagements.list_person_attested_entries(later)) == 1
    end
  end

  describe "renew_engagement/3" do
    test "extends the same engagement rather than creating a second" do
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      assert {:ok, renewed} =
               Engagements.renew_engagement(employer, engagement.id, @in_two_months)

      assert renewed.id == engagement.id
      assert DateTime.compare(renewed.ends_at, @in_two_months) == :eq
      assert renewed.lock_version == engagement.lock_version + 1
      assert engagement_count(venue.id) == 1
    end

    test "produces no second attested entry" do
      # The unique index on `attested_entries.engagement_id` is what makes this
      # structural rather than a property of whoever wrote the renewal.
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope)
      assert attested_entry_count(venue.id) == 1

      assert {:ok, _renewed} =
               Engagements.renew_engagement(employer, engagement.id, @in_two_months)

      assert attested_entry_count(venue.id) == 1
    end

    test "extends membership past the instant that used to end it" do
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      assert active_ids_at(venue, grant, @in_a_month) == []

      assert {:ok, _renewed} =
               Engagements.renew_engagement(employer, engagement.id, @in_two_months)

      assert active_ids_at(venue, grant, @in_a_month) == [engagement.id]
    end

    test "refuses one that would not move the upper bound once it is written" do
      # `ends_at` is compared at whatever precision the caller passed and
      # written truncated to the second, so a renewal half a second past the
      # current bound used to answer `{:ok, _}` having moved nothing — while
      # consuming the optimistic lock, so a concurrent renewal that *would*
      # have moved it failed as stale in its place.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})
      within_the_second = DateTime.add(engagement.ends_at, 500, :millisecond)

      assert Engagements.renew_engagement(employer, engagement.id, within_the_second) ==
               {:error, :not_an_extension}

      reloaded = Repo.get!(Engagement, engagement.id)
      assert reloaded.lock_version == engagement.lock_version
      assert DateTime.compare(reloaded.ends_at, engagement.ends_at) == :eq

      # The control: a second later is a real extension and is accepted.
      assert {:ok, renewed} =
               Engagements.renew_engagement(
                 employer,
                 engagement.id,
                 DateTime.add(engagement.ends_at, 1, :second)
               )

      assert renewed.lock_version == engagement.lock_version + 1
    end

    test "refuses anything that is not an extension" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      assert Engagements.renew_engagement(employer, engagement.id, @in_a_week) ==
               {:error, :not_an_extension}

      assert Engagements.renew_engagement(employer, engagement.id, engagement.ends_at) ==
               {:error, :not_an_extension}

      # The control: an extension is accepted, so the refusals are about the
      # direction rather than about renewal.
      assert {:ok, _renewed} =
               Engagements.renew_engagement(employer, engagement.id, @in_two_months)
    end

    test "reports another venue's engagement as not found" do
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(first_employer, scope)

      assert Engagements.renew_engagement(second_employer, engagement.id, @in_two_months) ==
               {:error, :not_found}
    end
  end

  describe "end_engagement/2" do
    test "closes the term at the scope's instant, half-open" do
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})
      ending = employer_scope_at(venue, grant, @in_a_week)

      assert active_ids_at(venue, grant, @in_a_week) == [engagement.id]
      assert {:ok, ended} = Engagements.end_engagement(ending, engagement.id)
      assert DateTime.compare(ended.ends_at, @in_a_week) == :eq

      # The instant it ends already belongs to the ended side.
      assert active_ids_at(venue, grant, @in_a_week) == []

      assert active_ids_at(venue, grant, DateTime.add(@in_a_week, -1, :second)) ==
               [engagement.id]
    end

    test "at the instant the term opened leaves a term containing no instant" do
      # The one state in which an engagement's term is empty, and it is
      # reachable only this way: an invitation's term is strictly ordered, so
      # nothing can be *created* with no duration. The empty range contains no
      # instant, so the person is a member at none — and it overlaps nothing,
      # so they can be engaged again over the same dates.
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      assert {:ok, ended} = Engagements.end_engagement(employer, engagement.id)
      assert DateTime.compare(ended.ends_at, ended.starts_at) == :eq

      assert active_ids_at(venue, grant, @now) == []
      refute Engagements.active?(ended, @now)

      # And the dates are free again, which is what "overlaps nothing" means.
      assert %Engagement{} =
               engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})
    end

    test "leaves another venue's engagement for the same person untouched" do
      # R4. The two engagements are the same human at two employers, and ending
      # one is not an event the other participates in.
      {first_employer, first} = scoped_venue_fixture(@now)
      {second_employer, second} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      at_first = engagement_fixture(first_employer, scope)
      at_second = engagement_fixture(second_employer, scope)

      assert {:ok, _ended} = Engagements.end_engagement(second_employer, at_second.id)

      assert active_ids_at(first.venue, first.grant, @now) == [at_first.id]
      assert active_ids_at(second.venue, second.grant, @now) == []
      assert Enum.map(Engagements.list_person_engagements(scope), & &1.id) == [at_first.id]
    end

    test "reports an already-ended engagement as not found" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope)

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)
      assert Engagements.end_engagement(employer, engagement.id) == {:error, :not_found}
    end

    test "closes an engagement that has not started at the instant its term opens" do
      # A claim made in error is claimed *before* the term opens more often than
      # after, and the engagement it produced occupies the exclusion constraint
      # for its whole term whether or not it is active — so while this was
      # `:not_found`, a corrected engagement over the same dates was refused and
      # the person's dates were reserved by a mistake nobody could take back.
      #
      # Closing it at `starts_at` rather than at the caller's instant is what
      # keeps the write representable: `ends_at >= starts_at`, producing the
      # empty range the schema already permits.
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @in_a_week, ends_at: @in_a_month})

      assert {:ok, ended} = Engagements.end_engagement(employer, engagement.id)
      assert ended.id == engagement.id
      assert DateTime.compare(ended.ends_at, engagement.starts_at) == :eq

      # Active at no instant, at either edge of the term it used to have.
      assert active_ids_at(venue, grant, @in_a_week) == []
      assert active_ids_at(venue, grant, @now) == []

      # And the dates are free again, which is the point.
      assert %Engagement{} =
               engagement_fixture(employer, scope, %{
                 starts_at: @in_a_week,
                 ends_at: @in_a_month
               })
    end

    test "still reports an engagement whose term has already closed as not found" do
      # The bound on the widening above. "Active or not yet started" is one
      # state wider than "active"; it is not "any engagement at all", and an
      # ended one stays `:not_found` so a second ending cannot move a closed
      # term.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_week})

      later = employer_scope_at_venue(employer, DateTime.add(@in_a_week, 1, :day))

      assert Engagements.end_engagement(later, engagement.id) == {:error, :not_found}
    end

    test "leaves a not-yet-started engagement out of every read, as it always was" do
      # The widening is on the ending path alone. `list_engagements/1` and
      # `fetch_engagement/2` still answer at the scope's instant, and renewal
      # still reaches only what is active.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @in_a_week, ends_at: @in_a_month})

      assert {:ok, []} = Engagements.list_engagements(employer)
      assert Engagements.fetch_engagement(employer, engagement.id) == {:error, :not_found}

      assert Engagements.renew_engagement(employer, engagement.id, @in_two_months) ==
               {:error, :not_found}
    end

    test "reports another venue's engagement as not found" do
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(first_employer, scope)

      assert Engagements.end_engagement(second_employer, engagement.id) == {:error, :not_found}

      # The control, and the reason this is not a function that refuses
      # everything.
      assert {:ok, _ended} = Engagements.end_engagement(first_employer, engagement.id)
    end

    test "broadcasts the revocation after the transaction commits" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope)
      :ok = Engagements.subscribe(engagement.id)

      assert {:ok, _ended} = Engagements.end_engagement(employer, engagement.id)

      assert_receive {:engagement_revoked, %{engagement_id: id, venue_id: venue_id}}
      assert id == engagement.id
      assert venue_id == engagement.venue_id
    end

    test "broadcasts nothing when the write is refused" do
      # KTD8 the other way round: a broadcast for a change that did not happen
      # would disconnect clients whose access never ended.
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{grant_id: grant.id})
      :ok = Engagements.subscribe(engagement.id)

      assert Engagements.end_engagement(employer, engagement.id) ==
               {:error, :last_grant_holder}

      refute_receive {:engagement_revoked, _payload}
      assert active_ids_at(venue, grant, @now) == [engagement.id]
    end
  end

  describe "the last grant-holding engagement" do
    test "cannot be ended, because the venue would have an authority nobody holds" do
      # R22 and KTD17's other half. `HospitalityComs.Venues.revoke_grant/2`
      # refuses to close the venue's last live *grant*; this refuses to end the
      # last engagement *holding* one. Neither rule was changed to make room
      # for the other.
      {employer, %{grant: grant}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      manager = engagement_fixture(employer, scope, %{grant_id: grant.id})

      assert Engagements.end_engagement(employer, manager.id) == {:error, :last_grant_holder}
    end

    test "is not what an ordinary worker's engagement is" do
      # The control. A venue with one manager and one bartender must let the
      # bartender go.
      {employer, %{grant: grant}} = scoped_venue_fixture(@now)
      manager_scope = person_scope_fixture(@now)
      worker_scope = person_scope_fixture(@now)

      _manager = engagement_fixture(employer, manager_scope, %{grant_id: grant.id})
      worker = engagement_fixture(employer, worker_scope)

      assert {:ok, ended} = Engagements.end_engagement(employer, worker.id)
      assert ended.id == worker.id
    end

    test "stops being the last one once a second engagement holds a grant" do
      {employer, %{venue: venue, grant: founding}} = scoped_venue_fixture(@now)
      first = person_scope_fixture(@now)
      second = person_scope_fixture(@now)

      {:ok, issued} = Venues.issue_grant(employer)

      original = engagement_fixture(employer, first, %{grant_id: founding.id})
      _successor = engagement_fixture(employer, second, %{grant_id: issued.id})

      assert {:ok, ended} = Engagements.end_engagement(employer, original.id)
      assert ended.id == original.id

      # And the venue is back to one holder, so that one cannot go either.
      assert length(active_ids_at(venue, founding, @now)) == 1
    end

    test "counts holders whose grant is live, not holders whose grant column is set" do
      # The security half. `grant_id` being non-null says an engagement was
      # *given* an authority, not that it still holds one: the grant behind it
      # may have been revoked yesterday. Counting it leaves the venue with one
      # apparent manager who can do nothing, the real one ended, and no way back
      # in — an unadministrable venue, which is the exact state R22 exists to
      # prevent.
      {employer, %{grant: founding}} = scoped_venue_fixture(@now)
      first = person_scope_fixture(@now)
      second = person_scope_fixture(@now)

      {:ok, revoked} = Venues.issue_grant(employer)

      _powerless = engagement_fixture(employer, second, %{grant_id: revoked.id})
      real = engagement_fixture(employer, first, %{grant_id: founding.id})

      {:ok, _closed} = Venues.revoke_grant(employer, revoked.id)

      assert Engagements.end_engagement(employer, real.id) == {:error, :last_grant_holder}
    end

    test "is not what an engagement holding a revoked grant is" do
      # The liveness half of the same mistake, and it points the other way: an
      # engagement whose grant was revoked counted as authority it did not hold,
      # so it could never be ended either. The venue was stuck with a row it
      # could not remove and a person it could not release.
      # Nobody holds the founding grant, so the engagement below is the venue's
      # only grant-*holding* one — and its grant is revoked, so it holds no
      # authority at all.
      {employer, %{venue: venue, grant: founding}} = scoped_venue_fixture(@now)
      departing = person_scope_fixture(@now)

      {:ok, revoked} = Venues.issue_grant(employer)
      powerless = engagement_fixture(employer, departing, %{grant_id: revoked.id})

      {:ok, _closed} = Venues.revoke_grant(employer, revoked.id)

      assert {:ok, ended} = Engagements.end_engagement(employer, powerless.id)
      assert ended.id == powerless.id
      assert active_ids_at(venue, founding, @now) == []
    end

    test "counts holders that are active, not holders that have a row" do
      # The same distinction U4 makes about live grants. A manager whose own
      # engagement has already ended is not a holder any more, and counting
      # them would leave the venue unadministrable from the instant they left.
      {employer, %{venue: venue, grant: founding}} = scoped_venue_fixture(@now)
      first = person_scope_fixture(@now)
      second = person_scope_fixture(@now)

      {:ok, issued} = Venues.issue_grant(employer)

      departing =
        engagement_fixture(employer, first, %{
          grant_id: issued.id,
          starts_at: @now,
          ends_at: @in_a_week
        })

      remaining = engagement_fixture(employer, second, %{grant_id: founding.id})

      assert {:ok, _ended} = Engagements.end_engagement(employer, departing.id)

      later = employer_scope_at(venue, founding, DateTime.add(@in_a_week, 1, :day))
      assert Engagements.end_engagement(later, remaining.id) == {:error, :last_grant_holder}
    end
  end

  describe "reading the bridge" do
    test "is per venue: another venue's engagements are absent" do
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)

      at_first = engagement_fixture(first_employer, person_scope_fixture(@now))
      at_second = engagement_fixture(second_employer, person_scope_fixture(@now))

      assert {:ok, [%Engagement{id: first_id}]} = Engagements.list_engagements(first_employer)
      assert {:ok, [%Engagement{id: second_id}]} = Engagements.list_engagements(second_employer)

      assert first_id == at_first.id
      assert second_id == at_second.id
    end

    test "is per person on the person's side, across venues" do
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)
      other = person_scope_fixture(@now)

      mine = [
        engagement_fixture(first_employer, scope).id,
        engagement_fixture(second_employer, scope).id
      ]

      _theirs = engagement_fixture(first_employer, other)

      assert Enum.sort(Enum.map(Engagements.list_person_engagements(scope), & &1.id)) ==
               Enum.sort(mine)
    end

    test "refuses an employer scope on the person's side by function clause" do
      {employer, _creation} = scoped_venue_fixture(@now)

      assert_raise FunctionClauseError, fn ->
        Engagements.list_person_engagements(scope_of(:employer, employer))
      end
    end

    test "fetches one of the venue's own engagements by id" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      assert {:ok, %Engagement{id: id}} = Engagements.fetch_engagement(employer, engagement.id)
      assert id == engagement.id
    end

    test "reports another venue's engagement, and an id that names nothing, as not found" do
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)

      engagement = engagement_fixture(first_employer, person_scope_fixture(@now))

      assert Engagements.fetch_engagement(second_employer, engagement.id) ==
               {:error, :not_found}

      assert Engagements.fetch_engagement(first_employer, Ecto.UUID.generate()) ==
               {:error, :not_found}
    end

    test "refuses a fetch under a grant that has been revoked" do
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)

      engagement = engagement_fixture(employer, person_scope_fixture(@now))

      {:ok, second} = Venues.issue_grant(employer)
      {:ok, _revoked} = Venues.revoke_grant(employer, second.id)

      revoked_scope = EmployerScope.for_grant(venue.id, second.id, @now)

      assert Engagements.fetch_engagement(revoked_scope, engagement.id) == {:error, :no_grant}
    end

    test "lists outstanding invitations and drops them once claimed" do
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      %{invitation: invitation, claim_code: code} = invitation_fixture(employer)

      assert {:ok, [%Invitation{id: id}]} = Engagements.list_invitations(employer)
      assert id == invitation.id

      assert {:ok, _claim} = Engagements.claim_invitation(scope, code)
      assert {:ok, []} = Engagements.list_invitations(employer)
    end

    test "drops an invitation whose code has expired, with no job having run" do
      {employer, %{venue: venue, grant: grant}} = scoped_venue_fixture(@now)

      _issued = invitation_fixture(employer, %{code_expires_at: @in_a_week})

      assert {:ok, [%Invitation{}]} = Engagements.list_invitations(employer)

      later = employer_scope_at(venue, grant, DateTime.add(@in_a_week, 1, :second))
      assert {:ok, []} = Engagements.list_invitations(later)
    end
  end

  describe "the bridge's row-level security" do
    # `HospitalityComs.BoundaryTest` asserts the policy exists and is not
    # `FORCE`d; what it cannot assert is the behaviour, because populating the
    # bridge needs a person and a venue visible to one connection and that file
    # holds two sandbox transactions that cannot see each other's rows. This
    # file commits, so it can.

    test "hides another venue's engagements from a query with no filter at all" do
      # Deliberately unfiltered. Nothing in the query says which venue, so what
      # answers is the policy rather than the context.
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)

      at_first = engagement_fixture(first_employer, person_scope_fixture(@now))
      at_second = engagement_fixture(second_employer, person_scope_fixture(@now))

      assert unfiltered_engagement_ids(first_employer) == [at_first.id]
      assert unfiltered_engagement_ids(second_employer) == [at_second.id]
    end

    test "bounds an unfiltered update to the venue the transaction is scoped to" do
      # U4's exploit aimed at the one table that names a human. Before the
      # policy, this call ended every engagement at every venue in one
      # statement, and it passed the unscoped guard, the zone guard and
      # Postgres on the way.
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, second} = scoped_venue_fixture(@now)

      _at_first = engagement_fixture(first_employer, person_scope_fixture(@now))
      at_second = engagement_fixture(second_employer, person_scope_fixture(@now))

      assert {count, _returned} = end_everything(first_employer)
      assert count == 1

      assert active_ids_at(second.venue, second.grant, @now) == [at_second.id]
    end

    test "leaves the bridge readable from the person's side, which is why it is not FORCEd" do
      # The property that lets one table serve both zones. `Repo` owns
      # `engagements` and the policy is not `FORCE`d, so a person's own view of
      # their engagements crosses no venue at all — which is exactly what an
      # employer session must never be able to do.
      {first_employer, _first} = scoped_venue_fixture(@now)
      {second_employer, _second} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      at_first = engagement_fixture(first_employer, scope)
      at_second = engagement_fixture(second_employer, scope)

      assert Enum.sort(Enum.map(Engagements.list_person_engagements(scope), & &1.id)) ==
               Enum.sort([at_first.id, at_second.id])
    end
  end

  describe "the query backstop, meeting the bridge" do
    test "refuses an employer query that joins an engagement to its person" do
      # The association exists because the person's side needs it, and it is a
      # rope an employer-scoped query could climb. The backstop names the table
      # before Postgres names the role.
      {employer, _creation} = scoped_venue_fixture(@now)

      query = from(e in Engagement, join: p in assoc(e, :person), select: p.id)

      assert_raise ZoneViolationError, ~r/people/, fn ->
        EmployerRepo.scoped_transaction(employer, fn _scope ->
          {:ok, EmployerRepo.all(query)}
        end)
      end
    end

    test "does not refuse the engagement on its own, which is the shared zone working" do
      # The control. `engagements` is `:shared` rather than person-zone, so an
      # employer session reads it — and a backstop that refused the bridge
      # outright would make the employer's own membership query impossible.
      {employer, _creation} = scoped_venue_fixture(@now)

      assert {:ok, []} = Engagements.list_engagements(employer)
    end

    test "refuses an employer session that tries to insert an engagement" do
      # No INSERT on `engagements` for `employer_role`, deliberately: an
      # engagement is created only by the person claiming a code. Ecto has no
      # insert-path hook that sees a table, so this reaches Postgres and is
      # refused by the grant tier — which is the only tier that is a guarantee.
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      %{invitation: invitation} = invitation_fixture(employer)
      person = person_fixture(@now)

      assert_raise Postgrex.Error, ~r/permission denied for table engagements/, fn ->
        EmployerRepo.scoped_transaction(employer, fn scope ->
          {:ok,
           EmployerRepo.insert!(Engagement.claim_changeset(invitation, person.id, scope.now))}
        end)
      end

      assert engagement_count(venue.id) == 0
    end
  end

  describe "Records.active_at/2" do
    test "takes the instant explicitly rather than reading a clock" do
      # Which is what makes every boundary in this file assertable, and what
      # the Credo check enforces from the other side.
      {employer, %{venue: venue}} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement = engagement_fixture(employer, scope, %{starts_at: @now, ends_at: @in_a_month})

      query = Records.of_venue(Engagement, venue.id)

      assert query |> Records.active_at(@now) |> Repo.all() |> Enum.map(& &1.id) ==
               [engagement.id]

      assert query |> Records.active_at(@in_a_month) |> Repo.all() == []
    end

    test "is the same predicate active?/2 spells in Elixir" do
      # Two spellings of one rule is one more than ideal; this is what says
      # they agree at the boundaries, which is where they would differ.
      {employer, _creation} = scoped_venue_fixture(@now)
      scope = person_scope_fixture(@now)

      engagement =
        engagement_fixture(employer, scope, %{starts_at: @in_a_week, ends_at: @in_a_month})

      assert Engagements.active?(engagement, @in_a_week)
      refute Engagements.active?(engagement, @in_a_month)
      refute Engagements.active?(engagement, @now)
    end
  end

  ## Helpers

  # Scopes handed out of a map so that their type at the call site is the union
  # of every kind rather than the one kind the compiler can prove has no
  # matching clause. Written inline, Elixir 1.20 proves the refusal at compile
  # time and warns at the call site — a good warning and a bad test, because a
  # scope built at run time from a session carries no such proof and it is the
  # run-time refusal the boundary rests on. `HospitalityComs.VenuesTest` does
  # the same thing for the same reason.
  defp scope_of(kind, scope) do
    Map.fetch!(
      %{
        anonymous: scope,
        grantless: scope,
        employer: scope
      },
      kind
    )
  end

  defp employer_scope_at(venue, grant, instant) do
    EmployerScope.for_grant(venue.id, grant.id, instant)
  end

  defp employer_scope_at_venue(%EmployerScope{} = scope, instant) do
    EmployerScope.for_grant(scope.venue_id, scope.grant_id, instant)
  end

  # Membership, asked through the context so that what is asserted is the
  # answer callers get rather than a query written for the test.
  defp active_ids_at(venue, grant, instant) do
    {:ok, engagements} = Engagements.list_engagements(employer_scope_at(venue, grant, instant))
    Enum.map(engagements, & &1.id)
  end

  defp venue_founding_grant_id(venue_id) do
    Repo.one!(
      from grant in HospitalityComs.Venues.EmployerGrant,
        where: grant.venue_id == ^venue_id and is_nil(grant.granted_by_grant_id),
        select: grant.id
    )
  end

  # Deliberately unfiltered, and read as `employer_role`: what decides the
  # answer is the row-level security policy rather than anything in the query.
  defp unfiltered_engagement_ids(scope) do
    as_employer(scope, fn ->
      EmployerRepo.all(from(e in "engagements", select: type(e.id, Ecto.UUID)))
    end)
  end

  defp end_everything(scope) do
    as_employer(scope, fn ->
      EmployerRepo.update_all(Engagement, set: [ends_at: scope.now])
    end)
  end

  defp as_employer(scope, fun) do
    {:ok, result} = EmployerRepo.scoped_transaction(scope, fn _scope -> {:ok, fun.()} end)
    result
  end

  # An invitation written straight at the table, so that what refuses it is the
  # check constraint rather than the changeset that would normally have
  # refused it first.
  defp unbounded_invitation_row(venue, grant, code_expires_at) do
    stamped_at = DateTime.truncate(@now, :second)

    %{
      id: Ecto.UUID.generate(),
      venue_id: venue.id,
      issued_by_grant_id: grant.id,
      role_label: "Bartender",
      starts_at: stamped_at,
      ends_at: DateTime.add(stamped_at, 30, :day),
      claim_code_digest: :crypto.strong_rand_bytes(32),
      code_expires_at: DateTime.truncate(code_expires_at, :second),
      issued_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    }
  end

  defp person_count, do: Repo.aggregate(Person, :count)

  defp engagement_count(venue_id) do
    Repo.aggregate(from(e in Engagement, where: e.venue_id == ^venue_id), :count)
  end

  defp attested_entry_count(venue_id) do
    Repo.aggregate(from(e in AttestedEntry, where: e.venue_id == ^venue_id), :count)
  end

  defp person_naming?(field) do
    field |> to_string() |> String.contains?("person")
  end

  # A constraint no insert can satisfy, so that the step after the engagement
  # fails for certain. `NOT VALID` skips the existing rows and still binds every
  # new one, which is exactly what is wanted: the table keeps whatever this file
  # has already written and refuses the next write.
  #
  # Dropped in an `after`, because this file is not sandboxed and a DDL left
  # behind would fail every test that ran after it.
  defp with_failing_attestation(fun) do
    Repo.query!(
      "ALTER TABLE attested_entries ADD CONSTRAINT u5_forced_failure CHECK (false) NOT VALID"
    )

    try do
      fun.()
    after
      Repo.query!("ALTER TABLE attested_entries DROP CONSTRAINT u5_forced_failure")
    end
  end
end
