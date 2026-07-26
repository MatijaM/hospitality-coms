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
  A person changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email. Defaults to `true`.
  """
  @spec email_changeset(t(), map(), keyword()) :: Ecto.Changeset.t(t())
  def email_changeset(person, attrs, opts \\ []) do
    person
    |> cast(attrs, [:email])
    |> validate_email(opts)
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
    change(person, confirmed_at: DateTime.truncate(now, :second))
  end
end
