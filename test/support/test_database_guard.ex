defmodule HospitalityComs.TestDatabaseGuard do
  @moduledoc """
  Clears leftover rows once, before the first test runs, and says what it found.

  ## The failure this exists to stop

  Ten test files in this tree are not sandboxed. `HospitalityComs.Engagements`'s
  claim spans both repos' connections and under the sandbox those are two
  transactions that cannot see each other's rows, so
  `HospitalityComs.EngagementsFixtures` checks out real connections, commits,
  and removes its rows with `purge/0` before and after each test.

  A run that dies between those two points — a Ctrl-C, an editor cancelling
  `mix test`, a VM that goes down with a test half finished — leaves committed
  rows behind. Three separate things then go wrong, and none of them looks like
  what it is:

    * **The purge cannot always heal it.** `purge/0` is one transaction. A row
      it does not know about that references a row it does delete makes the
      whole statement raise `foreign_key_violation` and roll back, so the run
      leaves the database exactly as dirty as it found it and every subsequent
      run fails the same way. Measured against a `correction_requests` row
      written by a branch this one does not carry the migration for.

    * **Some residue is unreachable by construction.** The purge removes
      `oban_jobs` by the venues their args name, and it does that before it
      removes the venues. A job whose venue has already gone — because somebody
      cleared `venues` by hand to unstick the suite — matches nothing, for
      ever, and breaks the single-row assertions in
      `HospitalityComs.Workers.EngagementSweeperTest`.

    * **Sandboxed tests see it too.** A sandbox transaction reads committed
      rows like any other. `Repo.aggregate(Person, :count) == 0` in
      `HospitalityComs.AccountsDeliveryTest` fails on a person nobody in that
      file ever wrote, which is how a hand-made `psql` probe account produces
      failures in files that touch no fixture at all.

  Together those produce roughly 150 errors across nineteen modules that read
  precisely like a regression in whatever was last committed. Two reviewers
  lost an afternoon each to it before bisecting to a `DELETE`.

  ## Why it cleans rather than refuses

  The correct contents of this database before the first test are *empty*:
  `priv/repo/seeds.exs` writes nothing, `mix test` creates and migrates it, and
  no fixture in the tree is meant to outlive its own test. So a row here is
  residue by construction and there is nothing to weigh up — refusing to run
  and printing instructions would make every developer paste the same `DELETE`
  the guard could have issued.

  What is worth weighing up is *silence*. Clearing rows without saying so would
  hide a genuine leak — a fixture that stopped purging, a new table nobody
  added to `purge/0` — behind a suite that goes green anyway. So the guard is
  loud in proportion to how surprising the residue is, and it separates the
  three cases above rather than reporting a single number.

  ## How it decides what is what

  The table list comes from `pg_class` rather than from
  `HospitalityComs.Zones`, and that is deliberate: a table created by a
  migration with no schema module is invisible to the zones and just as capable
  of holding a row, and a branch switch can leave this database carrying tables
  this checkout has never heard of. Asking the database what it contains is the
  only list that cannot drift.

  The classification is then a consequence of running the fixtures' own purge
  rather than a second opinion about it:

    * whatever `EngagementsFixtures.purge/0` removes is fixture residue, which
      is the ordinary case and reported quietly;
    * whatever survives it in `oban_jobs` or `oban_peers` is queue residue, the
      unreachable case above;
    * whatever else survives it was written by nothing in this tree, and is
      reported loudly, because that is either a hand-made probe or a fixture
      that has stopped cleaning up after itself.

  Reusing the purge is what keeps the foreign-key ordering — and the
  `ON DELETE RESTRICT` chain through `employer_grants` it encodes — in one
  place. The fallback for what the purge cannot reach is a single
  `TRUNCATE ... CASCADE` over every table at once, which needs no ordering at
  all and therefore cannot deadlock against itself; the identifiers are quoted
  by Postgres's own `format('%I')` rather than interpolated here.

  ## Cost on the ordinary path

  One round trip. The survey is a single statement, and on an empty database
  every `count(*)` in it reads zero pages; if it comes back all zeroes the
  guard returns without a second query and without printing anything. That
  matters because it runs on every `mix test`, including a one-file run.
  """

  alias HospitalityComs.EngagementsFixtures
  alias HospitalityComs.Repo

  @typedoc "A table holding rows it should not, and how many."
  @type residue() :: {table :: String.t(), rows :: pos_integer()}

  @typedoc "Whether the fixtures' own purge ran to completion."
  @type purge_outcome() :: :purged | {:failed, String.t()}

  # Oban's two tables belong to the library rather than to any zone —
  # `HospitalityComs.BoundaryTest` excludes them from its sweep for the same
  # reason. `purge/0` reaches `oban_jobs` only through the venues a job's args
  # name, so once those venues are gone the rows are unreachable rather than
  # unowned, and the report says so.
  @queue_tables ~w(oban_jobs oban_peers)

  # Ecto's own bookkeeping. Truncating it would silently un-migrate the
  # database, and `mix test`'s `ecto.migrate --quiet` would then re-run every
  # migration against tables that already exist.
  @not_application_data ~w(schema_migrations)

  @doc """
  Surveys the database, clears anything in it, and reports what it cleared.

  Returns `:ok` on a database that was already empty, having issued one query
  and printed nothing. Raises if residue survives the clear, so the guard
  cannot report a success it did not achieve.
  """
  @spec sweep() :: :ok
  def sweep, do: sweep(occupancy())

  @spec sweep([residue()]) :: :ok
  defp sweep([]), do: :ok

  defp sweep(found) do
    outcome = purge()
    survived = occupancy()

    truncate(survived)

    remaining = occupancy()
    IO.puts(:stderr, report(found, survived, remaining, outcome))
    cleared(remaining)
  end

  @spec cleared([residue()]) :: :ok
  defp cleared([]), do: :ok

  defp cleared(remaining) do
    raise """
    #{__MODULE__} could not empty the test database.

    Still holding rows after both the fixtures' purge and a TRUNCATE:
    #{inspect(remaining)}

    Something is writing to this database while the suite starts — another
    `mix test` on the same cluster is the usual answer.
    """
  end

  # The fixtures' purge is the tree's own statement of the foreign-key order,
  # so it runs first and is not reimplemented here. It is also the thing most
  # likely to raise on residue it was never written for — that is the failure
  # the moduledoc opens with — and a guard that gave up there would leave the
  # database exactly as it found it. The rescue is deliberately unqualified:
  # what the purge can raise on an unknown row is not a list anybody can close.
  @spec purge() :: purge_outcome()
  defp purge do
    EngagementsFixtures.purge()
    :purged
  rescue
    error -> {:failed, Exception.message(error)}
  end

  # Every base table in `public` and how many rows it holds, in one statement.
  #
  # `query_to_xml` is what makes it one statement: a table name cannot be a
  # query parameter, so counting a list of tables discovered at runtime is
  # otherwise a round trip each or an interpolated string. Here Postgres builds
  # each `count(*)` itself, through `format('%I')`, and nothing is spliced from
  # Elixir.
  #
  # Partition children are excluded because counting the parent already covers
  # them, and truncating the parent already clears them.
  @spec occupancy() :: [residue()]
  defp occupancy do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT t.relname, (xpath('/row/n/text()', t.counted))[1]::text::bigint
        FROM (
          SELECT c.relname,
                 query_to_xml(
                   format('SELECT count(*) AS n FROM %I.%I', n.nspname, c.relname),
                   false, true, ''
                 ) AS counted
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public'
            AND c.relkind IN ('r', 'p')
            AND NOT c.relispartition
            AND NOT c.relname = ANY($1::text[])
        ) t
        WHERE (xpath('/row/n/text()', t.counted))[1]::text::bigint > 0
        ORDER BY t.relname
        """,
        [@not_application_data]
      )

    Enum.map(rows, fn [table, count] -> {table, count} end)
  end

  # Every base table in `public`, empty or not. Only the clearing path asks for
  # it: the survey answers the ordinary question in one round trip and this is
  # a second one nobody pays for on a clean database.
  @spec application_tables() :: [String.t()]
  defp application_tables do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND NOT c.relname = ANY($1::text[])
        """,
        [@not_application_data]
      )

    Enum.map(rows, &hd/1)
  end

  # One statement over every table at once rather than over the survivors, so
  # there is no order to get wrong, no second lock to wait on, and nothing to
  # reason about when `CASCADE` reaches a table the survivors did not name.
  # Skipped entirely when the fixtures' purge already emptied the database.
  @spec truncate([residue()]) :: :ok
  defp truncate([]), do: :ok
  defp truncate(_survived), do: truncate_all(application_tables())

  @spec truncate_all([String.t()]) :: :ok
  defp truncate_all(tables) do
    %{rows: [[statement]]} =
      Repo.query!(
        """
        SELECT format(
          'TRUNCATE TABLE %s RESTART IDENTITY CASCADE',
          string_agg(format('%I', name), ', ' ORDER BY name)
        )
        FROM unnest($1::text[]) AS t(name)
        """,
        [tables]
      )

    Repo.query!(statement, [])
    :ok
  end

  @spec report([residue()], [residue()], [residue()], purge_outcome()) :: String.t()
  defp report(found, survived, remaining, outcome) do
    {queue, unowned} = Enum.split_with(survived, fn {table, _rows} -> table in @queue_tables end)

    [
      "\n" <> String.duplicate("=", 78),
      "LEFTOVER TEST DATA CLEARED BEFORE THE FIRST TEST RAN",
      "",
      """
      Nothing seeds this database, so every row below is residue from a run \
      that did not finish. It is not this run's doing, and the failures it \
      would have caused are not a regression in whatever you last changed.\
      """,
      "",
      section("found", found),
      purge_note(outcome),
      section("cleared by the fixtures' purge", cleared_by_purge(found, survived)),
      section("queue residue", queue),
      note(queue, "jobs outliving the venues their args name, which the purge cannot reach"),
      section("BEYOND THE FIXTURES' PURGE", unowned),
      note(unowned, "reached by nothing in this tree: a hand-made probe, a fixture"),
      note(unowned, "that stopped cleaning up, or — above — a purge that raised"),
      note(unowned, "before it got there. Worth a look before you dismiss this."),
      section("STILL PRESENT", remaining),
      String.duplicate("=", 78) <> "\n"
    ]
    |> Enum.reject(&(&1 == :skip))
    |> Enum.join("\n")
  end

  @spec cleared_by_purge([residue()], [residue()]) :: [residue()]
  defp cleared_by_purge(found, survived) do
    remaining = Map.new(survived)

    found
    |> Enum.map(fn {table, rows} -> {table, rows - Map.get(remaining, table, 0)} end)
    |> Enum.filter(fn {_table, rows} -> rows > 0 end)
  end

  @spec section(String.t(), [residue()]) :: String.t() | :skip
  defp section(_label, []), do: :skip

  defp section(label, residue) do
    "  #{String.pad_trailing(label, 32)}#{Enum.map_join(residue, ", ", &tally/1)}"
  end

  @spec tally(residue()) :: String.t()
  defp tally({table, rows}), do: "#{table} #{rows}"

  @spec note([residue()], String.t()) :: String.t() | :skip
  defp note([], _text), do: :skip
  defp note(_residue, text), do: "  #{String.duplicate(" ", 32)}#{text}"

  # The first line only. A `Postgrex.Error` message carries the constraint, the
  # table and the offending key across a dozen lines, and none of it says
  # anything the reader of a banner needs: what matters is that the tree's own
  # cleanup could not run, which is why the section below it is so long.
  @spec purge_note(purge_outcome()) :: String.t() | :skip
  defp purge_note(:purged), do: :skip

  defp purge_note({:failed, message}) do
    [first | _rest] = String.split(message, "\n")
    "  #{String.pad_trailing("the purge itself raised", 32)}#{first}"
  end
end
