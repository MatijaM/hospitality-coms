defmodule HospitalityComs.Profiles.Disclosure do
  @moduledoc """
  One worker's decision about one attested entry and one audience.

  **This table holds overrides and nothing else.** The concurrency *default* —
  an entry at venue A is hidden from venue B when the two terms overlapped — is
  computed inside `employer_visible_attested_entries` from the periods that are
  already stored, and appears here in no form at all. What is stored is the
  worker's departure from it, because nothing computes "this worker chose to
  reveal their second job".

  ## The subject is the engagement, not the entry

  For the reason `HospitalityComs.Rooms.VenueRoomSuspension` names an
  engagement: an attested entry is an employer-zone row, and a person-zone table
  pointing at one would reach across the boundary for no gain. The engagement is
  the row that already means "this person, at this venue", and
  `attested_entries.engagement_id` is unique, so naming the engagement names
  exactly one entry.

  ## Exactly one audience, and one of the two is a venue

  `audience_venue_id` is the first employer key on a person-zone table in this
  tree, and `*_create_profiles.exs` carries the argument for it in full. In
  short: the audience of an employer disclosure *is* a venue, every spelling of
  that reaches one, and the alternative — putting the ledger in the employer
  zone — hands each venue the answer to "which of my workers is concealing
  something", which is the oracle the standing incompleteness notice exists not
  to be.

  So `employer_role` holds nothing on this table,
  `HospitalityComs.EmployerRepo`'s backstop refuses any employer query that
  reaches it, and the only path to the disclosure rule is a view that returns
  the *result* of applying it.

  `attested_entry_disclosures_one_audience` is `(audience_venue_id IS NULL) <>
  (audience_person_id IS NULL)`. Both operands are non-null booleans, so it is
  NULL-proof by construction — unlike `x IS NULL OR y = z`, which a NULL `y`
  satisfies and which U8 shipped once and had caught.

  ## The two defaults are different, and only one of them is computed

  For an **employer** the default is the concurrency rule, and it lives in the
  view. For a **peer** the default is disclosed: a peer was co-rostered with the
  worker, the venue room's roll already told them where and in what role
  (KTD15b), and an entry they can already infer is not worth a default that
  hides it. Both are overridable here, and the two are independent rows.

  ## Writing `false` is not deletion

  Revoking a disclosure sets the boolean; nothing is removed. Deletion is
  confined to the lifecycle context (KTD21), and a ledger that deleted rows
  would lose the difference between "decided to hide" and "never decided", which
  for an employer audience is the difference between an override and the
  computed default.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "attested_entry_disclosures" do
    field :disclosed, :boolean
    field :decided_at, :utc_datetime

    belongs_to :engagement, Engagement
    belongs_to :audience_venue, Venue
    belongs_to :audience_person, Person

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          engagement_id: Ecto.UUID.t() | nil,
          engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          audience_venue_id: Ecto.UUID.t() | nil,
          audience_venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          audience_person_id: Ecto.UUID.t() | nil,
          audience_person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          disclosed: boolean() | nil,
          decided_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc """
  Who a decision is about: one venue, or one other person.

  A tagged tuple rather than two functions, so the audience travels as a value
  and the two partial unique indexes have one place each that spells them.
  """
  @type audience() :: {:venue, Ecto.UUID.t()} | {:person, Ecto.UUID.t()}

  @venue_constraint :attested_entry_disclosures_one_per_venue
  @person_constraint :attested_entry_disclosures_one_per_person

  @doc """
  The name of the partial unique index that keeps one row per (entry, venue).
  """
  @spec venue_constraint() :: atom()
  def venue_constraint, do: @venue_constraint

  @doc """
  The name of the partial unique index that keeps one row per (entry, person).
  """
  @spec person_constraint() :: atom()
  def person_constraint, do: @person_constraint

  @doc """
  A decision about one entry and one audience.

  Nothing is cast. Every field is supplied by
  `HospitalityComs.Profiles.set_disclosure/4`, which has already established
  that the engagement is the caller's own — a caller that could choose the
  engagement could publish somebody else's employment.
  """
  @spec decide_changeset(Ecto.UUID.t(), audience(), boolean(), DateTime.t()) ::
          Ecto.Changeset.t(t())
  def decide_changeset(engagement_id, audience, disclosed, %DateTime{} = now)
      when is_binary(engagement_id) and is_boolean(disclosed) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> change(
      engagement_id: engagement_id,
      disclosed: disclosed,
      decided_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> put_audience(audience)
    |> declare_constraints()
  end

  @doc """
  The columns an `ON CONFLICT` replaces when a decision is taken twice.

  A second decision about the same (entry, audience) is the same row with a new
  answer, not a second row — which is what the two partial unique indexes say
  and what this list is the other half of. The audience and the subject are
  deliberately absent: they are the conflict key.
  """
  @spec replaceable_fields() :: [atom()]
  def replaceable_fields, do: [:disclosed, :decided_at, :updated_at]

  @doc """
  The conflict target for one audience, including the partial index's predicate.

  Postgres needs the predicate to match a partial unique index, and Ecto's
  keyword-list form of `:conflict_target` cannot carry one. The fragment is a
  literal — nothing here interpolates a caller's value — and it is written next
  to the constraint names it has to agree with.
  """
  @spec conflict_target(audience()) :: {:unsafe_fragment, String.t()}
  def conflict_target({:venue, _id}) do
    {:unsafe_fragment, "(engagement_id, audience_venue_id) WHERE audience_venue_id IS NOT NULL"}
  end

  def conflict_target({:person, _id}) do
    {:unsafe_fragment, "(engagement_id, audience_person_id) WHERE audience_person_id IS NOT NULL"}
  end

  @spec put_audience(Ecto.Changeset.t(t()), audience()) :: Ecto.Changeset.t(t())
  defp put_audience(changeset, {:venue, venue_id}) when is_binary(venue_id) do
    put_change(changeset, :audience_venue_id, venue_id)
  end

  defp put_audience(changeset, {:person, person_id}) when is_binary(person_id) do
    put_change(changeset, :audience_person_id, person_id)
  end

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> check_constraint(:audience_venue_id,
      name: :attested_entry_disclosures_one_audience,
      message: "must name exactly one audience"
    )
    |> unique_constraint([:engagement_id, :audience_venue_id], name: @venue_constraint)
    |> unique_constraint([:engagement_id, :audience_person_id], name: @person_constraint)
    |> foreign_key_constraint(:engagement_id)
    |> foreign_key_constraint(:audience_venue_id)
    |> foreign_key_constraint(:audience_person_id)
  end
end
