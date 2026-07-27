defmodule HospitalityComs.Engagements.Engagement do
  @moduledoc """
  The bridge: one person, one venue, one fixed term.

  This is the only row in the application that names a human on the employer's
  side of the boundary (KTD2). Every other crossing the design might have needed
  goes through it — messages, roster entries and attested entries reference
  `engagements (id, venue_id)` rather than `people (id)` — so an employer-zone
  table that named a person would be a second crossing, and
  `HospitalityComs.BoundaryTest` fails on one.

  ## Nothing stores whether it is active

  An engagement is active at instant `t` when `starts_at <= t < ends_at`.
  Half-open (KTD4), so no instant falls in two consecutive periods and none
  falls in a gap, and the instant an engagement ends already belongs to the
  ended side.

  There is no `status` column, no `active` boolean, and no job that sets one.
  A cached authorization decision that outlives its reason is the exact failure
  the whole design exists to prevent: an expired grant that still works because
  nothing ran. Advancing the clock past `ends_at` therefore excludes the person
  from every membership query with no job having run, which is the unit's
  verification condition.

  The database keeps a generated `period` column — `tstzrange(starts_at,
  ends_at, '[)')`, `GENERATED ALWAYS AS ... STORED` — for the exclusion
  constraint alone. It cannot disagree with the two endpoints because there is
  no write that sets one without the other, which is why the queries in
  `HospitalityComs.Engagements.Records` are free to say `starts_at <= t` and
  `ends_at > t` in the form that reads like the rule.

  ## Two overlapping engagements at one venue are a database error

  `engagements_no_overlap` is an `EXCLUDE USING gist (person_id WITH =,
  venue_id WITH =, period WITH &&)`, and `exclusion_constraint/3` below is
  declared against its name. Without the declaration the violation raises
  through the transaction as a `Postgrex.Error` and the repository's enumerated
  errors become a lie at the one place it is load bearing; with it, the caller
  gets a changeset error on `:period`.

  Adjacent terms sharing a boundary instant are *not* a violation: `[a, b)` and
  `[b, c)` do not overlap. That is the half-open convention doing the work it
  was chosen for.

  Neither is an engagement ended at the instant its term opened. That produces
  `tstzrange(a, a, '[)')`, which is the *empty* range: it contains no instant,
  so the engagement is active at none, and it overlaps nothing, so the same
  person can be engaged again over the same dates. An engagement cannot be
  created that way — an invitation's term is strictly ordered — so the empty
  case is reachable only by ending one, which is exactly what it means.

  ## Renewal is an update under an optimistic lock

  A row does not conflict with itself, so the exclusion constraint says nothing
  about two managers renewing the same engagement at once — both read the same
  `ends_at`, both write their own, and one extension is silently discarded on
  what is the authorization root for everything the person can reach at that
  venue. `optimistic_lock(:lock_version)` is what turns the second one into a
  failure instead. `HospitalityComs.EngagementsConcurrencyTest` is what says the
  lock is load bearing rather than decorative.

  ## Acceptance is not the start

  `accepted_at` is when the person claimed the code and `starts_at` is when the
  term opens; KTD13 resolves the origin document's contradiction between them in
  favour of both existing. An engagement accepted before its start date is
  confirmed and not yet active, and grants no room access — which falls out of
  activeness being `starts_at <= t` rather than needing a rule of its own. No
  constraint orders the two columns, deliberately.

  ## `grant_id` is what makes a manager

  Null on an ordinary worker. Set on an engagement that holds one of the venue's
  administrative authorities, which is U4's missing half: `employer_grants`
  records no holder on purpose, and this is where the holder is recorded — from
  the person's side, so the arrow points *into* the employer zone and never out.
  `HospitalityComs.Engagements.end_engagement/2` refuses to end a venue's last
  grant-holding engagement for that reason (R22, KTD17).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Engagements.Invitation
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "engagements" do
    field :role_label, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :lock_version, :integer, default: 0

    belongs_to :person, Person
    belongs_to :venue, Venue
    belongs_to :invitation, Invitation
    belongs_to :grant, EmployerGrant

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          person_id: Ecto.UUID.t() | nil,
          person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          invitation_id: Ecto.UUID.t() | nil,
          invitation: Invitation.t() | Ecto.Association.NotLoaded.t() | nil,
          grant_id: Ecto.UUID.t() | nil,
          grant: EmployerGrant.t() | Ecto.Association.NotLoaded.t() | nil,
          role_label: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          accepted_at: DateTime.t() | nil,
          lock_version: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @overlap_constraint :engagements_no_overlap

  @doc """
  The name of the exclusion constraint that enforces R3.

  Exposed so the proof suite can look for it in `pg_constraint` by the same
  name the changeset declares, rather than by a string written twice.
  """
  @spec overlap_constraint() :: atom()
  def overlap_constraint, do: @overlap_constraint

  @doc """
  The engagement an invitation becomes when a person claims it.

  Every field comes from the invitation or from the claimant — nothing is cast
  from user attributes, because there is nothing here for a claimant to choose.
  Accepting an offer is accepting *the* offer; a claim that could move its own
  start date would be a claim that could grant itself a year at a venue that
  offered a fortnight.

  `accepted_at` is the claim instant and `starts_at` is the invitation's, which
  is what makes a not-yet-active engagement representable (KTD13).
  """
  @spec claim_changeset(Invitation.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def claim_changeset(%Invitation{} = invitation, person_id, %DateTime{} = now)
      when is_binary(person_id) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> change(
      person_id: person_id,
      venue_id: invitation.venue_id,
      invitation_id: invitation.id,
      grant_id: invitation.grant_id,
      role_label: invitation.role_label,
      starts_at: invitation.starts_at,
      ends_at: invitation.ends_at,
      accepted_at: stamped_at,
      lock_version: 0,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> declare_constraints()
  end

  @doc """
  Moves the upper bound of an engagement's term to `ends_at`.

  One changeset for renewal and for ending, because they are one write: both
  set where the term closes, and the difference between "extended to next
  quarter" and "ended now" is which instant the caller passes. Splitting them
  would be two functions that had to keep the same optimistic lock, the same
  exclusion constraint and the same stamp in step.

  `optimistic_lock/2` is what makes a lost update impossible rather than
  unlikely. `HospitalityComs.Repo.update/1` raises `Ecto.StaleEntryError` when
  the version has moved, which `HospitalityComs.Engagements` turns into
  `{:error, :stale}`.
  """
  @spec close_at_changeset(t(), DateTime.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def close_at_changeset(%__MODULE__{} = engagement, %DateTime{} = ends_at, %DateTime{} = now) do
    engagement
    |> change(
      ends_at: DateTime.truncate(ends_at, :second),
      updated_at: DateTime.truncate(now, :second)
    )
    |> optimistic_lock(:lock_version)
    |> declare_constraints()
  end

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> exclusion_constraint(:period,
      name: @overlap_constraint,
      message: "overlaps an engagement this person already holds at this venue"
    )
    # No `check_constraint(:ends_at, name: :engagements_term_not_reversed)`.
    # The table carries that CHECK and it is unreachable from here: `period` is
    # `GENERATED ALWAYS AS tstzrange(starts_at, ends_at, '[)')`, generated
    # expressions are evaluated while the tuple is formed, and a reversed pair
    # makes `tstzrange/3` raise SQLSTATE 22000 before any CHECK is consulted. A
    # declaration would read as though it turned that into a field error, and
    # it never has. `HospitalityComs.EngagementsTest` pins which error arrives.
    |> check_constraint(:role_label,
      name: :engagements_role_label_present,
      message: "can't be blank"
    )
    |> check_constraint(:role_label,
      name: :engagements_role_label_within_bound,
      message: "should be at most #{Invitation.max_label_length()} character(s)"
    )
    |> unique_constraint(:invitation_id)
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:invitation_id, name: :engagements_invitation_fkey)
    |> foreign_key_constraint(:grant_id, name: :engagements_grant_fkey)
  end
end
