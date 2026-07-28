defmodule HospitalityComs.Profiles.CorrectionRequest do
  @moduledoc """
  A worker's contest of an employer's assertion, and the employer's answer.

  R16's third clause: attested entries are employer-asserted, person-uneditable,
  and **accept worker correction requests**. This is the row that makes the
  third true without making the second false.

  ## It is employer zone, and it is keyed on the engagement

  The assertion belongs to a venue, and the answer is the venue's to give — so
  the row carries `venue_id` and is bound by the same row-level security policy
  every employer-zone table carries. It names the working relationship as
  `engagements (id, venue_id)` rather than naming a person, because no
  employer-zone row may name a human (KTD2); the composite key with `MATCH FULL`
  is what stops a request at venue A naming an engagement at venue B.

  ## Two writers, two roles, and neither holds the other's privileges

  The **worker** creates it, through `HospitalityComs.Repo` under a
  `HospitalityComs.Accounts.PersonScope`. `employer_role` holds no `INSERT`
  here, deliberately: a session that could write one could manufacture a
  complaint and then resolve it. That is the same manoeuvre
  `HospitalityComs.Engagements.claim_invitation/2` makes when it writes an
  attested entry as the application's own role.

  The **employer** resolves it, through `HospitalityComs.EmployerRepo` under a
  grant, with `SELECT` and an `UPDATE` scoped to the four columns a resolution
  writes.

  ## Resolving changes no attested entry, and cannot

  An attested entry derives from its engagement and there is no write path to
  one outside the claim. So `accepted` is an acknowledgement rather than an
  edit: the actual correction, if the employer makes one, is a change to the
  engagement through `HospitalityComs.Engagements`, and it flows into the entry
  because the entry was never a copy of it in the first place.

  Declining leaves the entry and the request both readable — to the worker, to
  the attesting venue, and to any venue the entry itself is disclosed to. A
  refusal that erased the request would let an employer make a contest
  disappear.

  ## The resolution is complete or absent

  `correction_requests_resolution_complete` pairs `resolved_at`, `resolution`
  and `resolved_by_grant_id` with `IS NULL` comparisons on both sides, so it is
  NULL-proof: a resolved request always says when, how, and under which
  authority, and an outstanding one says none of the three.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Venues.EmployerGrant
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "correction_requests" do
    field :body, :string
    field :requested_at, :utc_datetime
    field :resolved_at, :utc_datetime
    field :resolution, :string

    belongs_to :venue, Venue
    belongs_to :engagement, Engagement
    belongs_to :resolved_by_grant, EmployerGrant

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          engagement_id: Ecto.UUID.t() | nil,
          engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          resolved_by_grant_id: Ecto.UUID.t() | nil,
          resolved_by_grant: EmployerGrant.t() | Ecto.Association.NotLoaded.t() | nil,
          body: String.t() | nil,
          requested_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          resolution: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc """
  The two answers an employer may give, and the only two the CHECK admits.
  """
  @type resolution() :: :accepted | :declined

  # The same bound `room_messages` and `peer_messages` carry.
  @max_body_length 4000

  @resolutions ~w(accepted declined)a

  @doc """
  The longest a correction request's body may be.
  """
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  @doc """
  The answers a resolution may carry.
  """
  @spec resolutions() :: [resolution()]
  def resolutions, do: @resolutions

  @doc """
  A worker's contest of one of their own engagements' attested entries.

  `venue_id` and `engagement_id` are put rather than cast, both taken from an
  engagement `HospitalityComs.Profiles.request_correction/3` has already
  resolved against the caller's own `person_id`. The body is the only thing the
  caller chooses.
  """
  @spec request_changeset(Engagement.t(), map(), DateTime.t()) :: Ecto.Changeset.t(t())
  def request_changeset(%Engagement{} = engagement, attrs, %DateTime{} = now)
      when is_map(attrs) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> cast(attrs, [:body])
    |> put_change(:venue_id, engagement.venue_id)
    |> put_change(:engagement_id, engagement.id)
    |> put_change(:requested_at, stamped_at)
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
    |> validate_required([:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body_length)
    |> declare_constraints()
  end

  @doc """
  The three columns and the stamp a resolution writes, as an `update_all` set.

  Returned as a keyword list rather than as a changeset because resolving is a
  conditional `UPDATE` — the predicate is what makes answering twice a refusal
  rather than a second answer — and a changeset would need a row read in front
  of it that the predicate exists to avoid.
  """
  @spec resolution_set(resolution(), Ecto.UUID.t(), DateTime.t()) :: keyword()
  def resolution_set(resolution, grant_id, %DateTime{} = now)
      when resolution in @resolutions and is_binary(grant_id) do
    stamped_at = DateTime.truncate(now, :second)

    [
      resolved_at: stamped_at,
      resolution: Atom.to_string(resolution),
      resolved_by_grant_id: grant_id,
      updated_at: stamped_at
    ]
  end

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> check_constraint(:body,
      name: :correction_requests_body_present,
      message: "can't be blank"
    )
    |> check_constraint(:body,
      name: :correction_requests_body_within_bound,
      message: "should be at most #{@max_body_length} character(s)"
    )
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:engagement_id, name: :correction_requests_engagement_fkey)
    |> foreign_key_constraint(:resolved_by_grant_id,
      name: :correction_requests_resolved_by_grant_fkey
    )
  end
end
