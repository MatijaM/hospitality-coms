defmodule HospitalityComs.Venues.EmployerGrant do
  @moduledoc """
  An outstanding authority to administer a venue.

  ## It names no human, and that is the whole of the design

  There is no `person_id` here and there will not be one. No employer-zone
  table may carry one (KTD2) — the proof suite asserts it against
  `pg_constraint`, not against this docstring — so a grant is a row about a
  *venue*: this venue has an administrable authority outstanding, issued at
  this instant, revoked at that one or not yet.

  Which person holds it is recorded on the bridge. U5's `engagements` carries
  `person_id` and will carry `grant_id`, referencing
  `employer_grants (id, venue_id)`, so the crossing is made from the person's
  side and the employer zone stays free of names. That direction is also why
  this table can exist before the bridge does: it points at nothing that has
  not been built.

  A revocation carries the same shape: `revoked_by_grant_id` names the grant
  that closed this one, not the person who decided to. See
  `revocation_changeset/3`.

  ## Lineage instead of a holder

  `granted_by_grant_id` names the grant that issued this one, through a
  composite foreign key on `(granted_by_grant_id, venue_id)` — so a grant at
  one venue cannot descend from a grant at another. It is null on exactly one
  grant per venue: the one seeded when the venue was created, which has nobody
  above it. That is what makes the founding grant identifiable without naming
  its holder, and it is what exercises KTD2's composite-key discipline inside
  this unit rather than only promising it to later ones.

  ## Live is derived, never stored

  A grant is live at instant `t` when `granted_at <= t` and either it was never
  revoked or `t < revoked_at` — half-open, matching KTD4, so the revocation
  instant itself belongs to the revoked side and no instant falls in both
  states. Nothing stores a boolean: a cached authorization decision that
  outlives its reason is the failure the whole design exists to prevent.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "employer_grants" do
    field :granted_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :venue, Venue
    belongs_to :granted_by, __MODULE__, foreign_key: :granted_by_grant_id
    belongs_to :revoked_by, __MODULE__, foreign_key: :revoked_by_grant_id

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          granted_by_grant_id: Ecto.UUID.t() | nil,
          granted_by: t() | Ecto.Association.NotLoaded.t() | nil,
          revoked_by_grant_id: Ecto.UUID.t() | nil,
          revoked_by: t() | Ecto.Association.NotLoaded.t() | nil,
          granted_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  The grant seeded when a venue is created.

  Its id is supplied rather than generated, because the employer scope that
  runs the insert has to name the grant it is acting under before the row
  exists. `granted_by_grant_id` stays null: this is the grant with nobody above
  it.
  """
  @spec founding_changeset(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          Ecto.Changeset.t(t())
  def founding_changeset(id, venue_id, %DateTime{} = now)
      when is_binary(id) and is_binary(venue_id) do
    %__MODULE__{}
    |> change(id: id, venue_id: venue_id)
    |> issued_at(now)
  end

  @doc """
  A grant issued by an existing one, at the same venue.
  """
  @spec issued_changeset(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def issued_changeset(venue_id, granted_by_grant_id, %DateTime{} = now)
      when is_binary(venue_id) and is_binary(granted_by_grant_id) do
    %__MODULE__{}
    |> change(venue_id: venue_id, granted_by_grant_id: granted_by_grant_id)
    |> foreign_key_constraint(:granted_by_grant_id, name: :employer_grants_granted_by_fkey)
    |> issued_at(now)
  end

  @doc """
  Closes a grant at `now`, under the authority of `revoked_by_grant_id`.

  The instant is the unit of work's, so a grant revoked and a membership query
  run in the same request agree on which side of the boundary the work fell.

  The revoking grant is recorded because a revocation nobody can attribute is
  an administrative act with no author, and the only attribution this zone can
  hold is a grant: naming the human would be a person key in the employer zone.
  It may be the closed grant's own id — a holder standing down — and it is null
  on every grant that is still live, held in opposition to `revoked_at` by a
  check constraint.
  """
  @spec revocation_changeset(t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def revocation_changeset(%__MODULE__{} = grant, revoked_by_grant_id, %DateTime{} = now)
      when is_binary(revoked_by_grant_id) do
    stamped_at = DateTime.truncate(now, :second)

    grant
    |> change(
      revoked_at: stamped_at,
      revoked_by_grant_id: revoked_by_grant_id,
      updated_at: stamped_at
    )
    |> check_constraint(:revoked_at,
      name: :employer_grants_revoked_after_granted,
      message: "cannot precede the grant"
    )
    |> check_constraint(:revoked_by_grant_id,
      name: :employer_grants_revocation_attributed,
      message: "must be set exactly when the grant is revoked"
    )
    |> foreign_key_constraint(:revoked_by_grant_id, name: :employer_grants_revoked_by_fkey)
  end

  @spec issued_at(Ecto.Changeset.t(t()), DateTime.t()) :: Ecto.Changeset.t(t())
  defp issued_at(changeset, now) do
    stamped_at = DateTime.truncate(now, :second)

    changeset
    |> put_change(:granted_at, stamped_at)
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
    |> foreign_key_constraint(:venue_id)
    |> unique_constraint([:id, :venue_id])
  end

  @doc """
  Grants of one venue that are live at `instant`.

  Half-open: a grant revoked at exactly `instant` is not live, matching the
  convention every period in this application follows.
  """
  @spec live_at(Ecto.UUID.t(), DateTime.t()) :: Ecto.Query.t()
  def live_at(venue_id, %DateTime{} = instant) when is_binary(venue_id) do
    from grant in __MODULE__,
      where: grant.venue_id == ^venue_id,
      where: grant.granted_at <= ^instant,
      where: is_nil(grant.revoked_at) or grant.revoked_at > ^instant
  end
end
