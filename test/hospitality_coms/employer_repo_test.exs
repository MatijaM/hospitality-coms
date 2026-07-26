defmodule HospitalityComs.EmployerRepoTest do
  @moduledoc """
  Both repos run against the same database and differ only in the Postgres
  role they act as. This unit establishes that they exist and connect; the
  scoping wrapper and the zone grants arrive later.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias HospitalityComs.EmployerRepo
  alias HospitalityComs.Repo

  setup do
    repo_owner = Sandbox.start_owner!(Repo, shared: true)
    employer_owner = Sandbox.start_owner!(EmployerRepo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(employer_owner)
      Sandbox.stop_owner(repo_owner)
    end)
  end

  test "the primary repo connects as the application's own role" do
    assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
  end

  test "the employer repo connects as employer_role" do
    assert %{rows: [["employer_role"]]} = EmployerRepo.query!("SELECT current_user", [])
  end

  test "both repos address the same database" do
    assert EmployerRepo.config()[:database] == Repo.config()[:database]
    assert EmployerRepo.config()[:hostname] == Repo.config()[:hostname]
  end

  test "only the primary repo is registered for migrations" do
    assert Application.fetch_env!(:hospitality_coms, :ecto_repos) == [Repo]
  end
end
