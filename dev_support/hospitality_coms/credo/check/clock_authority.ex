defmodule HospitalityComs.Credo.Check.ClockAuthority do
  @moduledoc false

  use Credo.Check,
    id: "HC_CLOCK_AUTHORITY",
    base_priority: :high,
    category: :warning,
    param_defaults: [
      clock_module: HospitalityComs.Clock,
      boundary_modules: []
    ],
    explanations: [
      check: """
      One instant per unit of work, and one module that produces it.

      Time-dependent behaviour in this application is derived rather than
      stored: an engagement is active when its period contains the instant, a
      grace window is open when the shift's window contains the instant, a peer
      connection has lapsed when the instant is past the lapse deadline. If two
      queries in the same unit of work read the clock separately, they can
      disagree about which side of a boundary the work fell on — one call sees
      an entry as concurrent while the next sees it as expired.

      Two rules follow, and this check enforces both.

      `DateTime.utc_now/0` belongs only to the clock. Everywhere else, the
      instant arrives on a scope struct — `PersonScope` in the person zone,
      `EmployerScope` in the employer zone. There is no single `Scope`; the two
      are separate so that a context function refuses the wrong caller by
      function clause.

          # BAD
          def active?(engagement) do
            DateTime.compare(engagement.ends_at, DateTime.utc_now()) == :gt
          end

          # GOOD
          def active?(engagement, %EmployerScope{now: now}) do
            DateTime.compare(engagement.ends_at, now) == :gt
          end

      `Clock.now/0` belongs only to a unit-of-work boundary — an HTTP request,
      one inbound channel message, one job attempt — which captures the instant
      once and puts it on the scope. Those modules are listed in
      `:boundary_modules`. An empty list means no module may call
      `Clock.now/0`, which is the correct default while the boundary is still
      being built. `HospitalityComsWeb.PersonAuth` is the first entry.

      A repo is not a boundary and is not on that list.
      `HospitalityComs.EmployerRepo.scoped_transaction/2` takes the instant off
      the scope it is handed, for the same reason: the unit of work that
      captured it is the one that gets to say what "now" is.

      `Ecto.Query.ago/2` and `from_now/2` are banned outright, and are the
      reason this rule needs enforcing in a query as well as in Elixir. They
      expand to `DateTime.utc_now/0` *inside the query macro*, which is the
      worst of both worlds: the offsettable clock cannot move them, and the
      expansion happens after this check has read the source, so nothing would
      see them if the call itself were not flagged.

          # BAD — a horizon nobody in this application chose
          from t in Token, where: t.inserted_at > ago(14, "day")

          # GOOD — a horizon derived from the unit of work's instant
          from t in Token, where: t.inserted_at > ^DateTime.add(now, -14, :day)
      """,
      params: [
        clock_module: "The module that owns the current instant.",
        boundary_modules:
          "Modules permitted to call the clock, i.e. those that open a unit of work."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta

  # `Ecto.Query`'s relative-time macros. Both take an amount and a unit, and
  # both read the wall clock where nothing can reach them.
  @query_macros [:ago, :from_now]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    config = build_config(source_file, params)

    {_ast, {issues, _module_stack}} =
      source_file
      |> SourceFile.ast()
      |> Macro.traverse({[], []}, &enter(&1, &2, config), &leave/2)

    Enum.reverse(issues)
  end

  defp build_config(source_file, params) do
    clock_module = Params.get(params, :clock_module, __MODULE__)
    boundary_modules = Params.get(params, :boundary_modules, __MODULE__)

    %{
      issue_meta: IssueMeta.for(source_file, params),
      clock_name: inspect(clock_module),
      clock_parts: clock_module |> Module.split() |> Enum.map(&String.to_atom/1),
      boundary_names: Enum.map(boundary_modules, &inspect/1)
    }
  end

  # Track the enclosing module so a call can be attributed to the module that
  # makes it. The stack is pushed for every `defmodule`, named or not, so that
  # `leave/2` can pop unconditionally.
  defp enter(
         {:defmodule, _meta, [{:__aliases__, _, parts} | _rest]} = ast,
         {issues, stack},
         _config
       ) do
    {ast, {issues, [qualify(Enum.join(parts, "."), stack) | stack]}}
  end

  defp enter({:defmodule, _meta, _args} = ast, {issues, stack}, _config) do
    {ast, {issues, [nil | stack]}}
  end

  defp enter(
         {{:., meta, [{:__aliases__, _, [:DateTime]}, :utc_now]}, _call, _args} = ast,
         {issues, stack},
         config
       ) do
    {ast, {utc_now_issues(current_module(stack), meta, config) ++ issues, stack}}
  end

  defp enter(
         {{:., meta, [{:__aliases__, _, parts}, :now]}, _call, []} = ast,
         {issues, stack},
         config
       ) do
    {ast, {clock_now_issues(parts, current_module(stack), meta, config) ++ issues, stack}}
  end

  # `Ecto.Query.ago(14, "day")`, written out in full.
  defp enter(
         {{:., meta, [{:__aliases__, _, _parts}, name]}, _call, [_amount, _unit]} = ast,
         {issues, stack},
         config
       )
       when name in @query_macros do
    {ast, {[issue({:query_macro, name}, meta, config) | issues], stack}}
  end

  # `ago(14, "day")`, imported, which is how it is always actually written.
  defp enter({name, meta, [_amount, _unit]} = ast, {issues, stack}, config)
       when name in @query_macros do
    {ast, {[issue({:query_macro, name}, meta, config) | issues], stack}}
  end

  defp enter(ast, acc, _config), do: {ast, acc}

  defp leave({:defmodule, _meta, _args} = ast, {issues, [_module | stack]}),
    do: {ast, {issues, stack}}

  defp leave(ast, acc), do: {ast, acc}

  defp utc_now_issues(module, meta, config) do
    module
    |> clock_namespace?(config)
    |> issues_unless_allowed(:utc_now, meta, config)
  end

  defp clock_now_issues(parts, module, meta, config) do
    parts
    |> clock_alias?(config)
    |> issues_for_clock_now(module, meta, config)
  end

  defp issues_for_clock_now(false, _module, _meta, _config), do: []

  defp issues_for_clock_now(true, module, meta, config) do
    allowed? = boundary_module?(module, config) or clock_namespace?(module, config)
    issues_unless_allowed(allowed?, :clock_now, meta, config)
  end

  defp issues_unless_allowed(true, _kind, _meta, _config), do: []
  defp issues_unless_allowed(false, kind, meta, config), do: [issue(kind, meta, config)]

  defp issue(:utc_now, meta, config) do
    format_issue(config.issue_meta,
      message:
        "Only #{config.clock_name} may read the wall clock. Take the instant from the scope carried by the unit of work.",
      trigger: "DateTime.utc_now",
      line_no: meta[:line]
    )
  end

  defp issue(:clock_now, meta, config) do
    format_issue(config.issue_meta,
      message:
        "#{config.clock_name}.now/0 may only be called where a unit of work begins. Carry the instant on the scope instead.",
      trigger: "Clock.now",
      line_no: meta[:line]
    )
  end

  defp issue({:query_macro, name}, meta, config) do
    format_issue(config.issue_meta,
      message:
        "Ecto.Query.#{name}/2 expands to DateTime.utc_now/0 inside the query, where neither this check nor the clock can reach it. Compare against an instant carried by the unit of work.",
      trigger: Atom.to_string(name),
      line_no: meta[:line]
    )
  end

  # An alias names the clock when its segments are a suffix of the clock's own,
  # so both `Clock.now()` and `HospitalityComs.Clock.now()` are recognised.
  defp clock_alias?(parts, %{clock_parts: clock_parts})
       when length(parts) <= length(clock_parts) do
    Enum.take(clock_parts, -length(parts)) == parts
  end

  defp clock_alias?(_parts, _config), do: false

  defp clock_namespace?(nil, _config), do: false

  defp clock_namespace?(module, %{clock_name: clock_name}) do
    module == clock_name or String.starts_with?(module, clock_name <> ".")
  end

  defp boundary_module?(module, %{boundary_names: boundary_names}), do: module in boundary_names

  defp current_module([]), do: nil
  defp current_module([module | _rest]), do: module

  defp qualify(name, []), do: name
  defp qualify(name, [parent | _rest]) when is_binary(parent), do: parent <> "." <> name
  defp qualify(name, _stack), do: name
end
