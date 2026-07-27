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
  alias HospitalityComs.Venues.EmployerGrant

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
  Engagements whose term has *not* closed by `instant`.

  The exact complement of `ended_by/2`, and wider than `active_at/2` by one
  state: an engagement that has been claimed and has not started yet is in this
  set and not in that one. `HospitalityComs.Engagements.end_engagement/2` is
  the only caller that wants the wider set, because a term it can still move is
  a term it can still close.
  """
  @spec not_ended_by(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def not_ended_by(queryable, %DateTime{} = instant) do
    from engagement in queryable, where: engagement.ends_at > ^instant
  end

  @doc """
  Engagements whose term closed in the half-open window `(since, instant]`.

  The lower bound is what makes an unattended sweep able to keep up.
  `ended_by/2` alone grows without limit, so a bounded sweep over it examines
  the same oldest rows for ever and never reaches a term that closed this
  morning. Half-open on the same side as every other period here, so two
  consecutive windows neither overlap nor leave a gap.
  """
  @spec ended_between(Ecto.Queryable.t(), DateTime.t(), DateTime.t()) :: Ecto.Query.t()
  def ended_between(queryable, %DateTime{} = since, %DateTime{} = instant) do
    queryable |> ended_by(instant) |> not_ended_by(since)
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
  The rows `HospitalityComs.Engagements.end_engagement/2` locks and decides on:
  every engagement of the venue holding a *live* authority at `instant`, plus
  the one it has been asked to close.

  Both halves in one `where`, because the decision is one question — is this
  venue's last authority-holding engagement the one being closed — and asking it
  in two queries is asking it twice about a set that can move in between.

  "Holds an authority" is `grant_id` naming a grant that is live at `instant`,
  not `grant_id` being set, and the difference runs in both directions. An
  engagement whose grant was revoked yesterday is not a holder: counting it lets
  the venue's real manager be ended and leaves nobody able to administer it, and
  it also means the powerless engagement can never itself be ended, because it
  counts as authority it does not hold. `EmployerGrant.live_at/2` is the
  predicate `HospitalityComs.Venues` already treats as canonical, and this is
  the same one.

  It is a subquery rather than a join on purpose. `FOR UPDATE` over a join locks
  every relation in it, so a join would take row locks on `employer_grants` as
  well, in an order this function does not control and
  `HospitalityComs.Venues.revoke_grant/2` does not share. A subquery in `where`
  adds no locked relation.

  `starts_at <= instant` is applied to the survivors and not to the target: an
  engagement that has not started holds no authority *yet*, so it cannot be the
  last holder, but it can still be closed. The caller supplies the upper bound.
  """
  @spec decision_set(Ecto.Queryable.t(), Ecto.UUID.t(), DateTime.t(), Ecto.UUID.t()) ::
          Ecto.Query.t()
  def decision_set(queryable, venue_id, %DateTime{} = instant, engagement_id)
      when is_binary(venue_id) and is_binary(engagement_id) do
    live_grants = live_grant_ids(venue_id, instant)

    from engagement in queryable,
      where:
        (engagement.starts_at <= ^instant and engagement.grant_id in subquery(live_grants)) or
          engagement.id == ^engagement_id
  end

  @doc """
  The ids of a venue's grants that are live at `instant`.

  A projection of `HospitalityComs.Venues.EmployerGrant.live_at/2` rather than a
  second spelling of it, so that "live" cannot come to mean two things.
  """
  @spec live_grant_ids(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def live_grant_ids(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    venue_id |> EmployerGrant.live_at(instant) |> select([grant], grant.id)
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
  Most recently closed term first, with `id` breaking ties.

  Ordered by the column `ended_between/3` filters on, and in the direction that
  makes a bounded sweep converge: a limit applied to *oldest* first pins the
  sweep to the same rows for ever once more than a batch of terms have closed,
  so it keeps running, keeps reporting success, and never reaches a term that
  closed this morning. `oldest_first/1` stays the order for reads that want
  term order.
  """
  @spec newest_ended_first(Ecto.Queryable.t()) :: Ecto.Query.t()
  def newest_ended_first(queryable) do
    from engagement in queryable, order_by: [desc: engagement.ends_at, asc: engagement.id]
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

  **Returns whole structs, and one of their fields is `claim_code_digest`.**
  `employer_role` holds table-level `SELECT` on `invitations`, so the digest
  comes back with every row. It is SHA-256 of 32 random bytes and cannot be
  turned back into a code, so it is not a working credential — but an endpoint
  that renders one of these structs wholesale ships it to the client anyway. U6
  should render a field list rather than the struct.
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
