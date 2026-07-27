defmodule HospitalityComs.Engagements.Records do
  @moduledoc """
  Every query the engagement lifecycle asks, in one module.

  `HospitalityComs.Engagements` is the public API and this is where its
  `where` clauses live, for the reason `AGENTS.md` gives: a query rebuilt at a
  call site is a query that can drift from the one three call sites over. It
  matters more than usual here, because two of these clauses *are* the
  authorization model — "active" and "holds a grant" are not filters on an
  answer, they are the answer.

  ## Every function takes the instant

  None of them reads a clock. The instant is captured once at the unit-of-work
  boundary and carried on the scope (KTD5), and a query module that reached for
  `Clock.now/0` would let two queries in one request disagree about which side
  of a period boundary the work fell on — one seeing an engagement as active
  while the next saw it expired. `active_at/2` names the instant in its
  signature for that reason and not as a convenience.

  `Ecto.Query.ago/2` and `from_now/2` are banned project-wide and a Credo check
  enforces it: they expand to `DateTime.utc_now/0` *inside* the query macro,
  where the injected clock cannot reach them and where the check would not see
  them if the call itself were not flagged.

  ## Half-open, spelled the way the rule reads

  `starts_at <= instant AND ends_at > instant`. The table also keeps a generated
  `tstzrange` — `period` — but only the exclusion constraint reads it. The two
  cannot disagree: `period` is `GENERATED ALWAYS AS tstzrange(starts_at,
  ends_at, '[)')`, so the range and the predicate are the same statement written
  twice on purpose, once where Postgres can index it and once where a person can
  read it.

  ## These queries carry no tenancy of their own

  `of_venue/2` exists and is used, but nothing here assumes a caller remembered
  it. Employer reads run through `HospitalityComs.EmployerRepo` inside the
  transaction wrapper, and every table these queries touch carries a row-level
  security policy on the venue that wrapper writes — so a composition that
  forgot `of_venue/2` comes back empty rather than with somebody else's venue.
  The filters are what make the queries mean what they say; the policy is what
  makes a mistake safe.
  """

  import Ecto.Query

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Profiles.AttestedEntry

  ## Engagements

  @doc """
  Engagements whose term contains `instant`.

  Half-open: an engagement is returned at its `starts_at` and is not returned at
  its `ends_at`. That is what makes two adjacent terms unambiguous and what
  makes ending an engagement take effect at the instant it names rather than a
  second later.

  This is the whole of the authorization model for venue membership. Advancing
  the clock past `ends_at` excludes the person from it with no job having run,
  which is R2 and the unit's verification condition.
  """
  @spec active_at(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def active_at(queryable, %DateTime{} = instant) do
    from engagement in queryable,
      where: engagement.starts_at <= ^instant,
      where: engagement.ends_at > ^instant
  end

  @doc """
  Engagements whose term has closed at or before `instant`.

  The complement of `active_at/2` on the upper side only — an engagement that
  has not started yet is in neither set, which is KTD13's
  confirmed-but-not-yet-active state.
  """
  @spec ended_by(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def ended_by(queryable, %DateTime{} = instant) do
    from engagement in queryable, where: engagement.ends_at <= ^instant
  end

  @doc """
  Engagements at one venue.
  """
  @spec of_venue(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def of_venue(queryable, venue_id) when is_binary(venue_id) do
    from engagement in queryable, where: engagement.venue_id == ^venue_id
  end

  @doc """
  Engagements held by one person, across every venue.

  Person-scoped rather than venue-scoped, and therefore read through
  `HospitalityComs.Repo`: an employer session asking this question would be
  asking where else somebody works, which is the disclosure U9 governs and not
  a query any employer scope may run.
  """
  @spec of_person(Ecto.Queryable.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def of_person(queryable, person_id) when is_binary(person_id) do
    from engagement in queryable, where: engagement.person_id == ^person_id
  end

  @doc """
  Engagements that hold one of the venue's administrative authorities.

  `grant_id` is null on an ordinary worker. Combined with `active_at/2`, this is
  the set `HospitalityComs.Engagements.end_engagement/2` counts before it agrees
  to close one (R22, KTD17): a venue whose last grant-holding engagement ends is
  a venue nobody can administer.
  """
  @spec holding_authority(Ecto.Queryable.t()) :: Ecto.Query.t()
  def holding_authority(queryable) do
    from engagement in queryable, where: not is_nil(engagement.grant_id)
  end

  @doc """
  Oldest term first, with `id` breaking ties.

  Ordering by `id` alone is random on a `binary_id` schema, so "oldest first"
  would be a sentence the query did not implement. `(starts_at, id)` is a total
  order, which is also what keeps `FOR UPDATE` acquiring locks deterministically
  in `HospitalityComs.Engagements.end_engagement/2` — two sessions block rather
  than deadlock.
  """
  @spec oldest_first(Ecto.Queryable.t()) :: Ecto.Query.t()
  def oldest_first(queryable) do
    from engagement in queryable, order_by: [asc: engagement.starts_at, asc: engagement.id]
  end

  @doc """
  One engagement of one venue, by id.
  """
  @spec engagement(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def engagement(venue_id, engagement_id) when is_binary(engagement_id) do
    Engagement |> of_venue(venue_id) |> where([e], e.id == ^engagement_id)
  end

  ## Invitations

  @doc """
  The invitation a claim code redeems, if it is still redeemable at `instant`.

  Never resolved and then acted on. This is the predicate of the conditional
  `UPDATE` that consumes the invitation as the first step of the claim's
  `Ecto.Multi` — read-then-write would let two claimants both read a claimable
  invitation and both proceed, and their engagements name different people so
  the exclusion constraint would say nothing about it.

  Half-open on the code's expiry too: a code expiring at exactly `instant` is
  expired, matching every other period in the application.
  """
  @spec claimable(binary(), DateTime.t()) :: Ecto.Query.t()
  def claimable(digest, %DateTime{} = instant) when is_binary(digest) do
    from invitation in Invitation,
      where: invitation.claim_code_digest == ^digest,
      where: is_nil(invitation.claimed_at),
      where: invitation.code_expires_at > ^instant
  end

  @doc """
  The invitation a claim code names, redeemable or not.

  Only ever used to say *why* a consume matched no row — already claimed, code
  expired, or no such code. The three refusals are distinguished after the fact
  because one statement cannot both be race-free and explain itself, and a
  diagnosis that runs only on the failure path can never turn a refusal into a
  success.
  """
  @spec by_digest(binary()) :: Ecto.Query.t()
  def by_digest(digest) when is_binary(digest) do
    from invitation in Invitation, where: invitation.claim_code_digest == ^digest
  end

  @doc """
  A venue's invitations that are still claimable at `instant`, oldest first.
  """
  @spec outstanding_invitations(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def outstanding_invitations(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    from invitation in Invitation,
      where: invitation.venue_id == ^venue_id,
      where: is_nil(invitation.claimed_at),
      where: invitation.code_expires_at > ^instant,
      order_by: [asc: invitation.issued_at, asc: invitation.id]
  end

  ## Attested entries

  @doc """
  The attested entries of one venue's engagements, oldest first.

  `employer_role` holds no privilege on this table (KTD3), so this query runs
  through `HospitalityComs.Repo` — from the person's side, or from U9's
  owner-privileged view. It is here rather than in a profiles query module
  because U5 is what writes the rows, and a query nobody can run from the
  context that owns it is a query that grows a second copy.
  """
  @spec attested_entries_of_venue(Ecto.UUID.t()) :: Ecto.Query.t()
  def attested_entries_of_venue(venue_id) when is_binary(venue_id) do
    from entry in AttestedEntry,
      where: entry.venue_id == ^venue_id,
      order_by: [asc: entry.attested_at, asc: entry.id]
  end

  @doc """
  The attested entries belonging to one person, across every venue.

  Reached through the bridge, which is the only way to reach them: there is no
  `person_id` on `attested_entries` and there will not be one.
  """
  @spec attested_entries_of_person(Ecto.UUID.t()) :: Ecto.Query.t()
  def attested_entries_of_person(person_id) when is_binary(person_id) do
    from entry in AttestedEntry,
      join: engagement in Engagement,
      on: engagement.id == entry.engagement_id,
      where: engagement.person_id == ^person_id,
      order_by: [asc: entry.attested_at, asc: entry.id]
  end
end
