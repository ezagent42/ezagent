defmodule EzagentPluginGitWorkflow.ArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :architecture

  @app_dir Path.expand("../..", __DIR__)
  @lib_dir Path.join(@app_dir, "lib")

  describe "plugin dependency isolation" do
    test "workflow plugin has no GitHub, Kanban, or socialware plugin dependency" do
      mix_exs = Path.join(@app_dir, "mix.exs") |> File.read!()

      # Must NOT depend on these plugins
      refute mix_exs =~ ":ezagent_plugin_github"
      refute mix_exs =~ ":ezagent_plugin_kanban"
      refute mix_exs =~ ":ezagent_domain_socialware"
    end
  end

  describe "claim path rejects forbidden modules (static grep)" do
    @forbidden_modules ~w(
      Kind.spawn
      Cap.issue
      Cap.store
      Ezagent.DomainGit
      Ezagent.ActionSet.GitTaskAccess
      WorkspaceProvision
      Agent.Sidecar
      EzagentPluginGithub
      EzagentPluginKanban
      Req
    )

    test "claim implementation does not call forbidden modules" do
      lib_files =
        @lib_dir
        |> Path.join("**/*.ex")
        |> Path.wildcard()

      for file <- lib_files, file_base = Path.basename(file) do
        content = File.read!(file)

        for forbidden <- @forbidden_modules do
          refute String.contains?(content, forbidden),
                 "#{file_base}: references forbidden module/function `#{forbidden}`"
        end
      end
    end
  end

  describe "ActionSet surface audit" do
    test "GitWorkflow ActionSet only declares allowed actions" do
      actions = Ezagent.ActionSet.GitWorkflow.actions()

      allowed = ~w(register_binding disable_binding claim_task read_run)a

      for action <- actions do
        assert action in allowed,
               "GitWorkflow ActionSet declares unapproved action: #{action}"
      end
    end

    test "GitWorkflow ActionSet does not expose provider/materialize/spawn actions" do
      actions = Ezagent.ActionSet.GitWorkflow.actions()

      forbidden = ~w(
        materialize
        spawn
        provision
        create_pr
        wait_ci
        merge
        project
        issue_cap
        store_cap
        provision_workspace
        cleanup_workspace
      )a

      for action <- actions do
        refute action in forbidden,
               "GitWorkflow ActionSet exposes forbidden action: #{action}"
      end
    end
  end

  describe "schema field contract" do
    test "TaskBinding source has no secret fields" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/task_binding.ex"))

      # Scan @fields list and struct definition in source
      refute content =~ ~r/field\s+:token\b/
      refute content =~ ~r/field\s+:credential\b/
      refute content =~ ~r/field\s+:secret\b/
      refute content =~ ~r/field\s+:password\b/
      refute content =~ ~r/field\s+:oauth\b/
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
    end
  end

  describe "Store implementation audit" do
    test "Store uses no GenServer/Agent/ETS for concurrency" do
      store_file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex")
      content = File.read!(store_file)

      # Check for actual code usage, not docstring mentions
      refute content =~ ~r/\bGenServer\.(start|call|cast|start_link)\b/
      refute content =~ ~r/\bAgent\.(start|start_link|get|update)\b/
      refute content =~ ~r/\b:ets\.(new|insert|lookup)\b/
      refute content =~ ~r/Application\.put_env/
    end

    test "Store transition uses single-statement SQL CAS" do
      store_file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex")
      content = File.read!(store_file)

      # Must contain the UPDATE WHERE id AND state_version pattern
      assert content =~ "SET status ="
      assert content =~ "state_version"
      assert content =~ "WHERE id ="

      # Must NOT use get → changeset → update pattern
      refute content =~ "changeset"
      refute content =~ "Repo.get"
    end
  end
end
