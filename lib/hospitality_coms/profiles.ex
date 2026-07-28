defmodule HospitalityComs.Profiles do
  @moduledoc """
  The worker's portable record, and the rules about who may read which part of
  it.

  Two kinds of entry (R16). An **attested** entry is an employer's assertion
  that an engagement happened; it is written inside the claim's transaction
  (`HospitalityComs.Engagements.claim_invitation/2`) and by nothing else, and no
  function in this module writes one. A **declared** entry is the worker's own
  statement about work this application knows nothing about; they write it and
  amend it and nobody else can.

  On top of that, R17: per-employer and per-peer disclosure, worker-controlled,
  with concurrent engagements hidden by default — and the default computed from
  period overlap rather than materialised.

  ## KTD3 is the spine of this module

  > Hidden attested entries go through an owner-privileged view, not row-level
  > security.

  The hidden-entry rule is **per row**, and a table grant cannot express a
  per-row rule. So `employer_role` holds no privilege on `attested_entries` at
  all — since U5, asserted in `HospitalityComs.BoundaryTest` — and every
  employer read in this module goes through
  `employer_visible_attested_entries`, a view owned by the role that owns the
  base tables, granted `SELECT` and nothing else.

  Row-level security was not merely the less tidy option here. `HospitalityComs.Repo`
  connects as a **superuser** on this deployment, and a superuser bypasses
  row-level security whether or not a policy is `FORCE`d — so an RLS-based
  hidden-entry rule would read as a tier in the migration and provide none in
  the database. `*_create_employer_visible_view.exs` carries the measurement.

  ## The concurrency default is a comparison of two periods, and no instant

  An entry attested by venue A is hidden from venue B when the engagement it
  attests **overlapped** any engagement the same person held at venue B. That
  predicate is inside the view, over columns that are already stored, and it
  names no instant.

  Both halves of the requirement follow from that one property. "Changing an
  engagement's dates corrects the default automatically" holds because nothing
  is materialised — move the dates and the next read answers differently, with
  no job having run. "A hidden entry remains hidden after it stops being
  concurrent" holds because overlap is a fact about two periods rather than
  about now: a term that ended in June overlapped a term running March to
  December whether it is asked in May or in November. A default written as
  "concurrent at this instant" would satisfy the first and fail the second, by
  re-disclosing a second job at the moment it ended — which is the leak the
  default exists to prevent.

  What *is* time-derived is which workers an employer session may see at all:
  the people holding an engagement at its venue that is active at the scope's
  instant. An ex-worker leaves the employer's reach with nothing having run,
  exactly as they leave every membership query (R2).

  ## The worker's override is a row, because it is a decision

  Nothing computes "this worker chose to reveal their second job", so
  `attested_entry_disclosures` stores it: one row per (entry, audience),
  carrying a boolean, replacing the default in whichever direction the worker
  chose. Revoking one writes `false`; nothing is deleted (KTD21).

  The **peer** default is different and deliberately so. A peer was co-rostered
  with the worker and the venue room's roll already told them the venue and the
  employer-authored role label, so an entry is disclosed to peers unless the
  worker names one and says otherwise. The two settings are separate rows read
  by separate readers, which is what makes them independent.

  ## The standing incompleteness notice is a constant

  `incompleteness_notice/0` takes no arguments, and that is the whole of its
  design. A computed "this profile has hidden entries" would be an oracle: it
  would tell every viewer which workers are concealing something, which is
  strictly more than the concealed entries themselves would have disclosed. So
  nothing in this module counts hidden entries, no view column reports one, and
  the notice is shown next to every profile whether or not anything is missing
  from it.

  ## A person cannot edit an attested entry, and the correction request is why

  There is no function here that writes one, and `employer_role` holds no
  `UPDATE` on the table either. What a worker can do is contest one:
  `request_correction/3` writes a `correction_requests` row, which the attesting
  venue answers with `resolve_correction/3`. Resolving changes no entry and
  cannot — an attested entry derives from its engagement — so an accepted
  correction is an acknowledgement, and the actual correction, if the employer
  makes one, is a change to the engagement through
  `HospitalityComs.Engagements`. Declining leaves the entry and the request both
  readable, which is what stops a refusal being a way to make a contest
  disappear.

  ## Refusals enumerate nothing

  `:not_found` covers an engagement that belongs to somebody else, a declared
  entry that does, a correction request at another venue, and an id that names
  nothing — identically. The employer's reads take a `viewer_engagement_id` and
  answer `{:ok, []}` for one that names nothing, because a refusal there would
  confirm which engagements exist at which venue.
  """

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Peers
  alias HospitalityComs.Profiles.CorrectionRequest
  alias HospitalityComs.Profiles.DeclaredEntry
  alias HospitalityComs.Profiles.Disclosure
  alias HospitalityComs.Profiles.Records
  alias HospitalityComs.Profiles.VisibleCorrection
  alias HospitalityComs.Profiles.VisibleEntry
  alias HospitalityComs.Repo
  alias HospitalityComs.Venues

  @typedoc """
  A profile as one reader sees it.

  The same three lists whoever is asking, so the unit's verification — an
  employer session and the same human's person session returning different entry
  sets for one worker — is a comparison of two of these rather than of two
  different shapes.

  There is deliberately **no** `hidden_entries` count and no `complete?` flag.
  See `incompleteness_notice/0`.
  """
  @type profile() :: %{
          attested_entries: [VisibleEntry.t()],
          declared_entries: [DeclaredEntry.t()],
          correction_requests: [VisibleCorrection.t()]
        }

  # A constant, and it is a constant on purpose. See the moduledoc.
  @incompleteness_notice "This record may be incomplete. A worker chooses which " <>
                           "of their entries each employer and each peer can see."

  @doc """
  The standing notice shown beside every profile, whoever is reading it.

  **Arity zero, and that is the design rather than an accident of the
  signature.** It cannot depend on the worker it is shown beside, so it cannot
  become the oracle a computed "are any hidden" flag would be: a flag would
  disclose which workers are concealing something, which is strictly worse than
  disclosing the entries. Shown always, so its presence says nothing.
  """
  @spec incompleteness_notice() :: String.t()
  def incompleteness_notice, do: @incompleteness_notice

  ## The worker's own record

  @doc """
  Every attested entry this person's engagements have produced, oldest first.

  Their own, so nothing is filtered: disclosure governs what *others* see, and a
  worker who could not see what they were hiding could not decide about it.
  """
  @spec list_attested_entries(PersonScope.t()) :: [VisibleEntry.t()]
  def list_attested_entries(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    person_id |> Records.attested_entries_of() |> Repo.all() |> Enum.map(&VisibleEntry.new/1)
  end

  @doc """
  Every declared entry this person has written, oldest term first.
  """
  @spec list_declared_entries(PersonScope.t()) :: [DeclaredEntry.t()]
  def list_declared_entries(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    person_id |> Records.declared_entries_of() |> Repo.all()
  end

  @doc """
  Every correction request this person has raised, newest first.
  """
  @spec list_correction_requests(PersonScope.t()) :: [VisibleCorrection.t()]
  def list_correction_requests(%PersonScope{person: %Person{id: person_id}})
      when is_binary(person_id) do
    person_id
    |> Records.correction_requests_of()
    |> Repo.all()
    |> Enum.map(&VisibleCorrection.new/1)
  end

  @doc """
  Every disclosure decision this person has taken, newest first.

  The worker's own view of the ledger, and the only view of it there is. An
  employer-facing counterpart would tell a venue which of its workers is
  concealing something.
  """
  @spec list_disclosures(PersonScope.t()) :: [Disclosure.t()]
  def list_disclosures(%PersonScope{person: %Person{id: person_id}}) when is_binary(person_id) do
    person_id |> Records.disclosures_of() |> Repo.all()
  end

  @doc """
  This person's whole profile, as they see it.
  """
  @spec own_profile(PersonScope.t()) :: profile()
  def own_profile(%PersonScope{person: %Person{id: person_id}} = scope)
      when is_binary(person_id) do
    %{
      attested_entries: list_attested_entries(scope),
      declared_entries: list_declared_entries(scope),
      correction_requests: list_correction_requests(scope)
    }
  end

  ## Declared entries

  @doc """
  Writes a declared entry for the person the scope names.

  `attrs` carries `:role_label`, `:organisation_name`, `:starts_at` and
  `:ends_at`. The owner is taken from the scope and is not castable: a caller
  that could choose it could write history into somebody else's record.
  """
  @spec declare_entry(PersonScope.t(), map()) ::
          {:ok, DeclaredEntry.t()} | {:error, Ecto.Changeset.t(DeclaredEntry.t())}
  def declare_entry(%PersonScope{person: %Person{id: person_id}, now: now}, attrs)
      when is_binary(person_id) and is_map(attrs) do
    person_id |> DeclaredEntry.declare_changeset(attrs, now) |> Repo.insert()
  end

  @doc """
  Amends a declared entry this person wrote.

  Somebody else's entry and an id that names nothing are both `:not_found`, so
  the refusal enumerates nothing (AE1). `declared_at` is untouched: amending a
  statement is not re-declaring it.
  """
  @spec amend_declared_entry(PersonScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, DeclaredEntry.t()}
          | {:error, :not_found | Ecto.Changeset.t(DeclaredEntry.t())}
  def amend_declared_entry(
        %PersonScope{person: %Person{id: person_id}, now: now},
        entry_id,
        attrs
      )
      when is_binary(person_id) and is_binary(entry_id) and is_map(attrs) do
    person_id
    |> Records.declared_entry_of(entry_id)
    |> Repo.one()
    |> amend(attrs, now)
  end

  @spec amend(DeclaredEntry.t() | nil, map(), DateTime.t()) ::
          {:ok, DeclaredEntry.t()}
          | {:error, :not_found | Ecto.Changeset.t(DeclaredEntry.t())}
  defp amend(nil, _attrs, _now), do: {:error, :not_found}

  defp amend(%DeclaredEntry{} = entry, attrs, now) do
    entry |> DeclaredEntry.amend_changeset(attrs, now) |> Repo.update()
  end

  ## Disclosure

  @doc """
  Records this person's decision about one of their attested entries and one
  audience.

  The entry is named by its engagement, which is the row that already means
  "this person, at this venue" and which `attested_entries.engagement_id` makes
  unique. The audience is `{:venue, venue_id}` or `{:person, person_id}`.

  Deciding twice about the same pair replaces the answer rather than adding a
  second row — one statement, `ON CONFLICT` against the partial unique index, so
  two decisions racing resolve to one row and the later answer wins rather than
  one of them raising.

  An engagement that is not this person's is `:not_found`, identically to an id
  that names nothing. An audience that names no venue and no person is a
  changeset error from the foreign key.
  """
  @spec set_disclosure(PersonScope.t(), Ecto.UUID.t(), Disclosure.audience(), boolean()) ::
          {:ok, Disclosure.t()} | {:error, :not_found | Ecto.Changeset.t(Disclosure.t())}
  def set_disclosure(
        %PersonScope{person: %Person{id: person_id}, now: now},
        engagement_id,
        audience,
        disclosed
      )
      when is_binary(person_id) and is_binary(engagement_id) and is_boolean(disclosed) do
    person_id
    |> Records.own_engagement(engagement_id)
    |> Repo.exists?()
    |> decide(engagement_id, audience, disclosed, now)
  end

  @spec decide(boolean(), Ecto.UUID.t(), Disclosure.audience(), boolean(), DateTime.t()) ::
          {:ok, Disclosure.t()} | {:error, :not_found | Ecto.Changeset.t(Disclosure.t())}
  defp decide(false, _engagement_id, _audience, _disclosed, _now), do: {:error, :not_found}

  defp decide(true, engagement_id, audience, disclosed, now) do
    engagement_id
    |> Disclosure.decide_changeset(audience, disclosed, now)
    |> Repo.insert(
      on_conflict: {:replace, Disclosure.replaceable_fields()},
      conflict_target: Disclosure.conflict_target(audience),
      # Without this the struct that comes back carries the id this insert
      # *attempted* rather than the id of the row `ON CONFLICT` updated, because
      # a `binary_id` primary key is generated in Elixir and Ecto has no reason
      # to read one back.
      returning: true
    )
  end

  ## Correction requests, from the worker's side

  @doc """
  Raises a correction request against one of this person's own attested entries.

  `attrs` carries `:body`. The venue is taken from the engagement rather than
  from the caller, so a request can only ever be addressed to the employer that
  made the assertion, and the composite foreign key refuses one that names an
  engagement at another venue whatever this function believes.

  Runs through `HospitalityComs.Repo` as the application's own role, because
  `employer_role` holds no `INSERT` here — a session that could write a
  complaint could then resolve it — and no person session holds a privilege on
  the employer zone at all. That is the same shape
  `HospitalityComs.Engagements.claim_invitation/2` has.
  """
  @spec request_correction(PersonScope.t(), Ecto.UUID.t(), map()) ::
          {:ok, CorrectionRequest.t()}
          | {:error, :not_found | Ecto.Changeset.t(CorrectionRequest.t())}
  def request_correction(
        %PersonScope{person: %Person{id: person_id}, now: now},
        engagement_id,
        attrs
      )
      when is_binary(person_id) and is_binary(engagement_id) and is_map(attrs) do
    person_id
    |> Records.own_engagement(engagement_id)
    |> Repo.one()
    |> contest(attrs, now)
  end

  @spec contest(Engagement.t() | nil, map(), DateTime.t()) ::
          {:ok, CorrectionRequest.t()}
          | {:error, :not_found | Ecto.Changeset.t(CorrectionRequest.t())}
  defp contest(nil, _attrs, _now), do: {:error, :not_found}

  defp contest(%Engagement{} = engagement, attrs, now) do
    engagement |> CorrectionRequest.request_changeset(attrs, now) |> Repo.insert()
  end

  ## The peer's read

  @doc """
  Another person's profile, as a peer sees it.

  Gated on the pair being **visible to each other or connected**, and it has to
  be both clauses: visibility lapses thirty days after the first of their two
  engagements ends (R13), while a connection is permanent and outlives every
  engagement either of them holds. A gate on visibility alone would take the
  profile away from somebody they are still in conversation with.

  Attested entries come back subject to the worker's peer-audience decisions —
  disclosed unless the worker named this peer and said otherwise — and are
  independent of what any employer can see. Declared entries come back whole:
  writing one is publishing it, which is why the ledger governs attested entries
  alone.

  `:not_a_peer` covers a person who is neither visible nor connected, an id that
  names nobody, and the caller themselves, identically.
  """
  @spec fetch_peer_profile(PersonScope.t(), Ecto.UUID.t()) ::
          {:ok, profile()} | {:error, :not_a_peer}
  def fetch_peer_profile(%PersonScope{person: %Person{id: person_id}} = scope, other_person_id)
      when is_binary(person_id) and is_binary(other_person_id) do
    scope
    |> peer?(other_person_id)
    |> peer_profile(person_id, other_person_id)
  end

  @spec peer?(PersonScope.t(), Ecto.UUID.t()) :: boolean()
  defp peer?(scope, other_person_id) do
    Peers.visible?(scope, other_person_id) or Peers.connected?(scope, other_person_id)
  end

  @spec peer_profile(boolean(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, profile()} | {:error, :not_a_peer}
  defp peer_profile(false, _person_id, _other_person_id), do: {:error, :not_a_peer}

  defp peer_profile(true, person_id, other_person_id) do
    attested =
      other_person_id
      |> Records.attested_entries_disclosed_to(person_id)
      |> Repo.all()
      |> Enum.map(&VisibleEntry.new/1)

    corrections =
      other_person_id
      |> Records.correction_requests_disclosed_to(person_id)
      |> Repo.all()
      |> Enum.map(&VisibleCorrection.new/1)

    {:ok,
     %{
       attested_entries: attested,
       declared_entries: Repo.all(Records.declared_entries_of(other_person_id)),
       correction_requests: corrections
     }}
  end

  ## The employer's read, which goes through the view

  @doc """
  The attested entries this employer session may see behind one of its own
  engagements, oldest term first.

  Reads `employer_visible_attested_entries` and never `attested_entries`, on
  which `employer_role` holds no privilege at all (KTD3). The view resolves its
  own venue and instant from `app_current_employer_id()` and
  `app_current_instant()`, which `EmployerRepo.scoped_transaction/2` wrote from
  the scope — so a read that escaped the wrapper raises rather than resolving to
  NULL and returning an empty set, which would be indistinguishable from a
  worker who had disclosed nothing.

  Takes the **viewer's own engagement id** rather than a `person_id`, which is
  U9's answer to the disclosure recorded against `engagements.person_id`: the
  person key is globally stable and two venues comparing ids out of band could
  determine that the same human works at both. An engagement belonging to
  another venue, or one that names nothing, answers `{:ok, []}` rather than
  refusing, because a refusal would confirm which engagements exist (AE1).
  """
  @spec list_visible_entries(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [VisibleEntry.t()]} | {:error, :no_grant}
  def list_visible_entries(%EmployerScope{grant_id: grant_id} = scope, viewer_engagement_id)
      when is_binary(grant_id) and is_binary(viewer_engagement_id) do
    EmployerRepo.scoped_transaction(scope, &read_visible_entries(&1, viewer_engagement_id))
  end

  @spec read_visible_entries(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [VisibleEntry.t()]} | {:error, :no_grant}
  defp read_visible_entries(scope, viewer_engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok,
       viewer_engagement_id
       |> Records.employer_visible_entries()
       |> EmployerRepo.all()
       |> Enum.map(&VisibleEntry.new/1)}
    end
  end

  @doc """
  The correction requests attached to the entries that session can see.

  R16 makes a correction request visible to any viewer of the entry it contests,
  and `employer_visible_correction_requests` is that claim as a join onto the
  first view rather than as a second rule — so there is one spelling of the
  disclosure rule and a change to it cannot reach one view and miss the other.
  """
  @spec list_visible_corrections(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [VisibleCorrection.t()]} | {:error, :no_grant}
  def list_visible_corrections(%EmployerScope{grant_id: grant_id} = scope, viewer_engagement_id)
      when is_binary(grant_id) and is_binary(viewer_engagement_id) do
    EmployerRepo.scoped_transaction(scope, &read_visible_corrections(&1, viewer_engagement_id))
  end

  @spec read_visible_corrections(EmployerScope.t(), Ecto.UUID.t()) ::
          {:ok, [VisibleCorrection.t()]} | {:error, :no_grant}
  defp read_visible_corrections(scope, viewer_engagement_id) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok,
       viewer_engagement_id
       |> Records.employer_visible_corrections()
       |> EmployerRepo.all()
       |> Enum.map(&VisibleCorrection.new/1)}
    end
  end

  @doc """
  Every correction request raised against this venue's own assertions, newest
  first.

  The base table rather than a view, and the difference between the two employer
  paths is what each answers. This is "requests about assertions I made", which
  is the venue's own data, confined to it by the row-level security policy on
  `venue_id`. `list_visible_corrections/2` is "requests attached to entries
  somebody disclosed to me", which needs the disclosure rule and therefore the
  view.
  """
  @spec list_venue_corrections(EmployerScope.t()) ::
          {:ok, [CorrectionRequest.t()]} | {:error, :no_grant}
  def list_venue_corrections(%EmployerScope{grant_id: grant_id} = scope)
      when is_binary(grant_id) do
    EmployerRepo.scoped_transaction(scope, &read_venue_corrections/1)
  end

  @spec read_venue_corrections(EmployerScope.t()) ::
          {:ok, [CorrectionRequest.t()]} | {:error, :no_grant}
  defp read_venue_corrections(scope) do
    with {:ok, _grant} <- Venues.fetch_acting_grant(scope) do
      {:ok, EmployerRepo.all(Records.venue_corrections(scope.venue_id))}
    end
  end

  @doc """
  Answers a correction request raised against this venue's own assertion.

  `resolution` is `:accepted` or `:declined`, and **neither changes the attested
  entry**. An attested entry derives from its engagement and there is no write
  path to one, so accepting is an acknowledgement and the actual correction, if
  the employer makes one, is a change to the engagement through
  `HospitalityComs.Engagements`. Declining leaves the entry and the request both
  readable — to the worker, to this venue, and to any venue the entry is
  disclosed to — so a refusal cannot make a contest disappear.

  One conditional statement rather than a read and then a write: two managers
  answering at once resolve to one answer, and the loser's predicate no longer
  matches. `:already_resolved` is a statement about this venue's own row, so
  disclosing it enumerates nothing; another venue's request and an id that names
  nothing are both `:not_found`.
  """
  @spec resolve_correction(EmployerScope.t(), Ecto.UUID.t(), CorrectionRequest.resolution()) ::
          {:ok, CorrectionRequest.t()}
          | {:error, :no_grant | :not_found | :already_resolved}
  def resolve_correction(%EmployerScope{grant_id: grant_id} = scope, request_id, resolution)
      when is_binary(grant_id) and is_binary(request_id) do
    EmployerRepo.scoped_transaction(scope, &resolve(&1, request_id, resolution))
  end

  @spec resolve(EmployerScope.t(), Ecto.UUID.t(), CorrectionRequest.resolution()) ::
          {:ok, CorrectionRequest.t()}
          | {:error, :no_grant | :not_found | :already_resolved}
  defp resolve(scope, request_id, resolution) do
    with {:ok, grant} <- Venues.fetch_acting_grant(scope) do
      scope.venue_id
      |> Records.resolvable_correction(request_id)
      |> EmployerRepo.update_all(
        set: CorrectionRequest.resolution_set(resolution, grant.id, scope.now)
      )
      |> resolved(scope, request_id)
    end
  end

  @spec resolved(
          {non_neg_integer(), [CorrectionRequest.t()] | nil},
          EmployerScope.t(),
          Ecto.UUID.t()
        ) ::
          {:ok, CorrectionRequest.t()} | {:error, :not_found | :already_resolved}
  defp resolved({1, [request]}, _scope, _request_id), do: {:ok, request}

  defp resolved({0, _rows}, scope, request_id) do
    scope.venue_id
    |> Records.correction_at_venue(request_id)
    |> EmployerRepo.exists?()
    |> diagnose()
  end

  # Runs only when the conditional update matched nothing, so it cannot turn a
  # refusal into a success — the worst it can do is name the wrong one of two
  # refusals, and both are refusals.
  @spec diagnose(boolean()) :: {:error, :not_found | :already_resolved}
  defp diagnose(true), do: {:error, :already_resolved}
  defp diagnose(false), do: {:error, :not_found}
end
