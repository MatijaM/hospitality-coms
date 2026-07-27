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
  """

  use Ecto.Migration

  def up, do: execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

  def down, do: execute("DROP EXTENSION btree_gist")
end
