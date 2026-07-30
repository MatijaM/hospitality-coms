defmodule HospitalityComs.Peers.Connection do
  @moduledoc """
  A permanent link between two people, and the one write that closes it.

  A connection is created by an acceptance and ended by either party, once, at
  will. Nothing else moves it: **it outlives the visibility that produced it**,
  and it outlives every engagement either party holds. That is R13's second half
  — co-rostering creates visibility, and a *permanent* connection requires
  request and acceptance — and it is why nothing in this module consults an
  engagement.

  ## The pair is stored in one order

  `person_a_id < person_b_id`, enforced by a check constraint and by
  `open_changeset/3` sorting on the way in. Without it "at most one live
  connection per pair" is not expressible as a unique index, because the pair
  would be spelled two ways depending on who happened to ask first — and that
  index is what makes simultaneous crossed requests resolve to one connection
  rather than two.

  `HospitalityComs.Peers.ConnectionRequest` generates its equivalent columns in
  the database instead, because there the pair is a *projection* of the row's
  two person columns; here it is the row's identity, so there is nothing to
  project from.

  ## Closing is one conditional statement, not a read and a write

  `HospitalityComs.Peers.disconnect/2` issues `UPDATE … WHERE disconnected_at IS
  NULL` and answers `{:error, :already_disconnected}` when it matches nothing —
  the same manoeuvre `HospitalityComs.Rosters.remove_from_roster/3` and
  `HospitalityComs.Rooms.resume_venue_room/2` make on their own upper bounds,
  and for the reason `HospitalityComs.RoomsConcurrencyTest` measured: two
  parties disconnecting at two instants both read the same open row, both write,
  and whichever transaction commits second decides when the conversation closed.

  There is no `lock_version` here on purpose. Closing a period happens once, so
  `:stale` would be a worse answer than `:already_disconnected`; optimistic
  locking is for a repeatable mutation, which this is not.

  ## The pair's names are joined, and deliberately not preloaded

  `person_a_display_name` and `person_b_display_name` are **virtual** fields,
  filled by `HospitalityComs.Peers.Records.with_pair/1` on the reads that render
  a conversation and on the rows `accept_request/2` and `disconnect/2` read back.
  `HospitalityComs.Peers.Conversation` picks the counterpart's through
  `counterpart_display_name/2`.

  `preload: [:person_a, :person_b]` is one word and is the wrong word. It loads
  whole `%HospitalityComs.Accounts.Person{}` structs, and the only other
  identifying column `people` has is `email` — `HospitalityComs.PeersTest`
  asserts the peer surface discloses no address by value *and* by key name, and
  a `Person` struct inside a conversation is exactly the direction that
  assertion exists to catch. The join selects `display_name` and nothing else.

  Neither the join nor this module filters on activeness or on `erased_at`. A
  connection is permanent (R13), so a name that lapsed when co-rostering did
  would blank the heading of a conversation two people are still having; and an
  erased counterpart already has a name, because
  `HospitalityComs.Lifecycle.erase_person/1` writes
  `erased_display_name/0` in the statement that nulls the address.

  ## Nothing deletes a closed connection

  The messages hang off it, and after a disconnect each party still reads their
  own (R15). Deletion is confined to the lifecycle context in any case (KTD21).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.Person
  alias HospitalityComs.Peers.ConnectionRequest

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "peer_connections" do
    field :connected_at, :utc_datetime
    field :disconnected_at, :utc_datetime

    # Joined on the read that loaded this row, never stored, and never through
    # the two `belongs_to` associations below. See "The pair's names are joined".
    field :person_a_display_name, :string, virtual: true
    field :person_b_display_name, :string, virtual: true

    belongs_to :request, ConnectionRequest
    belongs_to :person_a, Person
    belongs_to :person_b, Person
    belongs_to :disconnected_by, Person

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          request_id: Ecto.UUID.t() | nil,
          request: ConnectionRequest.t() | Ecto.Association.NotLoaded.t() | nil,
          person_a_id: Ecto.UUID.t() | nil,
          person_a: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          person_b_id: Ecto.UUID.t() | nil,
          person_b: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          person_a_display_name: String.t() | nil,
          person_b_display_name: String.t() | nil,
          disconnected_by_id: Ecto.UUID.t() | nil,
          disconnected_by: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          connected_at: DateTime.t() | nil,
          disconnected_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @live_constraint :peer_connections_one_live_per_pair

  @doc """
  The name of the partial unique index that makes one live connection the most a
  pair can hold.

  Exposed so the proof suite can look for it under the same name the changeset
  declares.
  """
  @spec live_constraint() :: atom()
  def live_constraint, do: @live_constraint

  @doc """
  Opens the connection an accepted request produces, at `now`.

  The pair is sorted here, so no caller has to know the canonical order and none
  can get it wrong.
  """
  @spec open_changeset(ConnectionRequest.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def open_changeset(%ConnectionRequest{} = request, %DateTime{} = now) do
    stamped_at = DateTime.truncate(now, :second)
    {person_a_id, person_b_id} = pair(request.requester_id, request.addressee_id)

    %__MODULE__{}
    |> change(
      request_id: request.id,
      person_a_id: person_a_id,
      person_b_id: person_b_id,
      connected_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> declare_constraints()
  end

  @doc """
  Whether this conversation is still open.
  """
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{disconnected_at: nil}), do: true
  def open?(%__MODULE__{}), do: false

  @doc """
  Whether `person_id` is one of the two people this connection is between.
  """
  @spec party?(t(), Ecto.UUID.t()) :: boolean()
  def party?(%__MODULE__{person_a_id: person_id}, person_id), do: true
  def party?(%__MODULE__{person_b_id: person_id}, person_id), do: true
  def party?(%__MODULE__{}, person_id) when is_binary(person_id), do: false

  @doc """
  The party to this connection who is not `person_id`.

  Raises `FunctionClauseError` for anybody who is not a party — the callers all
  resolve the connection from one side, so a non-party reaching here is a bug
  rather than an input.
  """
  @spec counterpart(t(), Ecto.UUID.t()) :: Ecto.UUID.t()
  def counterpart(%__MODULE__{person_a_id: person_id, person_b_id: other}, person_id), do: other
  def counterpart(%__MODULE__{person_b_id: person_id, person_a_id: other}, person_id), do: other

  @doc """
  The display name of the party who is not `person_id`.

  `counterpart/2`'s shape with the guard that
  `HospitalityComsWeb.RoomChannel.rendered/1` uses: it matches on the name being
  a binary, so a connection read by a path that did not compose
  `HospitalityComs.Peers.Records.with_pair/1` is a `FunctionClauseError` here
  rather than a `null` on the wire and an `undefined` in a heading.

  Raises `FunctionClauseError` for a non-party too, for `counterpart/2`'s reason.
  """
  @spec counterpart_display_name(t(), Ecto.UUID.t()) :: String.t()
  def counterpart_display_name(
        %__MODULE__{person_a_id: person_id, person_b_display_name: name},
        person_id
      )
      when is_binary(name),
      do: name

  def counterpart_display_name(
        %__MODULE__{person_b_id: person_id, person_a_display_name: name},
        person_id
      )
      when is_binary(name),
      do: name

  @doc """
  Both people this connection is between, in the order the row stores them.
  """
  @spec parties(t()) :: [Ecto.UUID.t()]
  def parties(%__MODULE__{person_a_id: person_a_id, person_b_id: person_b_id}) do
    [person_a_id, person_b_id]
  end

  @spec pair(Ecto.UUID.t(), Ecto.UUID.t()) :: {Ecto.UUID.t(), Ecto.UUID.t()}
  defp pair(left, right) when left < right, do: {left, right}
  defp pair(left, right), do: {right, left}

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> unique_constraint([:person_a_id, :person_b_id],
      name: @live_constraint,
      message: "these two are already connected"
    )
    |> unique_constraint(:request_id)
    |> foreign_key_constraint(:request_id)
    |> foreign_key_constraint(:person_a_id)
    |> foreign_key_constraint(:person_b_id)
  end
end
