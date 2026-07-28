defmodule HospitalityComs.Lifecycle.RetainedMessageCopy do
  @moduledoc """
  A worker's own copy of one message they sent, kept after their engagement
  ended.

  ## It is a copy, and that is KTD16 rather than duplication

  The alternative — a filtered view over the employer-zone `room_messages` row —
  makes one row carry two deadlines, and the shorter silently wins. A person
  whose engagement ended long after a shift would lose their own copy on the
  shift's clock, which is precisely backwards: the venue's operational history
  is the thing with the shorter interest and the worker's record of their own
  words is the thing the product exists to give them.

  So the body travels. The venue's copy of the same message is deleted thirty
  days after the shift room closes; this one lives ninety days past the
  engagement's end, and the gap between the two numbers is what makes the
  separation observable rather than merely argued.

  ## `source_message_id` is not a foreign key

  It is the idempotence key and nothing else — one copy per (engagement,
  message), which is what makes re-running an expiry announcement free. A
  foreign key here would be wrong three separate ways:

    * a person-zone key into the employer zone is a second crossing, and KTD2
      permits one;
    * `ON DELETE RESTRICT` would make the shift-history sweep fail the instant a
      copy outlived its original;
    * `ON DELETE CASCADE` would delete this row on the venue's clock, which is
      the failure the separation exists to prevent.

  ## Ownership is a composite key, not an `exists?`

  `(engagement_id, person_id)` is `MATCH FULL` into `engagements (id,
  person_id)`, the discipline U9 established for `attested_entry_disclosures`
  and the reason there is no way to file somebody else's words under your own
  archive.

  ## Nothing here is castable

  Every field comes from a row `HospitalityComs.Lifecycle` resolved inside its
  own transaction. Copies are written in bulk with `insert_all`, so the
  primary key is minted in Elixir — `binary_id` autogeneration happens in Ecto's
  insert path and `insert_all` is not on it.
  """

  use Ecto.Schema

  alias HospitalityComs.Engagements.Engagement

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "retained_message_copies" do
    field :person_id, :binary_id
    field :source_message_id, :binary_id
    field :body, :string
    field :sent_at, :utc_datetime
    field :retained_at, :utc_datetime
    field :delete_after, :utc_datetime

    belongs_to :engagement, Engagement

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          engagement_id: Ecto.UUID.t() | nil,
          engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          person_id: Ecto.UUID.t() | nil,
          source_message_id: Ecto.UUID.t() | nil,
          body: String.t() | nil,
          sent_at: DateTime.t() | nil,
          retained_at: DateTime.t() | nil,
          delete_after: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
