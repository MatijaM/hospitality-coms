defmodule HospitalityComs.Profiles.AttestedEntry do
  @moduledoc """
  An employer's assertion that an engagement happened, written into the person's
  portable record.

  ## It is keyed on the engagement, not on the person

  Which is KTD2 in its narrowest and most load-bearing form. `attested_entries`
  is an employer-zone table — every row carries `venue_id`, every read is per
  venue — and no employer-zone table may name a human. So this references
  `engagements (id, venue_id)`, and the person is reached by way of the bridge
  or not at all. Written the other way it would be the second crossing, and
  KTD2's blast-radius argument for erasure would be false.

  ## It is written by the claim and by nothing else

  There is no path in this application that creates an attested entry directly.
  It is inserted in the same `Ecto.Multi` as the engagement it attests
  (`HospitalityComs.Engagements.claim_invitation/2`), and the unique index on
  `engagement_id` is what makes "one engagement, one entry" a property of the
  schema rather than of whoever wrote the context: a renewal extends the
  engagement and produces no second entry, because there is no second entry it
  could produce.

  A crash between the engagement insert and this one would leave an engagement
  with no portable history, which is the product. That is why the two are one
  transaction.

  ## What is deliberately not here

  No `role_label` and no period. Both live on the engagement — KTD15b puts the
  display label there so that erasure reduces a number of rows proportional to
  engagements rather than to messages, and the period is the engagement's by
  definition. Copying either would create two records of one fact that a
  renewal could put out of step.

  ## Who owns this module

  U5 wrote the schema because U5 is the unit that has to insert the row inside
  the claim's transaction. U9 owns the *context* — `HospitalityComs.Profiles` —
  and extended this schema rather than replacing it, which is to say it added
  nothing: the row was already the right shape, and the unit's work is entirely
  in the rules about who may read it.

  `employer_role` holds no privilege on this table at all: not a `SELECT`, and
  the absence is asserted in `HospitalityComs.BoundaryTest`. That is KTD3 and it
  is why the two views exist. The hidden-entry rule is **per row** and a table
  grant cannot express a per-row rule, so the employer reads
  `employer_visible_attested_entries` — owned by the role that owns this table,
  granted `SELECT` and nothing else, filtering on the employer and the instant
  that `HospitalityComs.EmployerRepo.scoped_transaction/2` wrote into the
  transaction.

  Row-level security would not have been an alternative here even at the cost
  KTD3 names. `HospitalityComs.Repo` connects as a **superuser**, and a
  superuser bypasses row-level security whether or not a policy is `FORCE`d — so
  a per-row policy on this table would read as a tier and provide none.
  `*_create_employer_visible_view.exs` carries the measurement.

  Retention never deletes one (KTD16). An attested entry and the engagement
  behind it are the person's record of their own working life, and the only
  clock that reaches them is erasure's.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "attested_entries" do
    field :attested_at, :utc_datetime

    belongs_to :venue, Venue
    belongs_to :engagement, Engagement

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          engagement_id: Ecto.UUID.t() | nil,
          engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          attested_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  The entry an engagement produces when it is claimed.

  Takes the engagement's id and venue explicitly rather than the struct, because
  it is built inside the same `Ecto.Multi` step sequence and the engagement's id
  is chosen before the insert — so there is no persisted struct to read it off
  and no reason to wait for one.
  """
  @spec attest_changeset(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def attest_changeset(engagement_id, venue_id, %DateTime{} = now)
      when is_binary(engagement_id) and is_binary(venue_id) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> change(
      engagement_id: engagement_id,
      venue_id: venue_id,
      attested_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> unique_constraint(:engagement_id)
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:engagement_id, name: :attested_entries_engagement_fkey)
  end
end
