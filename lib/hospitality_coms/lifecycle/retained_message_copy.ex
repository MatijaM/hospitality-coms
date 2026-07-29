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

  ## The row is written with the message; `delete_after` is written later

  A copy cannot be taken later than the instant its source may be deleted, and
  the earliest such instant is a shift message's `closes_at + 30 days` — which
  every ordinary term outlives. So `HospitalityComs.Rooms` writes the copy in
  the same transaction as the message, through
  `HospitalityComs.Lifecycle.retain_message/3`.

  `delete_after` is **null** until the engagement's term closes, exactly as
  `room_messages.delete_after` is null until the venue closes. The reason is the
  same in both: the clock has an origin that has not happened yet. Here it is
  `ends_at`, which a renewal can still move while the term is open and which
  nothing can move once it has closed — `renew_engagement/3` answers on
  activeness and `end_engagement/2` on "has not closed". So the stamp is written
  exactly once, by `HospitalityComs.Lifecycle.retain_own_messages/2`, from a
  value that can never be revised.

  ## `source_message_id` is not a foreign key

  It is the idempotence key and nothing else — one copy per (engagement,
  message), which is what makes re-running an expiry announcement free. A
  foreign key here would be wrong two separate ways, and either alone settles
  it:

    * `ON DELETE RESTRICT` would make the shift-history sweep fail the instant a
      copy outlived its original;
    * `ON DELETE CASCADE` would delete this row on the venue's clock, which is
      the failure the separation exists to prevent.

  It is **not** because a person-zone key into the employer zone would be a
  second crossing. KTD2's single crossing is about naming a *person*; arrows
  point into the employer zone freely, and
  `attested_entry_disclosures.audience_venue_id` is already such a key and is
  documented as deliberate. Leaving that reason standing would let a later unit
  cite it to refuse a legitimate key.

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

  **There is therefore no changeset in front of `body`, and that makes one
  agreement load-bearing** (issue #42, item 5). `retained_message_copies_body_within_bound`
  has to admit anything `room_messages_body_within_bound` admits, because this
  row is a verbatim copy of one of those. If it did not, a message the venue
  accepted would raise `Postgrex.Error` out of the retention transaction rather
  than returning an error anybody could act on — and the transaction it would
  take down is the one that gives a worker their own copy of what they said.

  The relation is an ordering rather than an equality: this bound may be wider
  than `HospitalityComs.Rooms.RoomMessage.max_body_length/0`, never narrower.
  Both sides are values only a migration can move, so it is asserted in
  `test/hospitality_coms/constant_agreement_test.exs` rather than derived.
  Adding a `validate_length/3` here would not help — nothing on this path builds
  a changeset to run it.
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
