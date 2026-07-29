defmodule HospitalityComs.Repo.Migrations.WidenDeclaredEntryLabels do
  @moduledoc """
  Two check constraints widened from 120 to 160, and nothing else.

  Issue #42's item 1, and the one instance in that sweep that had already gone
  wrong. `HospitalityComs.Profiles.DeclaredEntry` and `*_create_profiles.exs`
  both said

      # The same bound `engagements.role_label` carries, so a declared entry and
      # an attested one render in the same width.
      @max_label_length 120

  and `engagements.role_label` carries **160**, as `invitations.role_label` does
  and as `HospitalityComs.Engagements.Invitation.max_label_length/0` declares.
  The sentence was the specification, the number beside it was a copy nobody
  could check, and it drifted. The product call is 160, so the bound moves to
  meet the sentence rather than the sentence moving to meet the bound.

  `organisation_name` moves with `role_label` because one module attribute
  governs both validations and always has; splitting them would be a second
  declaration bought to avoid a one-line migration.

  ## Nothing here grants, and nothing here is classified

  `declared_entries` is person zone and already is. `employer_role` holds
  nothing on it, this migration creates no relation, and `PostgresRolesTest`'s
  unwind list is "every *grant* migration" — this is not one.

  ## `up` is safe on stored rows; `down` is not, and that is stated rather than hidden

  Widening a `CHECK` cannot fail: every string valid at 120 is valid at 160, and
  Postgres validates the new constraint against the existing rows and finds them
  all compliant.

  **`down` narrows, and Postgres validates that too.** A `declared_entries` row
  holding a label or an organisation name longer than 120 characters makes the
  rollback fail with `check_violation`, naming the constraint. There is no
  narrowing rollback without that property — the alternatives are to silently
  truncate stored user-authored text, or to add the constraint `NOT VALID`,
  which produces a constraint that does not hold and reports success. A rollback
  that stops and says what is in the way is the better failure.

  It cannot fire on this tree: a label longer than 120 is only writable *after*
  this migration, so a database that has never run it holds no such row, and one
  rolling it back has to have written one in between.
  """

  use Ecto.Migration

  # The bound `engagements.role_label` and `invitations.role_label` carry, which
  # is what `HospitalityComs.Engagements.Invitation.max_label_length/0` now
  # answers for `DeclaredEntry` too. Restated here as a literal rather than read
  # from that module: a migration must replay to the schema it originally
  # produced, and a value that moves with `lib/` cannot. Issue #42's own rule —
  # the agreement between the two is a test's job, and
  # `test/hospitality_coms/constant_agreement_test.exs` is where it is done.
  @max_label_length 160

  # What `*_create_profiles.exs` wrote, and what `down` has to restore for the
  # schema to be the one that migration produced.
  @previous_label_length 120

  @role_label :declared_entries_role_label_within_bound
  @organisation :declared_entries_organisation_within_bound

  def up do
    rebound(@role_label, "role_label", @max_label_length)
    rebound(@organisation, "organisation_name", @max_label_length)
  end

  def down do
    rebound(@role_label, "role_label", @previous_label_length)
    rebound(@organisation, "organisation_name", @previous_label_length)
  end

  # Drop and recreate rather than `ALTER CONSTRAINT`, which Postgres accepts for
  # a foreign key's deferrability and nothing else — a `CHECK`'s expression is
  # immutable once created. Both statements run inside the migration's
  # transaction, so the column is never briefly unbounded to another session.
  defp rebound(name, column, bound) do
    drop(constraint(:declared_entries, name))
    create(constraint(:declared_entries, name, check: "length(#{column}) <= #{bound}"))
  end
end
