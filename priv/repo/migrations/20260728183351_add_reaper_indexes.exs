defmodule HospitalityComs.Repo.Migrations.AddReaperIndexes do
  @moduledoc """
  Two indexes, and nothing else: issue #15's reapers are the first statements in
  the tree that ask either table how old a row is.

  **No table, no column and no grant.** `HospitalityComs.Lifecycle.reap/1`
  deletes from `people` and `people_tokens`, both of which already exist and are
  both person zone, and `employer_role` holds nothing on either — so there is no
  `Zones` classification to add, no entry for `PostgresRolesTest`'s unwind list
  (the rule there is "every *grant* migration" and this is not one), and no new
  relation for `boundary_test.exs`'s totality sweeps to reach.

  ## `people_tokens (context, inserted_at)`

  The token reap is a disjunction over the three contexts, each with its own
  horizon, plus a catch-all for a context nobody has written yet. Postgres can
  serve that as a bitmap OR over one index leading on `context`, which is what
  keeps an unattended statement over a table that only ever grew from being a
  sequential scan. `people_tokens` already carries `(person_id)` and a unique
  `(context, token)`; neither helps a query that filters on age.

  ## `people (inserted_at) WHERE confirmed_at IS NULL AND erased_at IS NULL`

  Partial, and the predicate is the reap's own two `IS NULL` clauses. That is
  what keeps it small: the rows it indexes are exactly the ones that are
  candidates for deletion, which on a healthy installation is a slice of the
  table rather than the table. A plain `(inserted_at)` index would carry every
  confirmed person in the system to answer a question about the ones who never
  confirmed.

  Rolling this back leaves the reap correct and slow, which is the right shape
  for an index migration: there is no data in either direction.
  """

  use Ecto.Migration

  def up do
    create index(:people_tokens, [:context, :inserted_at],
             name: :people_tokens_context_inserted_at_index
           )

    create index(:people, [:inserted_at],
             where: "confirmed_at IS NULL AND erased_at IS NULL",
             name: :people_unconfirmed_inserted_at_index
           )
  end

  def down do
    drop index(:people, [:inserted_at], name: :people_unconfirmed_inserted_at_index)

    drop index(:people_tokens, [:context, :inserted_at],
           name: :people_tokens_context_inserted_at_index
         )
  end
end
