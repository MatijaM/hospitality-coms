defmodule HospitalityComs.Rooms.RoomMessage do
  @moduledoc """
  One message, in one of the two room kinds, attributed to an engagement.

  ## The author is an engagement, never a person

  KTD15b. `author_engagement_id` is a composite key into
  `engagements (id, venue_id)` with `MATCH FULL`, and the engagement already
  carries the employer-authored `role_label` that a client renders. Three things
  follow, and each of them is why:

    * no worker's name is ever written into an employer-zone row (KTD2), so this
      table is not a second crossing;
    * erasure reduces a number of rows proportional to *engagements* rather than
      to messages, which is the difference between a bounded write and an
      unbounded one (KTD15);
    * no read path has to remember a null-coalesce on the hottest query in the
      application, because the label is on a row that is never nulled.

  A message at venue A cannot be attributed to an engagement at venue B, and
  that is the foreign key rather than this module.

  ## Which room it is in

  `shift_room_id` null is the venue room; set is that shift room. One table
  rather than two because the two differ in which people may read them and in
  nothing else — the row is the same row, and KTD16's two retention clocks are a
  stamped column U10 adds, not a second table.

  ## Bodies are retained even when their author is erased

  KTD15c: erasure is *identifier* erasure. Deleting message bodies would destroy
  conversations belonging to other people, so bodies survive under a
  non-identifying label. A body can still name someone; that is a stated,
  accepted position for this POC rather than an oversight.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_messages" do
    field :body, :string
    field :sent_at, :utc_datetime

    belongs_to :venue, Venue
    belongs_to :shift_room, ShiftRoom
    belongs_to :author_engagement, Engagement

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          venue_id: Ecto.UUID.t() | nil,
          venue: Venue.t() | Ecto.Association.NotLoaded.t() | nil,
          shift_room_id: Ecto.UUID.t() | nil,
          shift_room: ShiftRoom.t() | Ecto.Association.NotLoaded.t() | nil,
          author_engagement_id: Ecto.UUID.t() | nil,
          author_engagement: Engagement.t() | Ecto.Association.NotLoaded.t() | nil,
          body: String.t() | nil,
          sent_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @max_body_length 4000

  @doc """
  The longest message body the schema accepts, in characters.
  """
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  @doc """
  A message in the venue room of `engagement`'s venue.

  The author is the engagement the caller already resolved, so the venue comes
  from it rather than from attributes: a message cannot be posted into a venue
  its author is not engaged at, because there is no argument that would say so.
  """
  @spec venue_room_changeset(Engagement.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def venue_room_changeset(%Engagement{} = engagement, body, %DateTime{} = now) do
    engagement |> base_changeset(body, now) |> declare_constraints()
  end

  @doc """
  A message in `shift_room`, authored by `engagement`.

  Both are resolved by `HospitalityComs.Rooms` before this is called, and the
  composite foreign keys refuse a pair belonging to two different venues
  whatever that module believes.
  """
  @spec shift_room_changeset(ShiftRoom.t(), Engagement.t(), String.t(), DateTime.t()) ::
          Ecto.Changeset.t(t())
  def shift_room_changeset(
        %ShiftRoom{} = room,
        %Engagement{} = engagement,
        body,
        %DateTime{} = now
      ) do
    engagement
    |> base_changeset(body, now)
    |> put_change(:shift_room_id, room.id)
    |> declare_constraints()
  end

  @spec base_changeset(Engagement.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  defp base_changeset(%Engagement{} = engagement, body, now) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> cast(%{body: body}, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body_length)
    |> put_change(:venue_id, engagement.venue_id)
    |> put_change(:author_engagement_id, engagement.id)
    |> put_change(:sent_at, stamped_at)
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
  end

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> check_constraint(:body, name: :room_messages_body_present, message: "can't be blank")
    |> check_constraint(:body,
      name: :room_messages_body_within_bound,
      message: "should be at most #{@max_body_length} character(s)"
    )
    |> unique_constraint([:id, :venue_id])
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:shift_room_id, name: :room_messages_shift_room_fkey)
    |> foreign_key_constraint(:author_engagement_id, name: :room_messages_author_fkey)
  end
end
