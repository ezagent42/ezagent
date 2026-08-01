defmodule Mix.Tasks.Ezagent.CapRevocation.VerifyCleanStartTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ezagent.CapRevocation.VerifyCleanStart, as: Task

  @database "ezagent_pg_compat_test_clean_unit_123"

  test "database names are constrained to the disposable clean-test namespace" do
    assert Task.valid_database_name?(@database)
    assert Task.valid_database_name?("ezagent_pg_compat_test_clean_a0_b9")

    refute Task.valid_database_name?("ezagent_pg_compat_dev")
    refute Task.valid_database_name?("ezagent_pg_compat_test_clean_")
    refute Task.valid_database_name?("ezagent_pg_compat_test_clean_x-y")
    refute Task.valid_database_name?("ezagent_pg_compat_test_clean_x;drop_database")
    refute Task.valid_database_name?(nil)
  end

  test "every child receives the exact test environment and database" do
    assert Map.new(Task.child_env(@database, "clean_unit_123")) == %{
             "EZAGENT_TEST_DATABASE" => @database,
             "MIX_ENV" => "test",
             "MIX_TEST_PARTITION" => "clean_unit_123"
           }

    assert Enum.map(Task.phase_specs(), &elem(&1, 0)) == [
             :migrate,
             :seed,
             :first_boot,
             :cold_boot
           ]

    assert Enum.all?(Task.phase_specs(), fn {_phase, args} ->
             Enum.take(args, 2) == [
               "ezagent.cap_revocation.verify_clean_start",
               "__phase__"
             ]
           end)
  end

  test "a failed child still drops the exact created database" do
    parent = self()

    create = fn database -> send(parent, {:create, database}) end
    drop = fn database -> send(parent, {:drop, database}) end

    run_child = fn phase, _args, env ->
      send(parent, {:phase, phase, Map.new(env)})

      if phase == :seed do
        {"forced seed failure", 17}
      else
        {"ok", 0}
      end
    end

    assert_raise Mix.Error, ~r/seed.*exit 17/s, fn ->
      Task.execute(
        database: @database,
        partition: "clean_unit_123",
        create_database: create,
        drop_database: drop,
        run_child: run_child
      )
    end

    assert_received {:create, @database}
    assert_received {:phase, :migrate, %{"EZAGENT_TEST_DATABASE" => @database}}
    assert_received {:phase, :seed, %{"EZAGENT_TEST_DATABASE" => @database}}
    refute_received {:phase, :first_boot, _env}
    assert_received {:drop, @database}
  end

  test "child phase asserts the configured Repo database before phase work" do
    source = task_source()

    assert source =~
             ~r/defp run_child_phase!\(phase\).*assert_child_database!\(\).*run_phase!\(phase\)/s
  end

  test "umbrella aliases wire the clean-start gate into precommit exactly once" do
    source = File.read!(Path.join(repo_root(), "mix.exs"))

    assert source =~
             ~s("ci.clean_per_grant": ["ezagent.cap_revocation.verify_clean_start"])

    [precommit] = Regex.run(~r/precommit:\s*\[(.*?)\n\s*\],/s, source, capture: :all_but_first)
    assert length(Regex.scan(~r/"ci\.clean_per_grant"/, precommit)) == 1
  end

  defp task_source do
    File.read!(
      Path.join(
        repo_root(),
        "apps/ezagent_core/lib/mix/tasks/ezagent.cap_revocation.verify_clean_start.ex"
      )
    )
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
