defmodule HospitalityComs.Engagements do
  @moduledoc """
  The bridge between the two zones: invitation, claim, fixed term, derived
  activeness, renewal, ending, and the scheduled revocation that follows expiry.

  `engagements.person_id` is the only column anywhere outside the person zone
  that names a human (KTD2), and this context is the only code that writes it.
  Everything below follows from that being *one* crossing rather than four.

  ## Three callers, three roles, and the claim is none of them

  An employer session issues invitations, renews and ends engagements, and lists
  the venue's own. Those run through `HospitalityComs.EmployerRepo` inside
  `scoped_transaction/2`, under a grant resolved against the database on every
  call, exactly as `HospitalityComs.Venues` does.

  A person lists their own engagements and their own attested entries. Those run
  through `HospitalityComs.Repo` and are filtered by `person_id`, because "where
  else does this person work" is a question no employer scope may ask — U9's
  disclosure rules govern the answer.

  **The claim is neither.** It reads an invitation the claimant was handed a
  code for, writes the bridge row, writes the attested entry that the employer
  role holds no privilege to write, and enqueues the expiry job — four writes
  spanning both zones, and no session on either side holds the privileges for
  all of them. So it runs as the application's own role, under a
  `HospitalityComs.Accounts.PersonScope`, and it is the only place in the
  codebase that does. That is not a loophole around the boundary; it is what the
  boundary is a boundary *between*.

  ## Activeness is derived and nothing stores it

  An engagement is active when `starts_at <= instant < ends_at`. Half-open
  (KTD4), so no instant falls in two consecutive terms and none falls in a gap,
  and the instant an engagement ends already belongs to the ended side. There is
  no status column and no job that sets one: advancing the clock past `ends_at`
  excludes the person from every membership query with nothing having run, which
  is the property the whole design exists for.

  Acceptance is not the start (KTD13). An engagement claimed before its start
  date is confirmed and not yet active, which falls out of the predicate rather
  than needing a rule.

  ## Three races, and each has a different answer

  **Two people redeem one claim code.** The exclusion constraint says nothing
  about this — the two engagements would name *different* people, so nothing
  overlaps. What answers it is the conditional consume: `claim_invitation/2`
  updates the invitation `WHERE claimed_at IS NULL AND code_expires_at > now` as
  the **first** step of its `Ecto.Multi` and requires exactly one affected row.
  The loser blocks on the winner's row lock, re-evaluates the predicate after it
  commits, matches nothing, and fails at a step with a name. A unique index on
  `engagements.invitation_id` is the backstop underneath.

  **Two people hold overlapping terms at one venue.** That one *is* the
  exclusion constraint, named `engagements_no_overlap` so that
  `HospitalityComs.Engagements.Engagement` can declare a matching
  `exclusion_constraint/3` and the violation arrives as a changeset error rather
  than raising through the transaction.

  **Two managers renew the same engagement.** A row does not conflict with
  itself, so neither of the above fires and one extension is silently discarded
  on the authorization root for everything that person can reach at the venue.
  `optimistic_lock(:lock_version)` is what makes the second one fail;
  `HospitalityComs.EngagementsConcurrencyTest` is what says so.

  ## The expiry worker writes nothing

  `HospitalityComs.Workers.ExpireEngagement` re-derives activeness at its own
  instant and broadcasts only when the engagement is no longer active. It never
  touches `engagements`, and that is not tidiness: a job scheduled for the old
  upper bound and delivered after a renewal would otherwise truncate the renewed
  term — a revocation caused by nothing but a queue's latency. Because it writes
  nothing, a stale job is inert, which is why `renew_engagement/3` does not have
  to find and cancel one.

  It also could not enqueue one atomically if it wanted to. Renewal runs inside
  an `EmployerRepo` transaction and Oban writes through `Repo`; the two are
  different pools addressing the same database, so a job inserted there would
  commit even if the renewal rolled back. `claim_invitation/2` is the only
  operation that enqueues, and it can, because it already runs through `Repo`.

  ## The last grant-holding engagement, and the half of KTD17 that lives here

  `HospitalityComs.Venues.revoke_grant/2` refuses to close a venue's last live
  grant. That invariant counts grant *rows*, which U4 recorded as an honest
  limitation: `employer_grants` names no holder, so "holder" meant nothing yet.

  This is the other half. `engagements.grant_id` is what makes a grant
  attributable, and `end_engagement/2` refuses to end a venue's last *active
  grant-holding engagement* — under `FOR UPDATE` on the locked set, for the same
  reason U4 locks: two managers each ending the other's engagement would each
  read two holders, each correctly conclude they were not removing the last, and
  together leave the venue with an authority nobody holds.

  Together the two refusals close both routes to an unadministrable venue: you
  cannot revoke the last authority, and you cannot end the last engagement that
  holds one. Neither invariant was changed to accommodate the other.

  Erasure is exempt from both (KTD17), and lives in U10.

  ## What this context deliberately cannot do

  It cannot delete anything. Deletion is confined to the lifecycle context
  (KTD21), so an engagement claimed in error is *closed* rather than removed:
  `end_engagement/2` takes it to `ends_at == starts_at`, which is the empty
  range — active at no instant, and overlapping nothing, so the person's dates
  are free again. That widening is on the ending path alone. Every read still
  answers on `active_at/2`, so a not-yet-started engagement is invisible to
  `list_engagements/1`, to `fetch_engagement/2` and to `renew_engagement/3`
  exactly as it was.

  Everything whose term has already closed stays `:not_found`, along with an
  engagement belonging to another venue and an id that names nothing, so the
  refusal still enumerates nothing.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Engagements.Records
  alias HospitalityComs.Profiles.AttestedEntry
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues
  alias HospitalityComs.Workers.ExpireEngagement

  @typedoc """
  What issuing an invitation produces: the row, and the code that redeems it.

  The code is returned exactly once. The row holds only its SHA-256 digest, so
  nothing — not this context, not a `SELECT`, not a backup — can recover it
  afterwards.
  """
  @type issued() :: %{invitation: Invitation.t(), claim_code: String.t()}

  @typedoc """
  What a successful claim writes, by `Ecto.Multi` step name.
  """
  @type claim() :: %{
          consume: Invitation.t(),
          conferrable: :confers_nothing | :confers_a_live_grant,
          engagement: Engagement.t(),
          attested_entry: AttestedEntry.t(),
          expiry_job: Oban.Job.t()
        }

  @typedoc """
  A failed claim, naming the step that failed.

  `Ecto.Multi`'s shape rather than a flattened `{:error, reason}`, matching
  `HospitalityComs.Venues.create_venue/2`: the steps fail for unrelated reasons
  and collapsing them would lose which. The `:consume` step is the one the loser
  of a two-claimant race lands on, and the reason distinguishes the three ways a
  code can be unredeemable.
  """
  @type claim_failure() ::
          {:error, :consume, :unknown_code | :already_claimed | :code_expired, map()}
          | {:error, :conferrable, :grant_not_live, map()}
          | {:error, :engagement, Ecto.Changeset.t(Engagement.t()), map()}
          | {:error, :attested_entry, Ecto.Changeset.t(AttestedEntry.t()), map()}
          | {:error, :expiry_job, Ecto.Changeset.t(Oban.Job.t()), map()}

  @typedoc """
  What an expiry attempt concluded, having written nothing.
  """
  @type expiry() :: :revoked | :still_active | :gone

  ## Issuing an invitation

  @doc """
  Issues an invitation carrying a single-use claim code, and returns the code.

  Refuses a scope with no grant by function clause, and a scope whose grant is
  not live at this venue with `:no_grant` — resolved against the database on
  every call, never believed from the struct.

  `attrs` carries `:role_label`, `:starts_at`, `:ends_at`, `:code_expires_at`,
  and optionally `:grant_id`. The last is the authority the resulting engagement
  will *hold*: an invitation to manage rather than to work. It is checked here
  against the venue's live grants — `:grant_not_live` otherwise — and the
  composite foreign key refuses one belonging to another venue whatever this
  function believes.

  No contact identifier is stored and no person row is created (R1). An
  unclaimed invitation names nobody and grants nothing.
  """
  @spec issue_invitation(EmployerScope.t(), map()) ::
          {:ok, issued()}
          | {:error, :no_grant | :grant_not_live | Ecto.Changeset.t(Invitation.t())}
  def issue_invitation(%EmployerScope{grant_id: grant_id} = scope, attrs)
      when is_binary(grant_id) and is_map(attrs) do
    EmployerRepo.scoped_transaction(scope, &write_invitation(&1, attrs))
  end

  @spec write_invitation(EmployerScope.t(), map()) ::
          {:ok, issued()}
          | {:error, :no_grant | :grant_not_live | Ecto.Changeset.t(Invitation.t())}
  defp write_invitation(scope, attrs) do
    with {:ok, authority} <- Venues.fetch_acting_grant(scope) do
      scope.venue_id
      |> Invitation.issue(authority.id, attrs, scope.now)
      |> insert_if_conferrable(scope)
    end
  end

  # The changeset is built *before* the conferred grant is resolved, and the
  # order is the fix rather than an accident of style: resolving first meant a
  # `grant_id` that is not a UUID reached Ecto's query builder uncast and raised
  # `Ecto.Query.CastError` out of a function whose `@spec` promises a changeset.
  # Cast first, and a malformed id is an ordinary field error.
  @spec insert_if_conferrable({Ecto.Changeset.t(Invitation.t()), String.t()}, EmployerScope.t()) ::
          {:ok, issued()}
          | {:error, :grant_not_live | Ecto.Changeset.t(Invitation.t())}
  defp insert_if_conferrable({changeset, code}, scope) do
    with :ok <- conferrable(changeset, scope) do
      changeset |> EmployerRepo.insert() |> with_code(code)
    end
  end

  @spec with_code({:ok, Invitation.t()} | {:error, Ecto.Changeset.t(Invitation.t())}, String.t()) ::
          {:ok, issued()} | {:error, Ecto.Changeset.t(Invitation.t())}
  defp with_code({:ok, invitation}, code), do: {:ok, %{invitation: invitation, claim_code: code}}
  defp with_code({:error, changeset}, _code), do: {:error, changeset}

  # An invitation that confers an authority has to confer a live one. The
  # composite foreign key already refuses another venue's grant; what it cannot
  # see is a grant this venue revoked yesterday, which would produce a manager
  # whose authority was gone before they accepted it.
  #
  # A changeset that is already invalid is left alone: the insert will return it
  # with its own errors, and asking the database about a grant named by a
  # changeset that will not be written is a question with no consequence.
  @spec conferrable(Ecto.Changeset.t(Invitation.t()), EmployerScope.t()) ::
          :ok | {:error, :grant_not_live}
  defp conferrable(%Ecto.Changeset{valid?: false}, _scope), do: :ok

  defp conferrable(changeset, scope) do
    changeset
    |> Ecto.Changeset.get_change(:grant_id)
    |> live_grant?(scope)
    |> conferrable_or_refuse()
  end

  @spec live_grant?(Ecto.UUID.t() | nil, EmployerScope.t()) :: boolean()
  defp live_grant?(nil, _scope), do: true

  defp live_grant?(grant_id, %EmployerScope{venue_id: venue_id, now: now}) do
    venue_id
    |> Records.live_grant_ids(now)
    |> where([grant], grant.id == ^grant_id)
    |> EmployerRepo.exists?()
  end

  @spec conferrable_or_refuse(boolean()) :: :ok | {:error, :grant_not_live}
  defp conferrable_or_refuse(true), do: :ok
  defp conferrable_or_refuse(false), do: {:error, :grant_not_live}

  @doc """
  The venue's invitations that are still claimable at the scope's instant.
  """
  @spec list_invitations(EmployerScope.t()) :: {:ok, [Invitation.t()]} | {:error, :no_grant}
  def list_invitations(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_invitations/1)
  end

  @spec read_invitations(EmployerScope.t()) :: {:ok, [Invitation.t()]} | {:error, :no_grant}
  defp read_invitations(scope) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok, EmployerRepo.all(Records.outstanding_invitations(scope.venue_id, scope.now))}
    end
  end

  ## Claiming

  @doc """
  Redeems a claim code, producing one engagement and one attested entry.

  Four writes in one transaction, and the order is the design:

    1. `:consume` — a conditional `UPDATE` of the invitation requiring exactly
       one affected row. First, so that two claimants racing the same code
       resolve here rather than three statements later where nothing would
       notice. The loser gets `{:error, :consume, :already_claimed, _}`.
    1a. `:conferrable` — the authority the invitation confers, if any, asked
       again. `issue_invitation/2` checked it when the offer was written and an
       offer is good for as long as its code is; without this a claim can mint a
       manager whose grant was revoked in between, which is a holder that holds
       nothing and the unadministrable venue R22 refuses. A refusal rolls the
       consume back with it, so the code is not spent.
    2. `:engagement` — the bridge row, built entirely from the invitation and
       the claimant. Nothing is cast from the caller: accepting an offer is
       accepting *the* offer, and a claim that could move its own start date
       would be a claim that could grant itself a year at a venue that offered a
       fortnight.
    3. `:attested_entry` — the person's portable record of the engagement. In
       the same transaction, because a crash between the two would leave an
       engagement with no history, which is the product.
    4. `:expiry_job` — scheduled at the term's upper bound, and inserted here so
       that a rolled-back claim enqueues nothing.

  Refuses an anonymous person scope by function clause: an engagement attaches
  to a person record that already exists, and there is no path here that creates
  one. That is R1 from the other side.

  The three ways a code can fail are distinguished after the consume matched
  nothing, by a read that only ever runs on the failure path — one statement
  cannot be both race-free and self-explaining, and a diagnosis that can only
  produce an error can never turn a refusal into a success.
  """
  @spec claim_invitation(PersonScope.t(), String.t()) :: {:ok, claim()} | claim_failure()
  def claim_invitation(%PersonScope{person: %Person{id: person_id}, now: now}, code)
      when is_binary(person_id) and is_binary(code) do
    digest = Invitation.digest(code)

    Multi.new()
    |> Multi.run(:consume, fn repo, _changes -> consume(repo, digest, now) end)
    |> Multi.run(:conferrable, fn repo, changes -> still_conferrable(repo, changes, now) end)
    # `mode: :savepoint` on both constrained inserts, and it is explicit
    # because `ecto_sql` opens a savepoint *only* when asked. Without it, a
    # constraint violation caught and turned into a changeset error leaves the
    # surrounding transaction aborted — which is invisible here today only
    # because each of these is the last statement before the `Multi` rolls
    # everything back. A step added after one would find a poisoned
    # transaction and fail for a reason that had nothing to do with it.
    |> Multi.insert(:engagement, &claimed_engagement(&1, person_id, now), mode: :savepoint)
    |> Multi.insert(:attested_entry, &attestation(&1, now), mode: :savepoint)
    |> Oban.insert(:expiry_job, &expiry_job/1)
    |> Repo.transaction()
  end

  # The race-safe half. One statement decides claimability and claims it, so
  # there is no window between reading and writing for a second claimant to
  # arrive in. `RETURNING` hands back the row the update actually matched, which
  # is the only invitation the rest of the Multi may build on.
  @spec consume(Ecto.Repo.t(), binary(), DateTime.t()) ::
          {:ok, Invitation.t()} | {:error, :unknown_code | :already_claimed | :code_expired}
  defp consume(repo, digest, now) do
    stamped_at = DateTime.truncate(now, :second)

    digest
    |> Records.claimable(now)
    |> select([invitation], invitation)
    |> repo.update_all(set: [claimed_at: stamped_at, updated_at: stamped_at])
    |> consumed(repo, digest, now)
  end

  @spec consumed(
          {non_neg_integer(), [Invitation.t()] | nil},
          Ecto.Repo.t(),
          binary(),
          DateTime.t()
        ) ::
          {:ok, Invitation.t()} | {:error, :unknown_code | :already_claimed | :code_expired}
  defp consumed({1, [invitation]}, _repo, _digest, _now), do: {:ok, invitation}

  defp consumed({0, _rows}, repo, digest, now) do
    digest |> Records.by_digest() |> repo.one() |> diagnose(now)
  end

  # Runs only when the consume matched nothing, so it cannot make a claim
  # succeed — the worst it can do is name the wrong one of three refusals, and
  # all three are refusals.
  @spec diagnose(Invitation.t() | nil, DateTime.t()) ::
          {:error, :unknown_code | :already_claimed | :code_expired}
  defp diagnose(nil, _now), do: {:error, :unknown_code}
  defp diagnose(%Invitation{claimed_at: %DateTime{}}, _now), do: {:error, :already_claimed}
  defp diagnose(%Invitation{}, _now), do: {:error, :code_expired}

  # `issue_invitation/2` checks the conferred authority is live when the offer
  # is written, and an offer is good for as long as its code is. Asking again
  # here is what stops a claim minting a manager whose grant was revoked in
  # between: an engagement that counts as a holder and can do nothing, which is
  # the unadministrable venue R22 refuses, arrived at from the claim's side.
  #
  # A refusal rolls the consume back with it, so the code stays claimable. That
  # is deliberate: the offer is not spent, and re-issuing the grant makes it
  # good again.
  @spec still_conferrable(Ecto.Repo.t(), map(), DateTime.t()) ::
          {:ok, :confers_nothing | :confers_a_live_grant} | {:error, :grant_not_live}
  defp still_conferrable(_repo, %{consume: %Invitation{grant_id: nil}}, _now) do
    {:ok, :confers_nothing}
  end

  defp still_conferrable(repo, %{consume: %Invitation{} = invitation}, now) do
    invitation.venue_id
    |> Records.live_grant_ids(now)
    |> where([grant], grant.id == ^invitation.grant_id)
    |> repo.exists?()
    |> still_live()
  end

  @spec still_live(boolean()) :: {:ok, :confers_a_live_grant} | {:error, :grant_not_live}
  defp still_live(true), do: {:ok, :confers_a_live_grant}
  defp still_live(false), do: {:error, :grant_not_live}

  @spec claimed_engagement(map(), Ecto.UUID.t(), DateTime.t()) ::
          Ecto.Changeset.t(Engagement.t())
  defp claimed_engagement(%{consume: invitation}, person_id, now) do
    Engagement.claim_changeset(invitation, person_id, now)
  end

  @spec attestation(map(), DateTime.t()) :: Ecto.Changeset.t(AttestedEntry.t())
  defp attestation(%{engagement: engagement}, now) do
    AttestedEntry.attest_changeset(engagement.id, engagement.venue_id, now)
  end

  # Scheduled at the term's upper bound. `ends_at` travels in the args as a
  # uniqueness discriminator and for nothing else — the worker re-reads the row
  # and derives activeness from the database, never from this — so a renewal
  # produces a job with different args rather than colliding with the stale one.
  # No `person_id`: a job's args are a table in `public`, and KTD2's rule about
  # naming humans does not stop at the schemas the application owns.
  @spec expiry_job(map()) :: Ecto.Changeset.t(Oban.Job.t())
  defp expiry_job(%{engagement: engagement}) do
    ExpireEngagement.schedule_for(engagement)
  end

  ## Reading, from the employer's side

  @doc """
  The venue's engagements that are active at the scope's instant, oldest first.

  Membership, in other words. Nothing is stored and no job maintains it: the
  same call at a later instant returns a different set because the instant
  moved, which is R2 and the unit's verification condition.
  """
  @spec list_engagements(EmployerScope.t()) :: {:ok, [Engagement.t()]} | {:error, :no_grant}
  def list_engagements(%EmployerScope{grant_id: grant_id} = scope) when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_engagements/1)
  end

  @spec read_engagements(EmployerScope.t()) :: {:ok, [Engagement.t()]} | {:error, :no_grant}
  defp read_engagements(scope) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok, EmployerRepo.all(active_engagements(scope))}
    end
  end

  @doc """
  One of the venue's engagements, active at the scope's instant.
  """
  @spec fetch_engagement(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :no_grant | :not_found}
  def fetch_engagement(%EmployerScope{grant_id: grant_id} = scope, engagement_id)
      when is_binary(grant_id) and is_binary(engagement_id) do
    EmployerRepo.scoped_transaction(scope, &read_engagement(&1, engagement_id))
  end

  @spec read_engagement(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()} | {:error, :no_grant | :not_found}
  defp read_engagement(scope, engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      scope.venue_id
      |> Records.engagement(engagement_id)
      |> Records.active_at(scope.now)
      |> EmployerRepo.one()
      |> found()
    end
  end

  @spec found(Engagement.t() | nil) :: {:ok, Engagement.t()} | {:error, :not_found}
  defp found(%Engagement{} = engagement), do: {:ok, engagement}
  defp found(nil), do: {:error, :not_found}

  ## Reading, from the person's side

  @doc """
  Every engagement this person holds that is active at their scope's instant.

  Across venues, which is why it is person-scoped and runs through
  `HospitalityComs.Repo`: an employer session asking the same question would be
  asking where else somebody works.

  Refuses an employer scope by function clause, and an anonymous person scope
  too — an anonymous caller holds no engagements, and answering `[]` would make
  "nobody" and "somebody with nothing" the same answer.
  """
  @spec list_person_engagements(PersonScope.t()) :: [Engagement.t()]
  def list_person_engagements(%PersonScope{person: %Person{id: person_id}, now: now})
      when is_binary(person_id) do
    Engagement
    |> Records.of_person(person_id)
    |> Records.active_at(now)
    |> Records.oldest_first()
    |> Repo.all()
  end

  @doc """
  Every engagement this person has ever held, active or not.

  The portable record's spine: KTD16 gives engagements and attested entries no
  retention deadline at all, deliberately, because they are the person's own
  history rather than the employer's.
  """
  @spec list_person_history(PersonScope.t()) :: [Engagement.t()]
  def list_person_history(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    Engagement |> Records.of_person(person_id) |> Records.oldest_first() |> Repo.all()
  end

  @doc """
  Every attested entry this person's engagements have produced.

  Reached through the bridge, because there is no other way: `attested_entries`
  carries no `person_id` and never will.
  """
  @spec list_person_attested_entries(PersonScope.t()) :: [AttestedEntry.t()]
  def list_person_attested_entries(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    person_id |> Records.attested_entries_of_person() |> Repo.all()
  end

  ## Renewal

  @doc """
  Extends an active engagement's term to `ends_at`.

  The same engagement, not a second one — which is what keeps the attested entry
  singular: renewal writes no new entry, and the unique index on
  `attested_entries.engagement_id` means it could not if it tried.

  Refuses anything that is not an extension. Shortening a term is not a renewal;
  the way to end an engagement early is `end_engagement/2`, which carries the
  last-grant-holder invariant that a silent shortening would walk around.

  Under `optimistic_lock/2`. Two managers renewing at once both read the same
  `lock_version`, and the second `UPDATE` matches no row and comes back
  `{:error, :stale}` rather than overwriting the first extension with its own.
  Nothing about that race is visible to the exclusion constraint, because a row
  does not conflict with itself.

  An expiry job scheduled for the old upper bound is left alone. It re-derives
  activeness when it fires, finds the engagement active, and writes nothing —
  see `HospitalityComs.Workers.ExpireEngagement`. Cancelling it would be a write
  through a second repo inside this transaction, which would commit even if this
  rolled back.
  """
  @spec renew_engagement(EmployerScope.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Engagement.t()}
          | {:error,
             :no_grant
             | :not_found
             | :not_an_extension
             | :stale
             | Ecto.Changeset.t(Engagement.t())}
  def renew_engagement(
        %EmployerScope{grant_id: grant_id} = scope,
        engagement_id,
        %DateTime{} = ends_at
      )
      when is_binary(grant_id) and is_binary(engagement_id) do
    EmployerRepo.scoped_transaction(scope, &extend(&1, engagement_id, ends_at))
  end

  @spec extend(EmployerScope.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, Engagement.t()}
          | {:error,
             :no_grant
             | :not_found
             | :not_an_extension
             | :stale
             | Ecto.Changeset.t(Engagement.t())}
  # `ends_at` is truncated before it is compared, and that is the whole of the
  # sub-second fix: the column is second-precision and `close_at_changeset/3`
  # truncates on the way in, so a renewal half a second past the current bound
  # compared `:gt`, wrote the same instant back, and answered `{:ok, _}` having
  # moved nothing — while consuming the optimistic lock, so a concurrent
  # renewal that *would* have moved it failed as stale in its place.
  defp extend(scope, engagement_id, ends_at) do
    truncated = DateTime.truncate(ends_at, :second)

    with {:ok, _grant} <- Venues.fetch_acting_grant(scope),
         {:ok, engagement} <- read_engagement(scope, engagement_id),
         :ok <- extension?(engagement, truncated) do
      write_close_at(engagement, truncated, scope.now)
    end
  end

  @spec extension?(Engagement.t(), DateTime.t()) :: :ok | {:error, :not_an_extension}
  defp extension?(%Engagement{ends_at: current}, ends_at) do
    ends_at |> DateTime.compare(current) |> extension_or_refuse()
  end

  @spec extension_or_refuse(:lt | :eq | :gt) :: :ok | {:error, :not_an_extension}
  defp extension_or_refuse(:gt), do: :ok
  defp extension_or_refuse(_order), do: {:error, :not_an_extension}

  ## Ending

  @doc """
  Closes an engagement's term at the scope's instant, at that venue only.

  Half-open, so the person is outside the engagement from the instant it names
  rather than from a second later, and every other venue's engagement is
  untouched — R4, and the reason the socket id in KTD7 is per session rather
  than per person.

  Refuses the venue's last active grant-holding engagement with
  `:last_grant_holder` (R22, KTD17). "Holding" means `grant_id` naming a grant
  that is *live* at this instant, not `grant_id` being set — an engagement whose
  grant was revoked holds nothing, so it is neither a survivor that lets the
  real manager be ended nor a target that can never be ended itself. The count
  is taken under `FOR UPDATE` on that set, so the count and the write are one
  decision: two managers each ending the other would otherwise each read two
  holders, each correctly conclude they were not removing the last, and together
  leave the venue with an authority nobody holds. The target is resolved out of
  that same locked set rather than by a separate read in front of it.

  The target set is every engagement of the venue whose term has not closed —
  one state wider than active, so an engagement claimed before its start date
  can be closed too. It closes at the later of the caller's instant and its own
  `starts_at`, which for an active engagement is the instant and for a
  not-yet-started one is its opening: `ends_at == starts_at`, the empty range,
  active at no instant and overlapping nothing. Without that, a claim made in
  error reserved the person's dates against the exclusion constraint for its
  whole term and nobody could take it back. A not-yet-started engagement holds
  no authority *yet*, so it can never be the last grant holder.

  Everything whose term has already closed is `:not_found`, along with an
  engagement at another venue and an id that names nothing, so the refusal
  discloses nothing about which engagements exist.

  Broadcasts the revocation after the transaction commits and only if it did
  (KTD8). A broadcast inside the transaction would disconnect clients for a
  change that might roll back, and the broadcast is a nudge in any case: the
  revocation is the rejoin that `join/3` refuses, which U7 builds.
  """
  @spec end_engagement(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()}
          | {:error,
             :no_grant
             | :not_found
             | :last_grant_holder
             | :stale
             | Ecto.Changeset.t(Engagement.t())}
  def end_engagement(%EmployerScope{grant_id: grant_id} = scope, engagement_id)
      when is_binary(grant_id) and is_binary(engagement_id) do
    scope
    |> EmployerRepo.scoped_transaction(&close(&1, engagement_id))
    |> announce()
  end

  @spec close(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, Engagement.t()}
          | {:error,
             :no_grant
             | :not_found
             | :last_grant_holder
             | :stale
             | Ecto.Changeset.t(Engagement.t())}
  defp close(scope, engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      scope
      |> locked_decision_set(engagement_id)
      |> Enum.split_with(&(&1.id == engagement_id))
      |> close_target(scope)
    end
  end

  # `FOR UPDATE` over exactly the rows the decision depends on: every active
  # engagement of the venue holding a live authority, plus the target itself.
  # A total order — `(starts_at, id)` — makes the lock acquisition
  # deterministic, so two sessions block rather than deadlock.
  #
  # Every row that comes back other than the target therefore holds a live
  # grant by construction, which is what lets `orphans_venue?/3` decide on the
  # emptiness of the survivor list rather than re-testing each one.
  @spec locked_decision_set(EmployerScope.t(), Ecto.UUID.t()) :: [Engagement.t()]
  defp locked_decision_set(%EmployerScope{venue_id: venue_id, now: now}, engagement_id) do
    Engagement
    |> Records.of_venue(venue_id)
    |> Records.not_ended_by(now)
    |> Records.decision_set(venue_id, now, engagement_id)
    |> Records.oldest_first()
    |> lock("FOR UPDATE")
    |> EmployerRepo.all()
  end

  @spec close_target({[Engagement.t()], [Engagement.t()]}, EmployerScope.t()) ::
          {:ok, Engagement.t()}
          | {:error, :not_found | :last_grant_holder | :stale | Ecto.Changeset.t(Engagement.t())}
  defp close_target({[], _survivors}, _scope), do: {:error, :not_found}

  defp close_target({[target], survivors}, scope) do
    target
    |> orphans_venue?(survivors, scope)
    |> close_or_refuse(target, closing_instant(target, scope.now))
  end

  # Only an engagement that holds a *live* authority right now can orphan a
  # venue, and only if no other active engagement holds one. An ordinary
  # worker leaving is never refused, and neither is a manager whose grant was
  # revoked out from under them — they hold nothing to be the last of.
  @spec orphans_venue?(Engagement.t(), [Engagement.t()], EmployerScope.t()) :: boolean()
  defp orphans_venue?(%Engagement{grant_id: nil}, _survivors, _scope), do: false

  defp orphans_venue?(%Engagement{} = target, survivors, scope) do
    survivors == [] and active?(target, scope.now) and holds_live_grant?(target, scope)
  end

  @spec holds_live_grant?(Engagement.t(), EmployerScope.t()) :: boolean()
  defp holds_live_grant?(%Engagement{grant_id: grant_id}, %EmployerScope{} = scope) do
    scope.venue_id
    |> Records.live_grant_ids(scope.now)
    |> where([grant], grant.id == ^grant_id)
    |> EmployerRepo.exists?()
  end

  # An active engagement closes at the caller's instant; one that has not
  # started closes at its own opening, which is the earliest instant its term
  # can name. `ends_at < starts_at` is unrepresentable — the generated range
  # raises on it — and `ends_at == starts_at` is the empty range the schema
  # already permits: active at no instant, and overlapping nothing, so the
  # person's dates are free again.
  @spec closing_instant(Engagement.t(), DateTime.t()) :: DateTime.t()
  defp closing_instant(%Engagement{starts_at: starts_at}, now) do
    starts_at |> DateTime.compare(now) |> later_of(starts_at, now)
  end

  @spec later_of(:lt | :eq | :gt, DateTime.t(), DateTime.t()) :: DateTime.t()
  defp later_of(:gt, starts_at, _now), do: starts_at
  defp later_of(_order, _starts_at, now), do: now

  @spec close_or_refuse(boolean(), Engagement.t(), DateTime.t()) ::
          {:ok, Engagement.t()}
          | {:error, :last_grant_holder | :stale | Ecto.Changeset.t(Engagement.t())}
  defp close_or_refuse(true, _target, _now), do: {:error, :last_grant_holder}
  defp close_or_refuse(false, target, now), do: write_close_at(target, now, now)

  ## The one write both renewal and ending make

  # `Ecto.StaleEntryError` is what `optimistic_lock/2` raises when the version
  # has moved under the caller. It is rescued here rather than allowed out,
  # because the repository's convention is enumerated error atoms and a
  # concurrent renewal is an ordinary outcome rather than an exceptional one.
  # Nothing was written when it raises, so the enclosing transaction is intact.
  @spec write_close_at(Engagement.t(), DateTime.t(), DateTime.t()) ::
          {:ok, Engagement.t()} | {:error, :stale | Ecto.Changeset.t(Engagement.t())}
  defp write_close_at(engagement, ends_at, now) do
    engagement
    |> Engagement.close_at_changeset(ends_at, now)
    |> EmployerRepo.update()
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
  end

  @spec active_engagements(EmployerScope.t()) :: Ecto.Query.t()
  defp active_engagements(%EmployerScope{venue_id: venue_id, now: now}) do
    Engagement
    |> Records.of_venue(venue_id)
    |> Records.active_at(now)
    |> Records.oldest_first()
  end

  ## Expiry, which writes nothing

  @doc """
  Engagements whose term closed in `(since, instant]`, most recently first.

  What `HospitalityComs.Workers.EngagementSweeper` sweeps. Unscoped by venue —
  the sweeper is the application acting for itself rather than for an employer,
  so it runs through `HospitalityComs.Repo` and sees every venue, which is
  exactly what no employer session may do.

  Bounded three ways, and each bound answers something different:

    * `limit`, because an unattended query over a growing table is a query that
      eventually stops finishing;
    * `since`, because a limit on its own is worse than no limit. `ends_at <=
      instant` matches every term that ever closed, so once more than a batch of
      them have, a limited sweep examines the same oldest rows for ever and
      never reaches a term that closed this morning — while continuing to run
      and to report success;
    * the ordering, which is on the column being filtered and runs from the
      newest closure back, so the rows a sweep is most likely to owe an
      announcement are the ones inside the limit.

  The caller chooses `since`; `HospitalityComs.Workers.EngagementSweeper` is
  where the lookback and the assumption behind it are written down.
  """
  @spec list_expired(DateTime.t(), DateTime.t(), pos_integer()) :: [Engagement.t()]
  def list_expired(%DateTime{} = instant, %DateTime{} = since, limit)
      when is_integer(limit) and limit > 0 do
    Engagement
    |> Records.ended_between(since, instant)
    |> Records.newest_ended_first()
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Re-derives an engagement's activeness at `instant` and broadcasts if it has
  ended.

  **Writes nothing to `engagements`, ever.** That is the whole contract. A job
  scheduled for an upper bound that a renewal has since moved would, if it wrote
  anything, truncate the renewed term — a revocation caused by a queue's latency
  and by nothing a manager did. Because it only reads, a stale job is inert and
  no cancellation path is needed.

  `:gone` is a deleted engagement, which only U10's lifecycle context can
  produce, and it is not an error: a job outliving its row is the ordinary end
  of an erasure.
  """
  @spec revoke_if_expired(Ecto.UUID.t(), DateTime.t()) :: expiry()
  def revoke_if_expired(engagement_id, %DateTime{} = instant) when is_binary(engagement_id) do
    Engagement |> Repo.get(engagement_id) |> revoke_unless_active(instant)
  end

  @spec revoke_unless_active(Engagement.t() | nil, DateTime.t()) :: expiry()
  defp revoke_unless_active(nil, _instant), do: :gone

  defp revoke_unless_active(%Engagement{} = engagement, instant) do
    engagement |> active?(instant) |> broadcast_unless_active(engagement, instant)
  end

  @doc """
  Whether an engagement's term contains `instant`.

  The same half-open predicate `HospitalityComs.Engagements.Records.active_at/2`
  spells in SQL, in Elixir, for a struct already in hand. Two spellings of one
  rule is one more than ideal; what makes it safe is that both are tested at
  both boundaries, and what makes it necessary is that a worker holding a row
  should not have to ask the database whether the row it is holding is active.
  """
  @spec active?(Engagement.t(), DateTime.t()) :: boolean()
  def active?(%Engagement{starts_at: starts_at, ends_at: ends_at}, %DateTime{} = instant) do
    DateTime.compare(starts_at, instant) != :gt and DateTime.compare(ends_at, instant) == :gt
  end

  @spec broadcast_unless_active(boolean(), Engagement.t(), DateTime.t()) :: expiry()
  defp broadcast_unless_active(true, _engagement, _instant), do: :still_active

  defp broadcast_unless_active(false, engagement, instant) do
    broadcast_revocation(engagement, instant)
    :revoked
  end

  ## Revocation broadcasts

  @doc """
  The PubSub topic an engagement's revocation is announced on.

  Per engagement rather than per person: KTD7 makes a socket id per session so
  that ending a Venue B engagement leaves the Venue A session alone, and a
  per-person topic would put that back.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(engagement_id) when is_binary(engagement_id), do: "engagement:#{engagement_id}"

  @doc """
  Subscribes the calling process to one engagement's revocation.

  `{:error, {:already_registered, pid}}` is `Registry.register/3`'s only
  failure and it cannot happen here — `Phoenix.PubSub`'s registry is
  `keys: :duplicate`, and a duplicate registry accepts every registration. It is
  enumerated rather than dropped because the library's contract, not this
  function, is what would have to change for it to appear.
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, {:already_registered, pid()}}
  def subscribe(engagement_id) when is_binary(engagement_id) do
    Phoenix.PubSub.subscribe(HospitalityComs.PubSub, topic(engagement_id))
  end

  # Only on `{:ok, _}`. A broadcast for a change that rolled back would
  # disconnect clients whose access never actually ended (KTD8).
  #
  # The announcement's own outcome does not reach the caller, and that is the
  # decision rather than an oversight — see `broadcast_revocation/2`.
  @spec announce(
          {:ok, Engagement.t()}
          | {:error,
             :no_grant
             | :not_found
             | :last_grant_holder
             | :stale
             | Ecto.Changeset.t(Engagement.t())}
        ) ::
          {:ok, Engagement.t()}
          | {:error,
             :no_grant
             | :not_found
             | :last_grant_holder
             | :stale
             | Ecto.Changeset.t(Engagement.t())}
  defp announce({:ok, %Engagement{} = engagement} = result) do
    broadcast_revocation(engagement, engagement.ends_at)
    result
  end

  defp announce(result), do: result

  # **The announcement is best-effort, deliberately, and it is logged rather
  # than propagated.**
  #
  # The revocation is not this message. It is the rejoin that `join/3` refuses
  # once the period no longer contains the instant (KTD8, U7) — derived, with
  # nothing stored and nothing to keep in step. This broadcast is the nudge that
  # makes an already-powerless socket notice, so a delivery failure costs
  # latency and not correctness, and failing `end_engagement/2` over it would
  # roll back a term that is genuinely closed in order to report that nobody was
  # told.
  #
  # What it must not do is promise `:ok` and swallow the answer, which is what
  # it used to. `{:error, :no_such_group}` is the one failure the `:pg` adapter
  # can name, and on OTP's `:pg` it is unreachable — `:pg.get_members/2` answers
  # `[]` for a group nobody has joined. The clause is here because the
  # library's contract allows it, and the log line is what makes it visible if
  # the adapter ever changes.
  @spec broadcast_revocation(Engagement.t(), DateTime.t()) :: :ok
  defp broadcast_revocation(%Engagement{} = engagement, %DateTime{} = instant) do
    HospitalityComs.PubSub
    |> Phoenix.PubSub.broadcast(
      topic(engagement.id),
      {:engagement_revoked,
       %{engagement_id: engagement.id, venue_id: engagement.venue_id, at: instant}}
    )
    |> announced(engagement)
  end

  @spec announced(:ok | {:error, term()}, Engagement.t()) :: :ok
  defp announced(:ok, _engagement), do: :ok

  defp announced({:error, reason}, %Engagement{} = engagement) do
    Logger.warning(
      "engagement revocation was not announced " <>
        "engagement_id=#{engagement.id} venue_id=#{engagement.venue_id} " <>
        "reason_code=#{inspect(reason)}"
    )

    :ok
  end
end
