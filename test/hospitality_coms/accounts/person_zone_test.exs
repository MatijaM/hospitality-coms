defmodule HospitalityComs.Accounts.PersonZoneTest do
  @moduledoc """
  No employer-side code path can create a person record (R1).

  There are two ways to be wrong about that and they need separate answers.

  The first is Postgres. `employer_role` holds no privilege on `people` or on
  `people_tokens`, so a statement issued through `EmployerRepo` is refused by
  the database rather than by an application check somebody can forget. That is
  asserted here against the privilege itself and against an actual attempted
  write. U3 adds the explicit `REVOKE` migration and the systematic sweep over
  every person-zone table; what this file pins is that the guarantee is already
  true for the tables this unit creates, so U3's migration is a statement of
  intent rather than the thing holding the door shut.

  Both tables are named, not just `people`. `people_tokens` holds the bearer
  credentials, so a role that could read it would not need to read `people` to
  become a worker — and U3 builds its sweep from the list this file
  establishes, so a table missing here is a table missing there.

  The second is us. A privilege only helps if person data goes through the repo
  the privilege applies to, so the Accounts context is checked — from compiled
  code, not from a grep — for any call into `EmployerRepo`. The modules that
  get checked are read out of the application's own module list, so U3 and U10
  are covered by this file without editing it.

  The third is the argument shape, and #18 is what put it here. U3 split
  `Accounts.Scope` into `PersonScope` and `EmployerScope` so that a person-zone
  function refuses an employer caller *by function clause* — a
  `FunctionClauseError` raised before the body runs, which is not something a
  caller can forget to check. That mechanism protected one function that reads
  no data; every other entry point took a bare address, a bare token or a bare
  `DateTime`, so an employer session reached the whole context with
  `employer_scope.now`. The sweep below quantifies over the module's **export
  list** rather than a list somebody maintains, the way the compiled-imports
  check quantifies over the application's module list.

  It is not the boundary and does not claim to be — `boundary_test.exs` holds
  the counterpart, which reads an address back through a *forged* person scope
  and passes, because `Accounts` goes through `Repo` and `Repo` holds every
  privilege. What closes the zone is the grant. What this closes is reaching
  the zone by accident.
  """

  # `EmployerRepo` needs its own sandbox owner and the compiled-code check reads
  # BEAM files, so neither half of this belongs in an async test.
  use ExUnit.Case, async: false

  import HospitalityComs.AccountsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.Accounts
  alias HospitalityComs.Accounts.EmployerScope
  alias HospitalityComs.Accounts.PersonScope
  alias HospitalityComs.Accounts.PersonToken
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo

  # A struct carrying exactly the two fields a person scope carries, and it is
  # the control that makes the head's *name* load-bearing. Every function below
  # would refuse an `EmployerScope` under a head written `%{person: p, now: n}`
  # too, because an employer scope has no `:person` key — so without this the
  # whole sweep is satisfied by a bare map pattern that lets any later struct
  # with the right shape straight through.
  defmodule NotAScope do
    @moduledoc false
    defstruct [:person, :now]
  end

  # The context's modules are read out of the application rather than listed,
  # so a module added by a later unit is covered the day it is compiled instead
  # of the day somebody remembers this file. `HospitalityComs.AccountsFixtures`
  # is a sibling, not a child, and the dotted prefix keeps it out.
  @accounts_prefix "Elixir.HospitalityComs.Accounts"
  @accounts_namespace @accounts_prefix <> "."

  @now ~U[2026-03-01 12:00:00.000000Z]

  setup do
    repo_owner = Sandbox.start_owner!(Repo, shared: true)
    employer_owner = Sandbox.start_owner!(EmployerRepo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(employer_owner)
      Sandbox.stop_owner(repo_owner)
    end)
  end

  describe "the employer role against people" do
    test "holds no INSERT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!("SELECT has_table_privilege('employer_role', 'people', 'INSERT')", [])
    end

    test "holds no SELECT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!("SELECT has_table_privilege('employer_role', 'people', 'SELECT')", [])
    end

    test "is refused by Postgres when it tries to create a person" do
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!(
          "INSERT INTO people (id, email, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, now(), now())",
          ["smuggled@example.com"]
        )
      end
    end

    test "is refused by Postgres when it tries to read people" do
      assert_raise Postgrex.Error, ~r/permission denied for table people/, fn ->
        EmployerRepo.query!("SELECT id FROM people", [])
      end
    end
  end

  describe "the employer role against people_tokens" do
    test "holds no INSERT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT has_table_privilege('employer_role', 'people_tokens', 'INSERT')",
                 []
               )
    end

    test "holds no SELECT privilege" do
      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT has_table_privilege('employer_role', 'people_tokens', 'SELECT')",
                 []
               )
    end

    test "is refused by Postgres when it tries to mint a credential" do
      assert_raise Postgrex.Error, ~r/permission denied for table people_tokens/, fn ->
        EmployerRepo.query!(
          """
          INSERT INTO people_tokens (id, person_id, token, context, inserted_at)
          VALUES (gen_random_uuid(), gen_random_uuid(), $1, 'session', now())
          """,
          [:crypto.strong_rand_bytes(32)]
        )
      end
    end

    test "is refused by Postgres when it tries to read credentials" do
      assert_raise Postgrex.Error, ~r/permission denied for table people_tokens/, fn ->
        EmployerRepo.query!("SELECT token FROM people_tokens", [])
      end
    end
  end

  describe "the accounts context" do
    test "calls no repo but the person zone's own" do
      offenders =
        Enum.filter(accounts_modules(), fn module ->
          module |> called_modules() |> Enum.member?(EmployerRepo)
        end)

      assert offenders == []
    end

    test "actually reaches the repo it claims to" do
      # Guards the test above from passing because the module list came back
      # empty or the imports chunk stopped being readable.
      assert Repo in called_modules(Accounts)
    end

    test "sweeps the whole namespace rather than a list somebody maintains" do
      modules = accounts_modules()

      assert Accounts in modules
      assert Accounts.Person in modules
      assert Accounts.PersonToken in modules
      refute HospitalityComs.AccountsFixtures in modules
    end
  end

  describe "the scope-first shape, across the whole context" do
    setup :a_person_and_their_credentials

    test "every repo-touching function refuses an employer scope by function clause", context do
      employer = EmployerScope.for_employer(Ecto.UUID.generate(), @now)

      for {{name, arity}, args, _anonymous} <- calls(context) do
        error =
          assert_raise FunctionClauseError, fn ->
            apply(Accounts, name, [employer | args])
          end

        # The refusal is *this* head and not something three frames down that
        # the employer scope happened to reach. Without these three, a crash
        # anywhere inside the body satisfies the assertion above — which is the
        # shape `docs/solutions/test-failures/tests-that-certify-nothing.md`
        # catalogues twenty-one instances of.
        assert error.module == Accounts,
               "#{name}/#{arity} refused inside #{inspect(error.module)}"

        assert error.function == name
        assert error.arity == refusing_arity(name)
      end
    end

    test "…and answers the same call with a person scope", context do
      scope = PersonScope.for_person(context.person, @now)

      # The control for the test above, and it is `does not raise` rather than
      # `does not raise FunctionClauseError`: every argument in the table is a
      # valid one, so a call that raises anything is a call whose refusal was
      # about the arguments rather than about the scope.
      for {{name, _arity}, args, _anonymous} <- calls(context) do
        apply(Accounts, name, [scope | args])
      end
    end

    test "…and refuses a struct carrying the same two fields", context do
      impostor = %NotAScope{person: context.person, now: @now}

      for {{name, arity}, args, _anonymous} <- calls(context) do
        error =
          assert_raise FunctionClauseError, fn -> apply(Accounts, name, [impostor | args]) end

        assert error.module == Accounts,
               "#{name}/#{arity} refused inside #{inspect(error.module)}"

        assert error.function == name
        assert error.arity == refusing_arity(name)
      end
    end

    test "covers every export but the one that reaches no repo", context do
      exported = MapSet.new(Accounts.__info__(:functions))
      covered = MapSet.new(calls(context), fn {key, _args, _anonymous} -> key end)

      # Written as a literal rather than as a module attribute, so growing the
      # exception list is an edit to this assertion and shows up in the diff.
      # `session_token_digest/1` is the whole of it: see the test below.
      assert MapSet.difference(exported, covered) ==
               MapSet.new([{:session_token_digest, 1}])
    end

    test "and that one is a pure hash of its argument", %{session_token: token} do
      # The exception's justification, made assertable. It reaches no repo, no
      # row and no clock, so a scope would say nothing about it — and an
      # exception nobody can check is a hole in the sweep above.
      assert Accounts.session_token_digest(token) == :crypto.hash(:sha256, token)
      assert Accounts.session_token_digest(token) == PersonToken.hash_token(token)
    end

    test "and no function that reaches the repo can be excepted from it", context do
      covered = MapSet.new(calls(context), fn {key, _args, _anonymous} -> key end)

      # The literal above pins the exception list in a diff; it does not *fail*
      # when somebody grows it, so on its own it lets a repo-touching function
      # be hidden by two lines in one assertion. Measured: deleting
      # `get_person_by_email/2` from the table and adding it to the literal
      # killed nothing. This is the direction that fails — the exception list
      # can only ever hold functions that reach no repo, and which those are is
      # read out of the source rather than declared.
      #
      # It is one-directional on purpose. `sudo_mode?/2` reaches no repo either
      # and still takes a scope, so "mentions no Repo" permits an exception
      # rather than requiring one.
      #
      # Its known edge is the one `lifecycle_test.exs`'s source sweep has: a
      # body that delegates to a private helper mentions no repo of its own.
      assert MapSet.difference(repo_touching_functions(), covered) == MapSet.new()
    end

    test "…and there are enough of those for that to mean something", _context do
      # Control. The check above passes trivially on an empty set — which is
      # what it would answer if the file stopped parsing, if `Repo` were
      # aliased under another name, or if the walk stopped seeing `def`.
      touching = repo_touching_functions()

      assert MapSet.size(touching) >= 12
      assert {:get_person_by_email, 2} in touching
      assert {:login_person_by_magic_link, 2} in touching
      refute {:session_token_digest, 1} in touching
      refute {:sudo_mode?, 2} in touching
    end

    test "answers an anonymous person scope wherever the subject is handed in", context do
      anonymous = PersonScope.for_person(nil, @now)

      # Registration and log-in are anonymous, and one of these is the call
      # that *produces* the person a scope will carry — so a head that required
      # one would close the log-in door. `PersonScope.for_person(nil, now)` is
      # what every unauthenticated request already carries.
      for {{name, _arity}, args, :anonymous} <- calls(context) do
        apply(Accounts, name, [anonymous | args])
      end
    end

    test "…and refuses one wherever the scope's person is the subject", context do
      anonymous = PersonScope.for_person(nil, @now)

      # The control for the test above. Without it, "an anonymous scope reaches
      # the context" is satisfied by every head accepting `person: nil` — which
      # would mint a session token for nobody and mail a link to nowhere.
      for {{name, arity}, args, :named} <- calls(context) do
        error =
          assert_raise FunctionClauseError, fn -> apply(Accounts, name, [anonymous | args]) end

        assert error.module == Accounts,
               "#{name}/#{arity} refused inside #{inspect(error.module)}"

        assert error.function == name
        assert error.arity == refusing_arity(name)
      end
    end

    test "splits every covered function into exactly one of those two", context do
      kinds = calls(context) |> Enum.map(fn {_key, _args, kind} -> kind end) |> Enum.uniq()

      # So the two tests above cannot between them skip a function: a third
      # label, or a missing one, fails here rather than silently narrowing the
      # quantifier of one of them.
      assert Enum.sort(kinds) == [:anonymous, :named]
    end
  end

  # Every argument here is valid, which is what makes the person-scope control
  # meaningful — see the tests above. The third element says whether the head
  # takes its subject from the scope's person (`:named`) or from an argument
  # (`:anonymous`), which is the one thing that genuinely differs per function.
  #
  # `sudo_mode?/1` and `/2` are two exports of one definition with a default,
  # and both have to be here or the coverage assertion has a hole its own
  # source cannot show. Both are `:anonymous`: the second clause answers an
  # anonymous scope `false` rather than refusing it, deliberately.
  defp calls(%{person: person, session_token: session_token, digest: digest}) do
    url = &"http://localhost/#{&1}"

    [
      {{:get_person_by_email, 2}, [person.email], :anonymous},
      {{:get_person!, 2}, [person.id], :anonymous},
      {{:register_person, 2}, [%{email: unique_person_email()}], :anonymous},
      {{:request_login_instructions, 3}, [unique_person_email(), url], :anonymous},
      {{:get_person_by_session_token, 2}, [session_token], :anonymous},
      {{:get_person_by_session_token_digest, 2}, [digest], :anonymous},
      {{:get_person_by_magic_link_token, 2}, ["not a token"], :anonymous},
      {{:login_person_by_magic_link, 2}, ["not a token"], :anonymous},
      {{:delete_person_session_token, 2}, ["nobody issued this"], :anonymous},
      {{:sudo_mode?, 1}, [], :anonymous},
      {{:sudo_mode?, 2}, [-20], :anonymous},
      {{:generate_person_session_token, 1}, [], :named},
      {{:update_display_name, 2}, ["Wendy Darling"], :named},
      {{:update_person_email, 2}, ["not a token"], :named},
      {{:deliver_login_instructions, 2}, [url], :named},
      {{:deliver_person_update_email_instructions, 3}, [unique_person_email(), url], :named}
    ]
  end

  @accounts_source "lib/hospitality_coms/accounts.ex"

  # Every public function whose own body names a repo, read out of the source
  # AST rather than out of a list. `lifecycle_test.exs` parses source for the
  # same reason: the compiled `imports` chunk is per module, so it can say that
  # `Accounts` reaches `Repo` and never which function did.
  defp repo_touching_functions do
    @accounts_source
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:def, _meta, [head, body]} = node, acc ->
        {node, [{signature(head), names_repo?(body)} | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.filter(fn {_signature, touches} -> touches end)
    |> MapSet.new(fn {signature, _touches} -> signature end)
  end

  defp signature({:when, _meta, [head | _guards]}), do: signature(head)

  defp signature({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp signature({name, _meta, nil}) when is_atom(name), do: {name, 0}

  # `Repo.get_by(…)`, and `insert_login_token(Repo, …)` where it is passed as a
  # value — both are the function reaching the repo.
  defp names_repo?(ast) do
    ast
    |> Macro.prewalk(false, fn
      {:__aliases__, _meta, parts} = node, found when is_list(parts) ->
        {node, found or List.last(parts) == :Repo}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  # The arity of the clause that does the refusing, which is not always the
  # arity the call was made at: a default argument (`sudo_mode?/2`'s `minutes`)
  # exports a lower arity that delegates to the full one, so a `sudo_mode?/1`
  # call is refused by `sudo_mode?/2`'s head. Derived rather than tabulated,
  # because "the definition's own head" is the claim and the maximum exported
  # arity for a name is where a definition's head is.
  defp refusing_arity(name) do
    Accounts.__info__(:functions)
    |> Enum.filter(fn {exported, _arity} -> exported == name end)
    |> Enum.map(fn {_name, arity} -> arity end)
    |> Enum.max()
  end

  defp a_person_and_their_credentials(_context) do
    person = person_fixture(%{}, @now)
    session_token = Accounts.generate_person_session_token(PersonScope.for_person(person, @now))

    %{
      person: person,
      session_token: session_token,
      digest: Accounts.session_token_digest(session_token)
    }
  end

  defp accounts_modules do
    {:ok, modules} = :application.get_key(:hospitality_coms, :modules)
    Enum.filter(modules, &accounts_module?(Atom.to_string(&1)))
  end

  defp accounts_module?(@accounts_prefix), do: true
  defp accounts_module?(@accounts_namespace <> _rest), do: true
  defp accounts_module?(_name), do: false

  defp called_modules(module) do
    {:ok, {^module, [imports: imports]}} =
      module |> :code.which() |> :beam_lib.chunks([:imports])

    imports |> Enum.map(fn {called, _fun, _arity} -> called end) |> Enum.uniq()
  end
end
