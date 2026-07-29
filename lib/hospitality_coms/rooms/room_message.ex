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

  ## The author's name is joined, never stored

  `author_display_name` is a **virtual** field (#66), filled by
  `HospitalityComs.Rooms.Records.with_author_display_name/1` on every read and
  from the sender's own scope on the write. Three reasons it is not a column:

    * a stored copy is a denormalised name that a rename never reaches, so the
      room would show what somebody used to be called;
    * a stored copy is a *person's name* written into an employer-zone row,
      which is KTD2 broken — `room_messages` would become a second crossing;
    * erasure would then have to rewrite a number of rows proportional to
      **messages**, which is the unbounded write KTD15 put the label on the
      engagement to avoid.

  Joining is what makes an erased author's history render under
  `HospitalityComs.Lifecycle.erased_display_name/0` with nothing having visited
  these rows, and it is what makes a message from a **closed** engagement carry
  a name at all — the join reaches `engagements` and then `people` with no
  activeness predicate anywhere, which a client-side join against the venue
  room's current roll cannot do.

  ## Bodies are retained even when their author is erased

  KTD15c: erasure is *identifier* erasure. Deleting message bodies would destroy
  conversations belonging to other people, so bodies survive under a
  non-identifying label. A body can still name someone; that is a stated,
  accepted position for this POC rather than an oversight.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Engagements.Engagement
  alias HospitalityComs.Lifecycle
  alias HospitalityComs.Rooms.ShiftRoom
  alias HospitalityComs.Venues.Venue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_messages" do
    field :body, :string
    field :sent_at, :utc_datetime

    # KTD16's deadline, stamped rather than joined. `closes_at + 30 days` for a
    # shift-room message, from the room the sender had already resolved; **null**
    # for a venue-room message, because venue-room history has no clock at all
    # while the venue exists. `HospitalityComs.Lifecycle.close_venue/2` is what
    # gives it one, and it stamps only the rows where this is still null — so a
    # shift message's deadline is never moved by the venue closing.
    field :delete_after, :utc_datetime

    belongs_to :venue, Venue
    belongs_to :shift_room, ShiftRoom
    belongs_to :author_engagement, Engagement

    # Joined on every read, never stored. See the moduledoc.
    field :author_display_name, :string, virtual: true

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
          delete_after: DateTime.t() | nil,
          author_display_name: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # The number `room_messages_body_within_bound` in `*_create_rooms.exs`
  # enforces, and it is declared twice because a migration literal cannot move
  # (issue #42, item 5). The two are compared in
  # `test/hospitality_coms/constant_agreement_test.exs`, which reads the CHECK
  # back out of `pg_constraint`.
  #
  # It is *not* derived from and does not derive `HospitalityComs.Peers.PeerMessage`
  # or `HospitalityComs.Profiles.CorrectionRequest`, which declare the same
  # figure. Nothing depends on those three agreeing; coupling them would buy a
  # `Peers → Rooms` and a `Profiles → Rooms` compile-time dependency to enforce an
  # agreement no mechanism needs, and would still leave every migration literal
  # unchecked.
  #
  # **One relation here is real, and it is an ordering.**
  # `HospitalityComs.Lifecycle.RetainedMessageCopy` holds a verbatim copy of one
  # of these bodies, has no length validation, and is written with `insert_all` —
  # so its own CHECK is reached with no changeset in front of it. Raising this
  # number past `retained_message_copies_body_within_bound` would not return a
  # changeset error; it would raise `Postgrex.Error` inside the retention
  # transaction. That ordering is asserted in the same test file.
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
    |> put_change(:delete_after, Lifecycle.history_deadline(room.closes_at))
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
