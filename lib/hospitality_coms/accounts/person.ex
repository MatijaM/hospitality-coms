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

  alias HospitalityComs.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "people" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :erased_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps(type: :utc_datetime)
  end

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          email: String.t() | nil,
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
