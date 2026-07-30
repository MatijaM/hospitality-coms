defmodule HospitalityComs.Peers.ConnectionRequest do
  @moduledoc """
  One approach between two people, its outcome, and who may approach next.

  A pair has at most one *current* request — `superseded_at` is null — and that
  row carries the whole of the pair's state. Everything U8 refuses is read off
  it, and nothing about it is derived from anybody's employment, which is what
  makes KTD19's block survive new co-rostering.

  ## Four states, and one of them is not stored

  | State | The row | What it means |
  |---|---|---|
  | `:pending` | neither `accepted_at` nor `declined_at`, and the pair is visible | outstanding; the addressee may answer |
  | `:lapsed` | the same row, and the pair is **not** visible at this instant | the visibility that carried it has gone; the requester is told so |
  | `:declined` | `declined_at` set | refused, and `blocked_initiator_id` is the requester |
  | `:accepted` | `accepted_at` set | `peer_connections` holds the result |

  `:lapsed` is the interesting one. It is R14's "expired", and it is derived
  from `HospitalityComs.Peers.Visibility` at the asking instant rather than
  stored — so the same clock advance that lapses the visibility lapses the
  request, in the same query, with no sweeper and no column. Storing it would
  need a job that visited every pending request whenever any engagement moved,
  which is the design KTD6b rejects at membership scale.

  `state/2` therefore takes the visibility as a boolean rather than looking it
  up: the query that loads the requests already knows, and a schema module that
  asked the database would be a second place for "visible" to mean something.

  ## `blocked_initiator_id` is KTD19

  "Fresh acceptance is directional": after a decline or a disconnect only the
  non-blocked party may send the next request. The party who refused keeps the
  initiative, and the party who was refused does not — a decline blocks the
  requester, and a disconnect blocks the counterpart of whoever disconnected,
  because disconnection is the origin document's only stated remedy for harm and
  a symmetric reading would hand the remedy back to the person it was used
  against.

  It is a **column on this row** rather than a rule over engagements, and that
  is the whole of "the block survives new co-rostering". A block derived from
  employment would evaporate the moment the pair worked together again, which is
  the one thing the KTD says it must not do.

  Blocks are read off the *current* row and not accumulated over every row the
  pair has ever had. KTD19 governs "the next request"; accumulating would make a
  pair who each declined the other once permanently unreachable to both, which
  nothing asks for, and it would make a fresh acceptance unable to clear
  anything.

  ## Both names, never the counterpart's

  `requester_display_name` and `addressee_display_name` are **virtual**, filled
  by `HospitalityComs.Peers.Records.with_parties/1` on every read and on the two
  rows a write reads back. They are a pair rather than one viewer-relative
  `counterpart_display_name` because this row already names both people by id
  and lets the reader pick: `HospitalityComsWeb.PeerChannel.rendered_request/1`
  serves four call sites and takes no viewer, so a counterpart's name would make
  one entity's shape depend on who asked.

  Nothing new is disclosed by carrying them. A request exists only between two
  people who were visible to each other, and
  `HospitalityComs.Peers.list_visible_peers/1` has carried the counterpart's
  name since #66.

  ## Nothing here is castable from user attributes

  Every changeset below takes its values as arguments. A request has exactly one
  thing in it the caller chooses — who it is addressed to — and that is resolved
  against visibility before it reaches here. A castable `requested_at` would be
  a way to backdate an approach, and a castable `blocked_initiator_id` would be
  a way to block somebody by asking.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.Person

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "connection_requests" do
    field :requested_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :declined_at, :utc_datetime
    field :superseded_at, :utc_datetime

    # Generated in the database from the two person ids, so a unique index has a
    # canonical spelling of an unordered pair to be unique over. Read-only here:
    # `GENERATED ALWAYS` refuses a write, and nothing wants one.
    field :pair_low_id, Ecto.UUID, read_after_writes: true
    field :pair_high_id, Ecto.UUID, read_after_writes: true

    # Derived on the read that loaded this row, never stored. See the moduledoc.
    field :state, Ecto.Enum, values: [:pending, :lapsed, :declined, :accepted], virtual: true

    # Joined on the read that loaded this row, never stored. See "Both names,
    # never the counterpart's" in the moduledoc.
    field :requester_display_name, :string, virtual: true
    field :addressee_display_name, :string, virtual: true

    belongs_to :requester, Person
    belongs_to :addressee, Person
    belongs_to :blocked_initiator, Person

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          requester_id: Ecto.UUID.t() | nil,
          requester: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          addressee_id: Ecto.UUID.t() | nil,
          addressee: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          blocked_initiator_id: Ecto.UUID.t() | nil,
          blocked_initiator: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          requested_at: DateTime.t() | nil,
          accepted_at: DateTime.t() | nil,
          declined_at: DateTime.t() | nil,
          superseded_at: DateTime.t() | nil,
          pair_low_id: Ecto.UUID.t() | nil,
          pair_high_id: Ecto.UUID.t() | nil,
          state: state() | nil,
          requester_display_name: String.t() | nil,
          addressee_display_name: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc "Where one approach has got to, at the instant somebody asked."
  @type state() :: :pending | :lapsed | :declined | :accepted

  @current_constraint :connection_requests_one_current_per_pair

  @doc """
  The name of the partial unique index that makes one current request the most a
  pair can hold.

  Exposed so the proof suite can look for it in `pg_index` under the same name
  the changeset declares, rather than by a string written twice.
  """
  @spec current_constraint() :: atom()
  def current_constraint, do: @current_constraint

  @doc """
  Opens a request from `requester_id` to `addressee_id` at `now`.

  Nothing is cast. The addressee is resolved against visibility before this is
  reached, and every other column is either stamped here or generated by the
  database.
  """
  @spec open_changeset(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def open_changeset(requester_id, addressee_id, %DateTime{} = now)
      when is_binary(requester_id) and is_binary(addressee_id) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> change(
      requester_id: requester_id,
      addressee_id: addressee_id,
      requested_at: stamped_at,
      inserted_at: stamped_at,
      updated_at: stamped_at
    )
    |> declare_constraints()
  end

  @doc """
  Whether this request has an outcome — accepted or declined.

  Deliberately silent about `superseded_at`, and that is not an oversight.
  `HospitalityComs.Peers.request_connection/2` asks this of a row it superseded
  in the *same statement* it read the row with, so the struct in its hand
  already carries a `superseded_at` this write has just put there; a predicate
  that looked at the column would answer about the write rather than about the
  outcome. Whether the row was the pair's current one is decided by the query
  that returned it, which is where it belongs.

  Silent about visibility too — an addressee may always decline, whether or not
  the pair can still see each other.
  """
  @spec answered?(t()) :: boolean()
  def answered?(%__MODULE__{accepted_at: nil, declined_at: nil}), do: false
  def answered?(%__MODULE__{}), do: true

  @doc """
  What state this request is in, given whether the pair is visible right now.

  The boolean is supplied rather than looked up, so that "visible" is decided
  once by the query that loaded the row and not a second time here.
  """
  @spec state(t(), boolean()) :: state()
  def state(%__MODULE__{accepted_at: %DateTime{}}, _visible?), do: :accepted
  def state(%__MODULE__{declined_at: %DateTime{}}, _visible?), do: :declined
  def state(%__MODULE__{}, true), do: :pending
  def state(%__MODULE__{}, false), do: :lapsed

  @doc """
  This request with its derived state attached.
  """
  @spec with_state(t(), boolean()) :: t()
  def with_state(%__MODULE__{} = request, visible?) when is_boolean(visible?) do
    %{request | state: state(request, visible?)}
  end

  @doc """
  The party to this request who is not `person_id`.

  Raises `FunctionClauseError` for anybody who is not a party, which is what a
  caller that resolved the request from the wrong side deserves.
  """
  @spec counterpart(t(), Ecto.UUID.t()) :: Ecto.UUID.t()
  def counterpart(%__MODULE__{requester_id: person_id, addressee_id: other}, person_id), do: other
  def counterpart(%__MODULE__{addressee_id: person_id, requester_id: other}, person_id), do: other

  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> unique_constraint([:pair_low_id, :pair_high_id],
      name: @current_constraint,
      message: "a request between these two is already outstanding"
    )
    |> check_constraint(:addressee_id,
      name: :connection_requests_two_people,
      message: "cannot be the requester"
    )
    |> foreign_key_constraint(:requester_id)
    |> foreign_key_constraint(:addressee_id)
    |> foreign_key_constraint(:blocked_initiator_id)
  end
end
