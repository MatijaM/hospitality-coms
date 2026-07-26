defmodule HospitalityComs.Repo.Migrations.CreatePostgresRoles do
  @moduledoc """
  Creates the two Postgres roles the zone boundary is built on.

  This migration creates the roles and bounds how long the employer role may
  hold a connection. It grants nothing else: the zone grants and revocations
  that give the roles their asymmetry belong to a later migration, so the
  privilege story stays readable in one place.

  The timeouts are part of the time model, not housekeeping. A unit of work
  captures one instant and carries it for the length of a transaction, so an
  employer transaction that sits open indefinitely is one reading the database
  against an instant that has drifted arbitrarily far from now. These caps
  bound that drift.
  """

  use Ecto.Migration

  @roles ~w(employer_role person_role)

  @statement_timeout "5s"
  @idle_in_transaction_timeout "10s"

  def up do
    Enum.each(@roles, &create_role/1)

    execute("ALTER ROLE employer_role SET statement_timeout = '#{@statement_timeout}'")

    execute(
      "ALTER ROLE employer_role SET idle_in_transaction_session_timeout = '#{@idle_in_transaction_timeout}'"
    )

    # The application user assumes these roles with SET ROLE rather than
    # logging in as them, which requires membership.
    Enum.each(@roles, &execute("GRANT #{&1} TO CURRENT_USER"))
  end

  def down do
    Enum.each(@roles, &execute("REVOKE #{&1} FROM CURRENT_USER"))
    execute("ALTER ROLE employer_role RESET idle_in_transaction_session_timeout")
    execute("ALTER ROLE employer_role RESET statement_timeout")
    Enum.each(@roles, &execute("DROP ROLE IF EXISTS #{&1}"))
  end

  defp create_role(role) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN
        CREATE ROLE #{role} NOLOGIN;
      END IF;
    END
    $$
    """)
  end
end
