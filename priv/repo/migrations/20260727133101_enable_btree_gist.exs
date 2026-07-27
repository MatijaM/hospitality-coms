defmodule HospitalityComs.Repo.Migrations.EnableBtreeGist do
  @moduledoc """
  `btree_gist`, in its own migration and ahead of the table that needs it.

  The overlap rule in R3 — a person may not hold two overlapping engagements at
  one venue — is enforced by an exclusion constraint, and an exclusion
  constraint is a GiST index. GiST knows how to compare `tstzrange` with `&&`
  out of the box and knows nothing about comparing `uuid` with `=`, which is
  what the other two columns of the key need. `btree_gist` is the extension that
  teaches it; without it the constraint fails to create with
  `data type uuid has no default operator class for access method "gist"`.

  ## Why it is not in the same migration as the table

  The plan asks for the extension in its own earlier migration, and the reason
  is worth having next to it: `CREATE EXTENSION` and the first use of the
  operator classes it installs are separated so that a database which cannot
  host the extension fails here, on a migration that does one thing, rather than
  part-way through creating the schema's central table.

  ## The rollback is not CASCADE

  `DROP EXTENSION` plain, so rolling this back while the exclusion constraint
  still exists fails loudly rather than silently taking the constraint — and
  with it the overlap rule — away. Ecto rolls migrations back in reverse, so the
  ordinary path drops the constraint first; the path that does not is an
  out-of-order rollback, which is exactly when a loud failure is worth having.
  `grant_zones` made the same choice about `app_current_employer_id()`.

  ## And it only drops what it created

  `up` is `IF NOT EXISTS`, so on a database that already had `btree_gist` — for
  an index this application knows nothing about — it does nothing. A `down` that
  dropped unconditionally would then remove an extension somebody else installed
  and break whatever was using it, which is a rollback with a blast radius
  outside its own schema.

  So `up` records provenance: it creates the extension only when it is absent,
  and comments it in the same statement. `down` drops it only when that comment
  is there. An extension this migration found is left exactly as it found it,
  and `\\dx` says which case a given database is in.

  A comment rather than a table: `up` runs before this application owns anything
  it could write a row into, and a comment is a catalogue fact that travels with
  the object it describes and disappears with it.
  """

  use Ecto.Migration

  @extension "btree_gist"
  @marker "created by hospitality_coms; see priv/repo/migrations/*_enable_btree_gist.exs"

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = '#{@extension}') THEN
        CREATE EXTENSION #{@extension};
        COMMENT ON EXTENSION #{@extension} IS '#{@marker}';
      END IF;
    END $$
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_extension extension
        JOIN pg_description description ON description.objoid = extension.oid
        WHERE extension.extname = '#{@extension}'
          AND description.description = '#{@marker}'
      ) THEN
        DROP EXTENSION #{@extension};
      END IF;
    END $$
    """)
  end
end
