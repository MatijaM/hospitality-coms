defmodule HospitalityComs.Accounts.Person do
  @moduledoc """
  A person, and the only table in the application that names a human.

  A person row is created by the person and by nobody else (R1). There is no
  employer key here and there never will be — `engagements.person_id` is the
  single bridge across the zone boundary (KTD2), so an employer reaches a
  person only by way of an engagement they already hold.

  Two fields carry the lifecycle. `confirmed_at` is set the first time a magic
  link is redeemed. `erased_at` is set by erasure, which nulls `email` in the
  same write; the pair is held together by database check constraints rather
  than by this changeset, because erasure is a lifecycle-context operation
  (KTD21) and the guarantee has to survive being reached from there.

  ## `display_name`, and the disclosure it makes legible

  The one readable thing about a human this schema holds (#66). It is *given*
  at registration from `HospitalityComs.Accounts.DisplayName` and the person may
  change it; it is not asked for, because a worker who has just followed a magic
  link has supplied one fact about themselves and is owed a way to be recognised
  without supplying a second.

  It reaches **no employer**. `people` is person zone, `employer_role` holds
  nothing on it, `HospitalityComs.BoundaryTest`'s sweep asks about column grants
  as well as table grants, and no employer-facing render carries it.

  **It is a globally stable readable key, and one consequence is new.**
  `room_messages.author_engagement_id` is venue-local by construction (KTD15b),
  and a rendered message now carries a name beside it that is the same string at
  every venue — so a worker engaged at two venues, reading both venue rooms, can
  tell from the *messages alone* that the same human speaks in both. That
  capability already existed by another route:
  `HospitalityComs.Rooms.list_venue_room_members/2` hands every member the
  `person_id` of every other member, which `CLAUDE.md` records as a live
  disclosure. What changed is that it no longer needs a join. Recorded rather
  than closed, because closing it means a per-venue name, which is a KTD2-level
  decision about the single bridge rather than a rendering one.

  **Erasure overwrites it** with `HospitalityComs.Lifecycle.erased_display_name/0`,
  in the same statement that nulls the address — a readable name left behind is
  an identifying value surviving erasure, which is KTD15 broken outright.

  It carries **no check constraint pairing it with `erased_at`**, unlike
  `email`, and that is a decision rather than an omission. Three reasons:

    * `people_erased_email_removed` and `people_present_email_required` exist to
      keep `people_email_index` — partial on `WHERE erased_at IS NULL` —
      coherent, since an erased row that kept its address would go on occupying
      it. This column has no unique index and no such coupling;
    * `engagements.role_label` is the tree's existing case of erasure
      overwriting text with a constant, and it is guarded by
      `HospitalityComs.LifecycleTest`'s whole-row comparison rather than by a
      CHECK;
    * a CHECK here would have to pin a *value* — `erased_at IS NULL OR
      display_name = 'Former colleague'` — which puts a UI string in a migration
      (issue #42's defect class) to buy a guarantee `NOT NULL` plus that
      comparison already provides.

  What the column does carry is `people_display_name_present` and
  `people_display_name_within_bound`, because the erasure write is an
  `update_all` and meets no changeset at all.

  Authentication is magic-link only. The generator's password column and
  changeset were removed rather than left unreachable: no route can set a
  password once the HTML layer is gone, and an unreachable credential path in
  an auth module is a liability, not an option.

  Every changeset here takes the unit of work's instant and stamps
  `inserted_at` and `updated_at` from it (KTD5). Ecto's `timestamps()`
  autogenerate would otherwise call `DateTime.utc_now/0` from inside Ecto,
  which is beyond the reach of both the clock and the check that guards it —
  so `people` would ignore the injected instant while `people_tokens`, which
  stamps explicitly, honoured it. Two tables disagreeing about when the same
  request happened is not a rounding error; it is the thing the single-instant
  rule exists to prevent.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HospitalityComs.Accounts.DisplayName
  alias HospitalityComs.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "people" do
    field :email, :string
    field :display_name, :string
    field :confirmed_at, :utc_datetime
    field :erased_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
          display_name: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          erased_at: DateTime.t() | nil,
          authenticated_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  A person changeset for registering or changing the email, stamped from `now`.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email. Defaults to `true`.
  """
  @spec email_changeset(t(), map(), DateTime.t(), keyword()) :: Ecto.Changeset.t(t())
  def email_changeset(person, attrs, %DateTime{} = now, opts \\ []) do
    person
    |> cast(attrs, [:email])
    |> validate_email(opts)
    |> stamp(now)
  end

  @doc """
  A person changeset for registering, which is `email_changeset/4` plus a name.

  The name is **given**, not cast: there is no attribute that would supply one,
  so a caller cannot register somebody as anybody. Every path that makes a
  person goes through `HospitalityComs.Accounts.register_person/2`, so the
  fixtures and `HospitalityComs.Demo.seed/0` get one without knowing about it.

  A supplied `display_name` in `attrs` is ignored rather than refused, for the
  reason `email_changeset/4` casts exactly one field: what is not cast cannot
  be set, and a registration door that accepted a chosen name would be the first
  place this application asked a stranger for one.
  """
  @spec registration_changeset(t(), map(), DateTime.t(), keyword()) :: Ecto.Changeset.t(t())
  def registration_changeset(person, attrs, %DateTime{} = now, opts \\ []) do
    person
    |> email_changeset(attrs, now, opts)
    |> put_change(:display_name, DisplayName.generate())
    |> declare_display_name_constraints()
  end

  @doc """
  A person changeset for the name they chose instead of the one they were given.

  Trimmed before it is required, so `"   "` is blank rather than three
  characters. The bound is `HospitalityComs.Accounts.DisplayName.max_length/0`
  and the database carries the same number; neither is the other's backstop —
  the CHECK exists because the erasure write is an `update_all` and reaches no
  changeset.
  """
  @spec display_name_changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t(t())
  def display_name_changeset(person, attrs, %DateTime{} = now) do
    person
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &trimmed/1)
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: DisplayName.max_length())
    |> declare_display_name_constraints()
    |> stamp(now)
  end

  # Ecto's `cast/3` already treats a whitespace-only string as an empty value
  # and puts `nil` in the change, so the trim below is reached with a nil for
  # exactly the input it exists to catch. Two clauses rather than a `String.trim/1`
  # capture, which raises there — and `validate_required/2` is what then answers.
  @spec trimmed(String.t() | nil) :: String.t() | nil
  defp trimmed(name) when is_binary(name), do: String.trim(name)
  defp trimmed(name), do: name

  @spec declare_display_name_constraints(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp declare_display_name_constraints(changeset) do
    changeset
    |> check_constraint(:display_name,
      name: :people_display_name_present,
      message: "can't be blank"
    )
    |> check_constraint(:display_name,
      name: :people_display_name_within_bound,
      message: "should be at most #{DisplayName.max_length()} character(s)"
    )
  end

  @spec validate_email(Ecto.Changeset.t(t()), keyword()) :: Ecto.Changeset.t(t())
  defp validate_email(changeset, opts) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> maybe_validate_unique(Keyword.get(opts, :validate_unique, true))
  end

  @spec maybe_validate_unique(Ecto.Changeset.t(t()), boolean()) :: Ecto.Changeset.t(t())
  defp maybe_validate_unique(changeset, false), do: changeset

  defp maybe_validate_unique(changeset, true) do
    changeset
    |> unsafe_validate_unique(:email, Repo)
    |> unique_constraint(:email)
    |> validate_email_changed()
  end

  @spec validate_email_changed(Ecto.Changeset.t(t())) :: Ecto.Changeset.t(t())
  defp validate_email_changed(changeset) do
    email_changed?(changeset, get_field(changeset, :email), get_change(changeset, :email))
  end

  @spec email_changed?(Ecto.Changeset.t(t()), String.t() | nil, String.t() | nil) ::
          Ecto.Changeset.t(t())
  defp email_changed?(changeset, email, nil) when is_binary(email) do
    add_error(changeset, :email, "did not change")
  end

  defp email_changed?(changeset, _email, _change), do: changeset

  @doc """
  Confirms the account by setting `confirmed_at` to the unit of work's instant.
  """
  @spec confirm_changeset(t(), DateTime.t()) :: Ecto.Changeset.t(t())
  def confirm_changeset(person, %DateTime{} = now) do
    person
    |> change(confirmed_at: DateTime.truncate(now, :second))
    |> stamp(now)
  end

  # A row that has never been inserted gets both stamps; one that has keeps the
  # `inserted_at` it was born with.
  @spec stamp(Ecto.Changeset.t(t()), DateTime.t()) :: Ecto.Changeset.t(t())
  defp stamp(%Ecto.Changeset{data: %__MODULE__{inserted_at: nil}} = changeset, now) do
    stamped_at = DateTime.truncate(now, :second)

    changeset
    |> put_change(:inserted_at, stamped_at)
    |> put_change(:updated_at, stamped_at)
  end

  defp stamp(changeset, now) do
    put_change(changeset, :updated_at, DateTime.truncate(now, :second))
  end
end
