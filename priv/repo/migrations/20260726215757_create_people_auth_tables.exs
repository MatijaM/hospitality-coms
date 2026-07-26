defmodule HospitalityComs.Repo.Migrations.CreatePeopleAuthTables do
  @moduledoc """
  The person zone's root table and the token table authentication runs on.

  Three departures from what `mix phx.gen.auth` generates, all of them there so
  that erasure is possible later rather than retrofitted (KTD15).

  Erasure pseudonymises the person row in place: it never deletes it, because
  every referencing table would then have to choose between destroying data the
  design commits to keeping and dropping an engagement out of overlap
  enforcement. So `email` becomes null on erasure, which the generated schema
  forbids twice over — once with `NOT NULL`, and once with a plain unique index
  that a second erased row would collide with on `NULL`... except that Postgres
  does not treat nulls as equal, so the collision is on the *generated* shape's
  `NOT NULL` alone. Both are replaced:

    * `email` is nullable, and a partial unique index scoped to `erased_at IS
      NULL` keeps live addresses unique while leaving erased rows out of the
      index entirely;
    * `people_erased_email_removed` makes the erasure irreversible at the schema
      level — an erased row cannot carry an address;
    * `people_present_email_required` puts back the guarantee `NOT NULL` used to
      give, so dropping it does not quietly admit live people with no address.

  `citext` gives case-insensitive addresses, which is the property an email
  identity wants and which a `lower()` index would only approximate.
  """

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    create table(:people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext
      add :confirmed_at, :utc_datetime
      add :erased_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:people, [:email], where: "erased_at IS NULL", name: :people_email_index)

    create constraint(:people, :people_erased_email_removed,
             check: "erased_at IS NULL OR email IS NULL"
           )

    create constraint(:people, :people_present_email_required,
             check: "erased_at IS NOT NULL OR email IS NOT NULL"
           )

    create table(:people_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:people_tokens, [:person_id])
    create unique_index(:people_tokens, [:context, :token])
  end

  def down do
    drop table(:people_tokens)

    drop constraint(:people, :people_present_email_required)
    drop constraint(:people, :people_erased_email_removed)
    drop index(:people, [:email], name: :people_email_index)

    drop table(:people)

    execute("DROP EXTENSION IF EXISTS citext")
  end
end
