defmodule HospitalityComs.Peers.PeerMessage do
  @moduledoc """
  One thing one person said to another, in the person zone, naming its author
  directly.

  ## Why this names a person where `room_messages` names an engagement

  KTD15b resolves authorship through the engagement for room messages, and the
  reason is KTD2: `room_messages` is an employer-zone row and **no employer-zone
  table may name a human**. Neither half of that reasoning reaches here. This is
  a person-zone row between two people who need not be employed anywhere at all
  — a peer conversation outlives every engagement either party holds (R13) — so
  an engagement is a key this row could not always have, and the employer role
  holds no privilege on the table in any case.

  So `author_id` references `people`, like every other key in this unit, and the
  boundary suite's positive crossing test is what keeps that from quietly
  becoming a second bridge: `engagements` must remain the only table *outside*
  the person zone with a foreign key to `people`.

  ## After a disconnect, each party keeps their own

  R15's disconnect closes the conversation for both. What each of them keeps is
  the messages they wrote — `HospitalityComs.Peers.list_messages/2` filters on
  `author_id` once the connection is closed — and nothing is deleted to achieve
  it. The reasoning is KTD15c's, applied one table over: the other person's
  words are not the disconnecting party's to destroy, and a conversation that
  vanished from both sides would take somebody else's record with it.

  There is no retention column. KTD16's four triggers are U10's, and a peer
  conversation is not one of them.

  ## The author's name is joined, never stored

  `author_display_name` is a **virtual** field, filled by
  `HospitalityComs.Peers.Records.with_author/1` on every read and on the row the
  send reads back — `HospitalityComs.Rooms.RoomMessage`'s shape and its first two
  reasons, one of which does not transfer:

    * a stored copy is denormalised, so a rename never reaches it and the
      conversation shows what used to be true;
    * erasure would have to rewrite a number of rows proportional to
      **messages**. `HospitalityComs.Lifecycle.erase_person/1` overwrites
      `people.display_name` in one statement, and joining is what makes an
      erased author's words render under
      `HospitalityComs.Lifecycle.erased_display_name/0` with nothing having
      visited this table;
    * KTD2 is the reason that does **not** apply. `room_messages` is an
      employer-zone row and may name no human; this row already names one
      directly, so a name column here would break nothing about the bridge. It
      is still not a column, for the two reasons above.

  The join carries no activeness predicate and no `erased_at` filter, which is
  R15 rather than a copy of `with_author/1`'s reasoning: a connection outlives
  the visibility that produced it and every engagement either party holds, so a
  name that lapsed with co-rostering would blank a conversation two people are
  still having.

  ## The body is bounded in the database as well as here

  Both bounds are mirrored from `room_messages` for the reason U5 mirrored a
  label length: a body the database refuses is a body the changeset should have
  refused, and a check constraint is what stops a second writer discovering
  otherwise.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Peers.Connection

  # The number `peer_messages_body_within_bound` in `*_create_peer_graph.exs`
  # enforces, which was in turn written to match `room_messages`. The first of
  # those is a pair that must agree and is checked by reading the CHECK back out
  # in `test/hospitality_coms/constant_agreement_test.exs`; the second is a
  # resemblance nothing depends on, deliberately left as one rather than derived
  # from `HospitalityComs.Rooms.RoomMessage` (issue #42, item 5).
  @max_body_length 4000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "peer_messages" do
    field :body, :string
    field :sent_at, :utc_datetime

    # Joined on the read that loaded this row, never stored. See the moduledoc.
    field :author_display_name, :string, virtual: true

    belongs_to :connection, Connection
    belongs_to :author, Person

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          connection_id: Ecto.UUID.t() | nil,
          connection: Connection.t() | Ecto.Association.NotLoaded.t() | nil,
          author_id: Ecto.UUID.t() | nil,
          author: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          author_display_name: String.t() | nil,
          body: String.t() | nil,
          sent_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  The longest body a peer message may carry.
  """
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  @doc """
  A message from `author_id` on `connection`, at `now`.

  The body is the only thing cast. Everything else is resolved by the caller
  against a connection it has already established the author is a party to — a
  castable `connection_id` would be a way to write into somebody else's
  conversation, and a castable `sent_at` a way to backdate one.
  """
  @spec sent_changeset(Connection.t(), Ecto.UUID.t(), String.t(), DateTime.t()) ::
          Ecto.Changeset.t(t())
  def sent_changeset(%Connection{} = connection, author_id, body, %DateTime{} = now)
      when is_binary(author_id) and is_binary(body) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> cast(%{body: body}, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body_length)
    |> put_change(:connection_id, connection.id)
    |> put_change(:author_id, author_id)
    |> put_change(:sent_at, stamped_at)
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
    |> check_constraint(:body, name: :peer_messages_body_present, message: "can't be blank")
    |> check_constraint(:body,
      name: :peer_messages_body_within_bound,
      message: "should be at most #{@max_body_length} character(s)"
    )
    |> foreign_key_constraint(:connection_id)
    |> foreign_key_constraint(:author_id)
  end
end
