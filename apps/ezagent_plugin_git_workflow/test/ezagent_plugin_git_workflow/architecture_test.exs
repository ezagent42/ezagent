defmodule EzagentPluginGitWorkflow.ArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :architecture

  @app_dir Path.expand("../..", __DIR__)
  @lib_dir Path.join(@app_dir, "lib")

  describe "no public ingress" do
    test "no ActionSet module exists" do
      action_set_dir = Path.join(@app_dir, "lib/ezagent/behavior")
      refute File.exists?(action_set_dir),
             "lib/ezagent/behavior/ must not exist — no ActionSet or public ingress"
    end

    test "lib modules do not reference Ezagent.ActionSet, Cap, or Plugin" do
      lib_files = Path.join(@lib_dir, "**/*.ex") |> Path.wildcard()

      for file <- lib_files do
        content = File.read!(file)
        base = Path.basename(file)

        refute content =~ ~r/\bdefmodule\s+Ezagent\.ActionSet\b/,
               "#{base}: must not define ActionSet"
        refute content =~ ~r/\buse\s+Ezagent\.ActionSet\b/,
               "#{base}: must not use ActionSet"
        refute content =~ ~r/\buse\s+Ezagent\.Plugin\b/,
               "#{base}: must not register as Plugin"
      end
    end

    test "no web wiring" do
      web_mix = Path.join(@app_dir, "../../ezagent_web/mix.exs") |> Path.expand()
      if File.exists?(web_mix) do
        content = File.read!(web_mix)
        refute content =~ ":ezagent_plugin_git_workflow",
               "ezagent_web must not depend on git_workflow"
      end
    end

    test "no release wiring" do
      root_mix = Path.join(@app_dir, "../../../mix.exs") |> Path.expand()
      if File.exists?(root_mix) do
        content = File.read!(root_mix)
        refute content =~ "ezagent_plugin_git_workflow:",
               "root mix.exs must not reference git_workflow in release"
      end
    end
  end

  describe "plugin dependency isolation" do
    test "workflow app has no GitHub, Kanban, or socialware plugin dependency" do
      mix_exs = Path.join(@app_dir, "mix.exs") |> File.read!()

      refute mix_exs =~ ":ezagent_plugin_github"
      refute mix_exs =~ ":ezagent_plugin_kanban"
      refute mix_exs =~ ":ezagent_domain_socialware"
    end
  end

  describe "claim path rejects forbidden modules" do
    test "Store and schema modules do not call Kind/Cap/Agent/sidecar" do
      sources = ~w(store.ex task_binding.ex workflow_run.ex)

      forbidden = ~w(
        Kind.spawn Cap.issue Cap.store Ezagent.ActionSet.GitTaskAccess
        EzagentPluginGithub EzagentPluginKanban WorkspaceProvision Agent.Sidecar
      )

      for source <- sources do
        file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/#{source}")
        if File.exists?(file) do
          content = File.read!(file)
          for forbidden_ref <- forbidden do
            refute content =~ ~r/#{forbidden_ref}/,
                   "#{source}: references forbidden #{forbidden_ref}"
          end
        end
      end
    end
  end

  describe "Store implementation audit" do
    test "Store uses no GenServer/Agent/ETS for concurrency" do
      store_file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex")
      content = File.read!(store_file)

      refute content =~ ~r/\bGenServer\.(start|call|cast|start_link)\b/
      refute content =~ ~r/\bAgent\.(start|start_link|get|update)\b/
      refute content =~ ~r/\b:ets\.(new|insert|lookup)\b/
      refute content =~ ~r/Application\.put_env/
    end

    test "Store transition uses single-statement SQL CAS" do
      store_file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex")
      content = File.read!(store_file)

      assert content =~ "SET status ="
      assert content =~ "state_version"
      assert content =~ "WHERE id ="

      refute content =~ "changeset"
      refute content =~ ~r/Repo\.get\b/
    end

    test "no authenticated_principal in Store code paths" do
      store_file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex")
      content = File.read!(store_file)
      # Check for actual field usage, not moduledoc mentions
      refute content =~ ~r/:authenticated_principal/
    end

    test "no Req/HTTP in Store or schemas" do
      sources = ~w(store.ex task_binding.ex workflow_run.ex)

      for source <- sources do
        file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/#{source}")
        if File.exists?(file) do
          content = File.read!(file)
          refute content =~ ~r/\bReq\.(get|post|put|delete|request)\b/,
                 "#{source}: must not use Req HTTP"
        end
      end
    end
  end

  describe "schema field contract" do
    test "TaskBinding source has no secret-value fields" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/task_binding.ex"))

      refute content =~ ~r/field\s+:token\b/
      refute content =~ ~r/field\s+:credential\b/
      refute content =~ ~r/field\s+:secret\b/
      refute content =~ ~r/field\s+:password\b/
      refute content =~ ~r/field\s+:installation_id\b/
      refute content =~ ~r/field\s+:private_key\b/
    end

    test "WorkflowRun source has no secret or lifecycle-result fields" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/workflow_run.ex"))

      refute content =~ ~r/field\s+:token\b/
      refute content =~ ~r/field\s+:secret\b/
      refute content =~ ~r/field\s+:password\b/
      refute content =~ ~r/field\s+:provider_response\b/
      refute content =~ ~r/field\s+:worker_pid\b/
      refute content =~ ~r/field\s+:workspace_cwd\b/
      refute content =~ ~r/field\s+:authenticated_principal\b/
    end
  end

  describe "migration contract" do
    test "migration uses proper Ecto.Migration DSL" do
      mig_path = Path.join(@app_dir, "../../ezagent_core/priv/repo_pg/migrations/20260724010000_create_git_workflow_intents.exs") |> Path.expand()
      if File.exists?(mig_path) do
        content = File.read!(mig_path)
        assert content =~ "use Ecto.Migration"
        assert content =~ "create table"
        assert content =~ "create unique_index"
      end
    end
  end
end
