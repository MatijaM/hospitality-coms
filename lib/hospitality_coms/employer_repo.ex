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

defmodule HospitalityComs.EmployerRepo.NestedScopeError do
  @moduledoc """
  Raised when `HospitalityComs.EmployerRepo.scoped_transaction/2` is entered
  inside a transaction that already carries a *different* employer's scope.

  There is no savepoint between the two. `DBConnection.transaction/3` on a
  connection already in a transaction runs the inner function on that same
  transaction, so the inner `set_config(..., true)` overwrites `app.employer_id`
  and `app.now` for the whole of it and nothing puts them back when the inner
  call returns. The outer work would carry on believing it was scoped to the
  first employer while Postgres answered as the second — a cross-tenant read
  with no error anywhere.

  Restoring the settings on the way out is not an option either: the inner call
  may have returned because it raised, in which case the transaction is aborted
  and the restoring statement fails too, masking the original error with a
  second one. So the reentry is refused before either scope is written.
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

  Entering the wrapper again inside itself with a *different* employer raises
  `NestedScopeError`, because there is no savepoint between the two and the
  inner settings would stay in force after the inner call returned. Entering it
  again with an identical scope is a no-op that runs the work and writes
  nothing: the settings it would write are the ones already there.

  ## The guards

  `default_options/1` refuses any operation issued outside the wrapper. The
  transaction-local settings would be absent or, on a reused connection, left
  over — so the choice is between failing closed and running against somebody
  else's scope. Only `:transaction` is exempt, because the wrapper has to be
  able to open one.

  `prepare_query/3` walks a query's sources — including subqueries in every
  position Ecto parks them, common table expressions, unions, and association
  joins, whose source the planner has not yet resolved when this runs — and
  refuses any that reaches a person-zone table.

  Neither is the boundary. Both live in the BEAM, and anything in the BEAM can
  be worked around by code that means to. They exist so that the ordinary way
  to get this wrong — a join added to a query three units from now — fails with
  a message naming the table, before Postgres answers with a message naming the
  connection's role.

  ## What the guards do not see

  Three holes, pinned by tests in `HospitalityComs.BoundaryTest` rather than
  only described here, because a documented hole nobody asserts is a hole
  somebody closes by accident and reopens by accident.

  Writes go through `default_options/1` but not through `prepare_query/3`;
  Ecto has no hook on the insert path that sees a table. An
  `EmployerRepo.insert/2` of a person-zone struct inside the wrapper therefore
  reaches Postgres and is refused there. That is the guarantee doing its job,
  with none of the legibility.

  Raw SQL goes through neither. `query/3`, `query!/3`, `query_many/3` and
  `to_sql/3` are dispatched by Ecto straight to `Ecto.Adapters.SQL` without
  consulting `default_options/1`, so `EmployerRepo.query!("SELECT 1", [])`
  outside the wrapper runs. The exemption is load-bearing rather than
  accidental — `write_settings/1` is itself a raw query, issued before the
  scope is registered, so a `query/3` that went through the guard could never
  satisfy it — and closing it would mean closing the door the wrapper comes in
  through.

  Raw SQL is also how the role assumption is escapable. Connections log in as
  the application's own role and assume `employer_role` with `SET ROLE`, so a
  single `RESET ROLE` puts the login role back and with it every privilege the
  grants were withholding. The grant tier is therefore defeatable from the BEAM
  exactly as the two guards are; what the whole boundary is strong against is
  *accident* — a join, a forgotten filter, a context function called from the
  wrong zone — and not against a caller who means to get out. Closing it needs
  `EmployerRepo` to log in as a dedicated role of its own, which is an
  infrastructure decision rather than a code one and is filed separately.
  """

  use Ecto.Repo,
    otp_app: :hospitality_coms,
    adapter: Ecto.Adapters.Postgres

  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.EmployerRepo.NestedScopeError
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

  Raises `NestedScopeError` when a scope for a different employer is already in
  force on this process. Nesting an identical scope is allowed and writes
  nothing.
  """
  @spec scoped_transaction(
          EmployerScope.t(),
          (EmployerScope.t() -> {:ok, result} | {:error, reason})
        ) :: {:ok, result} | {:error, reason}
        when result: var, reason: var
  def scoped_transaction(%EmployerScope{} = scope, fun) when is_function(fun, 1) do
    scope
    |> reentry(Process.get(@scope_key))
    |> transact_scoped(scope, fun)
  end

  @typedoc "The operations Ecto invokes `c:Ecto.Repo.default_options/1` for."
  @type operation() ::
          :all
          | :delete
          | :delete_all
          | :insert
          | :insert_all
          | :insert_or_update
          | :preload
          | :reload
          | :stream
          | :transaction
          | :update
          | :update_all

  @doc false
  @impl true
  @spec default_options(operation()) :: keyword()
  def default_options(:transaction), do: []

  def default_options(operation) do
    operation |> scoped?() |> allow_or_refuse(operation)
  end

  @doc false
  @impl true
  @spec prepare_query(
          :all | :update_all | :delete_all | :stream | :insert_all,
          Ecto.Query.t(),
          keyword()
        ) ::
          {Ecto.Query.t(), keyword()}
  def prepare_query(_operation, query, opts) do
    query |> person_zone_reach() |> allow_or_refuse_query(query, opts)
  end

  ## The wrapper

  # Whether this call is the one that opens the scope, or one inside it.
  @typep entry() :: :outermost | :reentrant

  # Decided before `transact/1` is called, so that the refusal does not itself
  # mark somebody else's transaction as failed on the way out.
  @spec reentry(EmployerScope.t(), EmployerScope.t() | nil) :: entry()
  defp reentry(_scope, nil), do: :outermost
  defp reentry(same, same), do: :reentrant

  defp reentry(%EmployerScope{} = scope, %EmployerScope{} = in_force) do
    raise NestedScopeError,
      message: """
      #{inspect(__MODULE__)} was asked to open a scope for venue \
      #{scope.venue_id} inside one already in force for #{in_force.venue_id}.

      The two would share one Postgres transaction — there is no savepoint \
      between them — so the inner set_config would overwrite app.employer_id \
      and app.now for the rest of it and stay there after the inner call \
      returned. The outer work would read as the inner venue with nothing \
      raised anywhere.

      One unit of work is one venue. Pass the scope down rather than \
      opening a second one.
      """
  end

  @spec transact_scoped(
          entry(),
          EmployerScope.t(),
          (EmployerScope.t() -> {:ok, result} | {:error, reason})
        ) :: {:ok, result} | {:error, reason}
        when result: var, reason: var
  defp transact_scoped(:outermost, scope, fun), do: transact(fn -> run_scoped(scope, fun) end)

  # The settings this call would write are the ones already written, so it runs
  # the work and touches neither the connection nor the process dictionary. The
  # transaction is kept so that the return and rollback shapes do not depend on
  # how deep the caller happens to be.
  defp transact_scoped(:reentrant, scope, fun), do: transact(fn -> fun.(scope) end)

  @spec run_scoped(
          EmployerScope.t(),
          (EmployerScope.t() -> {:ok, result} | {:error, reason})
        ) :: {:ok, result} | {:error, reason}
        when result: var, reason: var
  defp run_scoped(scope, fun) do
    write_settings(scope)
    Process.put(@scope_key, scope)

    try do
      fun.(scope)
    after
      Process.delete(@scope_key)
    end
  end

  @spec write_settings(EmployerScope.t()) :: :ok
  defp write_settings(%EmployerScope{venue_id: venue_id, now: now}) do
    # Raw SQL on purpose: this runs before the scope is registered, and it must
    # not be refused by the guard it is on its way to satisfying.
    query!(
      "SELECT set_config('app.employer_id', $1, true), set_config('app.now', $2, true)",
      [venue_id, DateTime.to_iso8601(now)]
    )

    :ok
  end

  ## The unscoped guard

  @spec scoped?(operation()) :: boolean()
  defp scoped?(_operation), do: match?(%EmployerScope{}, Process.get(@scope_key))

  @spec allow_or_refuse(boolean(), operation()) :: keyword()
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

    Enum.flat_map(bindings, &expand_binding/1) ++
      Enum.flat_map(expression_subqueries(query), &expand/1) ++
      Enum.flat_map(nested_queries(query), &sources/1)
  end

  # One entry of a query's binding list: `Ecto.Query.FromExpr` or
  # `Ecto.Query.JoinExpr`. Neither exports a `t/0`, and naming the structs in a
  # spec is what `Credo.Check.Warning.SpecWithStruct` exists to stop, so the
  # shape is named here rather than at each call.
  @typep binding_expr() :: struct()

  # What one binding resolves to: the source a later `assoc` is resolved
  # against, and any source the join reaches without binding — the join table
  # of a `many_to_many`, the intermediate tables of a `:through`.
  @typep resolved_binding() :: {term(), [term()]}

  @spec resolve_bindings([binding_expr()]) :: [resolved_binding()]
  defp resolve_bindings(exprs) do
    Enum.reduce(exprs, [], fn expr, resolved -> resolved ++ [binding(expr, resolved)] end)
  end

  @spec binding(binding_expr(), [resolved_binding()]) :: resolved_binding()
  defp binding(%{source: nil, assoc: {index, field}}, resolved) do
    resolved |> Enum.at(index) |> association_source(field)
  end

  defp binding(%{source: source}, _resolved), do: {source, []}

  @spec association_source(resolved_binding() | nil, atom()) :: resolved_binding()
  defp association_source({{_table, schema}, _reached}, field)
       when is_atom(schema) and not is_nil(schema) do
    related(schema.__schema__(:association, field), schema, field)
  end

  defp association_source(_parent, _field), do: {nil, []}

  # An association reflection is not one shape. `has_one`/`has_many`/`belongs_to`
  # carry `:related` and nothing else; `many_to_many` carries `:related` and a
  # `:join_through` the query reaches without binding; `has_one`/`has_many`
  # `:through` carry neither, only a chain of association names — and reading
  # `.related` off one of those is a `KeyError` raised from inside
  # `prepare_query/3`, which fails closed and says nothing useful.
  @spec related(term(), module(), atom()) :: resolved_binding()
  defp related(
         %Ecto.Association.ManyToMany{related: related, join_through: join},
         _schema,
         _field
       ) do
    {{nil, related}, [join_source(join)]}
  end

  defp related(%Ecto.Association.HasThrough{owner: owner, through: through}, _schema, _field) do
    through
    |> Enum.reduce([{{nil, owner}, []}], &step_through/2)
    |> chain_binding()
  end

  defp related(%{related: related}, _schema, _field)
       when is_atom(related) and not is_nil(related) do
    {{nil, related}, []}
  end

  defp related(nil, schema, field) do
    raise ZoneViolationError,
      message: """
      An employer-scoped query joined #{inspect(schema)}.#{field}, which is not \
      an association.

      The query cannot be checked against the zones because there is no table \
      to name, so it is refused rather than sent. Ecto would refuse it too, one \
      layer further in.
      """
  end

  defp related(association, schema, field) do
    raise ZoneViolationError,
      message: """
      An employer-scoped query joined #{inspect(schema)}.#{field}, whose \
      reflection #{inspect(association.__struct__)} names no table this \
      backstop knows how to resolve.

      An association it cannot resolve is an association it cannot place in a \
      zone, so it is refused rather than sent. Teach `related/3` the shape.
      """
  end

  # `:through` is a chain of association names starting at the owner. Every
  # link is a table the join reaches, so the whole chain is walked rather than
  # only its last hop.
  @spec step_through(atom(), [resolved_binding()]) :: [resolved_binding()]
  defp step_through(field, [{source, _reached} | _rest] = chain) do
    [association_source({source, []}, field) | chain]
  end

  # The head of the walked chain is what a later `assoc` resolves against;
  # everything it passed through on the way is reached but not bound.
  @spec chain_binding([resolved_binding()]) :: resolved_binding()
  defp chain_binding([{source, reached} | passed]) do
    {source, reached ++ Enum.flat_map(passed, fn {each, more} -> [each | more] end)}
  end

  # `:join_through` is a schema module or a bare table name.
  @spec join_source(module() | String.t()) :: {String.t() | nil, module() | nil}
  defp join_source(join) when is_binary(join), do: {join, nil}
  defp join_source(join) when is_atom(join), do: {nil, join}

  @spec expand_binding(resolved_binding()) :: [{String.t() | nil, module() | nil}]
  defp expand_binding({source, reached}), do: Enum.flat_map([source | reached], &expand/1)

  # A binding is a `{table, schema}` pair, a subquery to walk into, or something
  # opaque — a fragment source, an unresolvable association — that only Postgres
  # can adjudicate.
  @spec expand(term()) :: [{String.t() | nil, module() | nil}]
  defp expand({table, schema}) when (is_binary(table) or is_nil(table)) and is_atom(schema) do
    [{table, schema}]
  end

  defp expand(%Ecto.SubQuery{query: query}), do: sources(query)
  defp expand(_source), do: []

  # A subquery written in `where`, `having`, `select`, `order_by`, `group_by`,
  # `distinct` or a window is not in the binding list. Ecto parks it on a
  # `:subqueries` field of the expression struct, and a walker reading bindings
  # alone waves it through — measured: of eight shapes, only from-position,
  # CTE, union and association joins were refused.
  #
  # The positions are the ones `Ecto.Query.Planner.plan/4` itself resolves
  # subqueries in, taken from there so the two lists cannot drift apart in
  # silence. `join ... on` is absent because Ecto refuses to build one.
  @expression_lists [:wheres, :havings, :order_bys, :group_bys]
  @expression_fields [:distinct, :select]

  @spec expression_subqueries(Ecto.Query.t()) :: [term()]
  defp expression_subqueries(%Ecto.Query{} = query) do
    windows = Enum.map(query.windows, fn {_name, window} -> window end)

    @expression_lists
    |> Enum.flat_map(&Map.fetch!(query, &1))
    |> Enum.concat(Enum.map(@expression_fields, &Map.fetch!(query, &1)))
    |> Enum.concat(windows)
    |> Enum.flat_map(&subqueries_of/1)
  end

  # `:distinct` and `:select` are nil on a query with neither, and
  # `Ecto.Query.QueryExpr` has no `:subqueries` key at all — so this reads the
  # key rather than assuming it.
  @spec subqueries_of(term()) :: [term()]
  defp subqueries_of(%_struct{} = expr), do: Map.get(expr, :subqueries, [])
  defp subqueries_of(_expr), do: []

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
