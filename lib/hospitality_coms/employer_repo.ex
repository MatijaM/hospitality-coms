defmodule HospitalityComs.EmployerRepo.UnscopedError do
  @moduledoc """
  Raised when an employer operation is issued outside
  `HospitalityComs.EmployerRepo.scoped_transaction/2`.

  Employer reads depend on transaction-local settings that the wrapper writes,
  so a read outside it is a read against a scope that is either absent or —
  worse, on a pooled connection — left over from somebody else's request. Both
  are refused here rather than allowed to resolve to something.
  """

  defexception [:message]

  @type t() :: %__MODULE__{message: String.t()}
end

defmodule HospitalityComs.EmployerRepo.ZoneViolationError do
  @moduledoc """
  Raised when an employer query names a person-zone table.

  Postgres would refuse the same statement for want of privilege, and that
  refusal is the guarantee. This exception exists because it arrives first and
  says something more useful: which table, and that the table is out of bounds
  by design rather than by a grant somebody forgot.
  """

  defexception [:message]

  @type t() :: %__MODULE__{message: String.t()}
end

defmodule HospitalityComs.EmployerRepo do
  @moduledoc """
  The employer zone's connection to the database, and the two guards in front
  of it.

  It addresses the same database as `HospitalityComs.Repo` and differs in one
  respect that matters: its connections run as the Postgres role
  `employer_role`, which holds no privilege on any person-zone table. That is
  the boundary — the only tier whose violation produces an error rather than a
  leak. The role is assumed on connection rather than logged in as, so there is
  no second credential to manage, and the repo is deliberately absent from
  `:ecto_repos` because migrations belong to `HospitalityComs.Repo` alone.

  What is here is everything above that tier, and none of it is the guarantee.

  ## The wrapper

  `scoped_transaction/2` opens a transaction and writes `app.employer_id` and
  `app.now` into it with `set_config(..., true)` — transaction-locally. The
  third argument is the whole point: a session-level setting outlives the
  transaction that wrote it and is still there when the connection goes back to
  the pool and is handed to the next request, which is a scope leak between
  employers rather than a stale variable.

  The instant is taken off the scope and never from `Clock.now/0`. A repo is
  not a unit of work; the instant was captured at the boundary that opened one,
  and reading it again here would let the view and the query it filters
  disagree about which side of a period boundary the request fell on (KTD5).

  ## The guards

  `default_options/1` refuses any operation issued outside the wrapper. The
  transaction-local settings would be absent or, on a reused connection, left
  over — so the choice is between failing closed and running against somebody
  else's scope. Only `:transaction` is exempt, because the wrapper has to be
  able to open one.

  `prepare_query/3` walks a query's sources — including subqueries, common
  table expressions, unions, and association joins, whose source the planner
  has not yet resolved when this runs — and refuses any that reaches a
  person-zone table.

  Neither is the boundary. Both live in the BEAM, and anything in the BEAM can
  be worked around by code that means to. They exist so that the ordinary way
  to get this wrong — a join added to a query three units from now — fails with
  a message naming the table, before Postgres answers with a message naming the
  connection's role.

  Writes go through `default_options/1` but not through `prepare_query/3`;
  Ecto has no hook on the insert path that sees a table. An
  `EmployerRepo.insert/2` of a person-zone struct inside the wrapper therefore
  reaches Postgres and is refused there. That is the guarantee doing its job,
  with none of the legibility.
  """

  use Ecto.Repo,
    otp_app: :hospitality_coms,
    adapter: Ecto.Adapters.Postgres

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.EmployerRepo.UnscopedError
  alias HospitalityComs.EmployerRepo.ZoneViolationError
  alias HospitalityComs.Zones

  @scope_key {__MODULE__, :scope}

  @doc """
  Runs `fun` inside a transaction carrying the scope's employer and instant.

  Both are written with `set_config(..., true)`, so they are gone when the
  transaction ends rather than when the connection is closed. Everything the
  employer-visible view filters on reads them from there.

  `fun` receives the scope, so the instant travels into the work rather than
  being fetched again inside it, and returns `{:ok, result}` or
  `{:error, reason}` — the `transact/1` contract the rest of the application
  writes transactions against, so that a failure is a value rather than a
  `rollback/1` somebody has to remember.
  """
  @spec scoped_transaction(
          EmployerScope.t(),
          (EmployerScope.t() -> {:ok, result} | {:error, reason})
        ) :: {:ok, result} | {:error, reason}
        when result: var, reason: var
  def scoped_transaction(%EmployerScope{} = scope, fun) when is_function(fun, 1) do
    transact(fn -> run_scoped(scope, fun) end)
  end

  @doc """
  The scope the current process is running under, if it is inside the wrapper.
  """
  @spec current_scope() :: EmployerScope.t() | nil
  def current_scope, do: Process.get(@scope_key)

  @doc false
  @impl true
  def default_options(:transaction), do: []

  def default_options(operation) do
    operation |> permitted?() |> allow_or_refuse(operation)
  end

  @doc false
  @impl true
  def prepare_query(_operation, query, opts) do
    query |> person_zone_reach() |> allow_or_refuse_query(query, opts)
  end

  ## The wrapper

  @spec run_scoped(
          EmployerScope.t(),
          (EmployerScope.t() -> {:ok, result} | {:error, reason})
        ) :: {:ok, result} | {:error, reason}
        when result: var, reason: var
  defp run_scoped(scope, fun) do
    outer = Process.get(@scope_key)
    write_settings(scope)
    Process.put(@scope_key, scope)

    try do
      fun.(scope)
    after
      restore_scope(outer)
    end
  end

  @spec write_settings(EmployerScope.t()) :: :ok
  defp write_settings(%EmployerScope{employer_id: employer_id, now: now}) do
    # Raw SQL on purpose: this runs before the scope is registered, and it must
    # not be refused by the guard it is on its way to satisfying.
    query!(
      "SELECT set_config('app.employer_id', $1, true), set_config('app.now', $2, true)",
      [employer_id, DateTime.to_iso8601(now)]
    )

    :ok
  end

  @spec restore_scope(EmployerScope.t() | nil) :: :ok
  defp restore_scope(nil) do
    Process.delete(@scope_key)
    :ok
  end

  defp restore_scope(%EmployerScope{} = outer) do
    Process.put(@scope_key, outer)
    :ok
  end

  ## The unscoped guard

  @spec permitted?(atom()) :: boolean()
  defp permitted?(_operation), do: match?(%EmployerScope{}, Process.get(@scope_key))

  @spec allow_or_refuse(boolean(), atom()) :: keyword()
  defp allow_or_refuse(true, _operation), do: []

  defp allow_or_refuse(false, operation) do
    raise UnscopedError,
      message: """
      #{inspect(__MODULE__)} was asked to #{operation} outside its transaction wrapper.

      Employer reads depend on app.employer_id and app.now, which are written \
      transaction-locally and are therefore absent here — or, on a connection \
      that has served an earlier request, left over from it. Run the work \
      inside EmployerRepo.scoped_transaction/2.
      """
  end

  ## The zone guard

  @spec allow_or_refuse_query([String.t()], Ecto.Query.t(), keyword()) ::
          {Ecto.Query.t(), keyword()}
  defp allow_or_refuse_query([], query, opts), do: {query, opts}

  defp allow_or_refuse_query(tables, _query, _opts) do
    raise ZoneViolationError,
      message: """
      An employer-scoped query reached the person zone: #{Enum.join(tables, ", ")}.

      Person-zone tables carry no employer key, so there is no filter that \
      would make this query correct. Postgres would refuse it for want of \
      privilege; this is the same refusal, arriving early enough to name the \
      table.
      """
  end

  # Every table the query can reach, filtered to the ones it must not.
  @spec person_zone_reach(Ecto.Query.t()) :: [String.t()]
  defp person_zone_reach(%Ecto.Query{} = query) do
    query
    |> sources()
    |> Enum.filter(&person_zone?/1)
    |> Enum.map(&table_name/1)
    |> Enum.uniq()
  end

  @spec person_zone?({String.t() | nil, module() | nil}) :: boolean()
  defp person_zone?({table, schema}) do
    Zones.person_zone_table?(table) or Zones.person_zone_schema?(schema)
  end

  @spec table_name({String.t() | nil, module() | nil}) :: String.t()
  defp table_name({table, _schema}) when is_binary(table), do: table
  defp table_name({nil, schema}), do: schema.__schema__(:source)

  ## Walking a query

  # `prepare_query/3` runs before the planner, so `query.sources` is not
  # populated and association joins have not been resolved. Both are worked out
  # here from the bindings in order, which is the order the planner will use.
  @spec sources(Ecto.Query.t()) :: [{String.t() | nil, module() | nil}]
  defp sources(%Ecto.Query{} = query) do
    bindings = resolve_bindings([query.from | query.joins])

    Enum.flat_map(bindings, &expand/1) ++
      Enum.flat_map(nested_queries(query), &sources/1)
  end

  @spec resolve_bindings([Ecto.Query.FromExpr.t() | Ecto.Query.JoinExpr.t()]) :: [term()]
  defp resolve_bindings(exprs) do
    Enum.reduce(exprs, [], fn expr, resolved -> resolved ++ [binding(expr, resolved)] end)
  end

  @spec binding(map(), [term()]) :: term()
  defp binding(%{source: nil, assoc: {index, field}}, resolved) do
    resolved |> Enum.at(index) |> association_source(field)
  end

  defp binding(%{source: source}, _resolved), do: source

  @spec association_source(term(), atom()) :: {nil, module()} | nil
  defp association_source({_table, schema}, field) when is_atom(schema) and not is_nil(schema) do
    {nil, schema.__schema__(:association, field).related}
  end

  defp association_source(_parent, _field), do: nil

  # A binding is a `{table, schema}` pair, a subquery to walk into, or something
  # opaque — a fragment source, an unresolvable association — that only Postgres
  # can adjudicate.
  @spec expand(term()) :: [{String.t() | nil, module() | nil}]
  defp expand({table, schema}) when (is_binary(table) or is_nil(table)) and is_atom(schema) do
    [{table, schema}]
  end

  defp expand(%Ecto.SubQuery{query: query}), do: sources(query)
  defp expand(_source), do: []

  @spec nested_queries(Ecto.Query.t()) :: [Ecto.Query.t()]
  defp nested_queries(%Ecto.Query{} = query) do
    Enum.filter(cte_queries(query) ++ combination_queries(query), &is_struct(&1, Ecto.Query))
  end

  @spec cte_queries(Ecto.Query.t()) :: [term()]
  defp cte_queries(%Ecto.Query{with_ctes: %Ecto.Query.WithExpr{queries: queries}}) do
    Enum.map(queries, fn {_name, _operation, query} -> query end)
  end

  defp cte_queries(%Ecto.Query{}), do: []

  @spec combination_queries(Ecto.Query.t()) :: [term()]
  defp combination_queries(%Ecto.Query{combinations: combinations}) do
    Enum.map(combinations, fn {_kind, query} -> query end)
  end
end
