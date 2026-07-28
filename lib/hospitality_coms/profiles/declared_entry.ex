defmodule HospitalityComs.Profiles.DeclaredEntry do
  @moduledoc """
  The worker's own statement about work this application knows nothing about.

  The other half of R16's taxonomy. An attested entry is an employer's assertion
  and the person cannot edit it — there is no write path to one outside the
  claim's transaction — and a declared entry is the person's, so they write it,
  amend it, and are the only one who can.

  ## It is person zone, and there is no engagement behind it

  That absence *is* the distinction. An attested entry is keyed on
  `engagements (id, venue_id)` because an employer asserted it and no
  employer-zone row may name a human (KTD2); a declared entry has no employer on
  either side of it, so it is keyed on `person_id` and carries no venue at all.

  ## It never reaches the employer-visible view, and that is deliberate

  The plan's zone diagram routes only `attested_entries` through
  `employer_visible_attested_entries`, and the line is the right one: the view
  carries what employers asserted, under a disclosure rule whose whole purpose
  is to stop one employer inferring another. A worker's own claim needs no
  database tier to be believed or doubted, and running it through the same
  concurrency default would be nonsense — there is no period at a venue to be
  concurrent with.

  A peer sees them, because publishing a declared entry is what writing one
  means. `HospitalityComs.Profiles.fetch_peer_profile/2` is where that is
  applied, and it is why the disclosure ledger governs attested entries alone:
  nothing needs a per-audience switch for a statement the author can amend or
  empty at will.

  ## The term is strictly ordered, unlike an engagement's

  `ends_at > starts_at`, in the changeset and in the database. An engagement
  permits `ends_at == starts_at` because `end_engagement/2` has to be able to
  close a term before it opened; a declared entry is never ended, only written,
  so the empty range has nothing to represent here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.Person

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "declared_entries" do
    field :role_label, :string
    field :organisation_name, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :declared_at, :utc_datetime

    belongs_to :person, Person

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          person_id: Ecto.UUID.t() | nil,
          person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          role_label: String.t() | nil,
          organisation_name: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          declared_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # The same bound `engagements.role_label` carries, so a declared entry and an
  # attested one render in the same width.
  @max_label_length 120

  @castable [:role_label, :organisation_name, :starts_at, :ends_at]

  @doc """
  The longest a label or an organisation name may be.
  """
  @spec max_label_length() :: pos_integer()
  def max_label_length, do: @max_label_length

  @doc """
  A new declared entry, authored by the person the scope names.

  `person_id` is put rather than cast: an entry belongs to whoever wrote it, and
  a caller that could choose the owner could write history into somebody else's
  record.
  """
  @spec declare_changeset(Ecto.UUID.t(), map(), DateTime.t()) :: Ecto.Changeset.t(t())
  def declare_changeset(person_id, attrs, %DateTime{} = now)
      when is_binary(person_id) and is_map(attrs) do
    stamped_at = DateTime.truncate(now, :second)

    %__MODULE__{}
    |> cast(attrs, @castable)
    |> put_change(:person_id, person_id)
    |> put_change(:declared_at, stamped_at)
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
    |> validate()
  end

  @doc """
  An amendment to a declared entry the person already wrote.

  `person_id` and `declared_at` are untouched: amending a statement is not
  re-declaring it, and moving the declaration instant would make an edit look
  like a fresh assertion.
  """
  @spec amend_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t(t())
  def amend_changeset(%__MODULE__{} = entry, attrs, %DateTime{} = now) when is_map(attrs) do
    entry
    |> cast(attrs, @castable)
    |> put_change(:updated_at, DateTime.truncate(now, :second))
    |> validate()
  end

  @spec validate(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp validate(changeset) do
    changeset
    |> validate_required(@castable)
    |> update_change(:role_label, &String.trim/1)
    |> update_change(:organisation_name, &String.trim/1)
    |> validate_required([:role_label, :organisation_name])
    |> validate_length(:role_label, max: @max_label_length)
    |> validate_length(:organisation_name, max: @max_label_length)
    |> truncate(:starts_at)
    |> truncate(:ends_at)
    |> validate_term()
    |> declare_constraints()
  end

  # The changeset half of every check constraint the table carries, so a caller
  # gets a field error rather than a raised `Postgrex.Error`, and the constraint
  # half so that a write which never passed through here cannot get around it.
  @spec declare_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_constraints(changeset) do
    changeset
    |> check_constraint(:ends_at,
      name: :declared_entries_term_ordered,
      message: "must be after the start"
    )
    |> check_constraint(:role_label,
      name: :declared_entries_role_label_present,
      message: "can't be blank"
    )
    |> check_constraint(:role_label,
      name: :declared_entries_role_label_within_bound,
      message: "should be at most #{@max_label_length} character(s)"
    )
    |> check_constraint(:organisation_name,
      name: :declared_entries_organisation_present,
      message: "can't be blank"
    )
    |> check_constraint(:organisation_name,
      name: :declared_entries_organisation_within_bound,
      message: "should be at most #{@max_label_length} character(s)"
    )
    |> foreign_key_constraint(:person_id)
  end

  @spec validate_term(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp validate_term(changeset) do
    changeset
    |> get_field(:starts_at)
    |> ordered?(get_field(changeset, :ends_at))
    |> refuse_term(changeset)
  end

  @spec ordered?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  defp ordered?(%DateTime{} = starts_at, %DateTime{} = ends_at) do
    DateTime.compare(ends_at, starts_at) == :gt
  end

  defp ordered?(_starts_at, _ends_at), do: true

  @spec refuse_term(boolean(), Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp refuse_term(true, changeset), do: changeset

  defp refuse_term(false, changeset),
    do: add_error(changeset, :ends_at, "must be after the start")

  # Every instant column in this schema is second-precision, matching the rest
  # of the application. Truncating in the changeset rather than at the database
  # means a test comparing what it wrote against what it reads back gets the
  # same value.
  @spec truncate(Ecto.Changeset.t(t()), atom()) :: Ecto.Changeset.t(t())
  defp truncate(changeset, field) do
    changeset |> get_change(field) |> truncated(changeset, field)
  end

  @spec truncated(DateTime.t() | nil, Ecto.Changeset.t(t()), atom()) :: Ecto.Changeset.t(t())
  defp truncated(%DateTime{} = instant, changeset, field) do
    put_change(changeset, field, DateTime.truncate(instant, :second))
  end

  defp truncated(_instant, changeset, _field), do: changeset
end
