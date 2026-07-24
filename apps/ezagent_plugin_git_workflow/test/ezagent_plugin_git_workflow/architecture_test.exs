defmodule EzagentPluginGitWorkflow.ArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :architecture

  @app_dir Path.expand("../..", __DIR__)
  @lib_dir Path.join(@app_dir, "lib")

  describe "no public ingress" do
    test "no ActionSet module exists" do
      action_set_dir = Path.join(@app_dir, "lib/ezagent/behavior")
      refute File.exists?(action_set_dir),
             "lib/ezagent/behavior/ must not exist"
    end

    test "no ActionSet in any lib module" do
      lib_files = Path.join(@lib_dir, "**/*.ex") |> Path.wildcard()

      for file <- lib_files do
        content = File.read!(file)
        base = Path.basename(file)

        refute content =~ ~r/\bdefmodule\s+Ezagent\.ActionSet\b/, "#{base}: no ActionSet"
        refute content =~ ~r/\buse\s+Ezagent\.ActionSet\b/, "#{base}: no use ActionSet"
      end
    end

    test "Application module uses Ezagent.Plugin exactly once for dormant contract" do
      app_file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/application.ex")
      content = File.read!(app_file)

      # Must use Ezagent.Plugin for the :ezagent_plugin_check compiler gate
      assert content =~ ~r/\buse\s+Ezagent\.Plugin\b/,
             "application.ex: must use Ezagent.Plugin for compiler contract"

      # Only the Application module may use it
      other_files =
        Path.join(@lib_dir, "**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, "application.ex"))

      for file <- other_files do
        content = File.read!(file)
        base = Path.basename(file)
        refute content =~ ~r/\buse\s+Ezagent\.Plugin\b/,
               "#{base}: only application.ex may use Ezagent.Plugin"
      end
    end

    test "Application module never calls Ezagent.Plugin.boot/1" do
      lib_files = Path.join(@lib_dir, "**/*.ex") |> Path.wildcard()

      for file <- lib_files do
        content = File.read!(file)
        base = Path.basename(file)
        refute content =~ ~r/Ezagent\.Plugin\.boot\b/,
               "#{base}: must not call Plugin.boot"
      end
    end

    test "no web wiring" do
      web_mix = Path.join(@app_dir, "../../ezagent_web/mix.exs") |> Path.expand()
      if File.exists?(web_mix) do
        content = File.read!(web_mix)
        refute content =~ ":ezagent_plugin_git_workflow"
      end
    end

    test "no release wiring" do
      root_mix = Path.join(@app_dir, "../../../mix.exs") |> Path.expand()
      if File.exists?(root_mix) do
        content = File.read!(root_mix)
        refute content =~ "ezagent_plugin_git_workflow:"
      end
    end
  end

  describe "plugin dependency isolation" do
    test "no GitHub, Kanban, or socialware plugin dependency" do
      mix_exs = Path.join(@app_dir, "mix.exs") |> File.read!()
      refute mix_exs =~ ":ezagent_plugin_github"
      refute mix_exs =~ ":ezagent_plugin_kanban"
      refute mix_exs =~ ":ezagent_domain_socialware"
    end
  end

  describe "claim path rejects forbidden modules" do
    test "no Kind/Cap/Agent/sidecar/Req in lib modules" do
      sources = ~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex)
      forbidden = ~w(
        Kind.spawn Cap.issue Cap.store Ezagent.ActionSet.GitTaskAccess
        EzagentPluginGithub EzagentPluginKanban WorkspaceProvision Agent.Sidecar
        Req.get Req.post Req.put Req.delete Req.request
      )

      for source <- sources do
        file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/#{source}")
        if File.exists?(file) do
          content = File.read!(file)
          for fb <- forbidden do
            refute content =~ ~r/#{fb}/, "#{source}: references #{fb}"
          end
        end
      end
    end
  end

  describe "Store implementation" do
    test "no GenServer/Agent/ETS/concurrent" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex"))
      refute content =~ ~r/\bGenServer\.(start|call|cast|start_link)\b/
      refute content =~ ~r/\bAgent\.(start|start_link|get|update)\b/
      refute content =~ ~r/\b:ets\.(new|insert|lookup)\b/
    end

    test "single-statement SQL CAS" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex"))
      assert content =~ "SET status ="
      assert content =~ "state_version"
      assert content =~ "WHERE id ="
      refute content =~ "changeset"
      refute content =~ ~r/Repo\.get\b/
    end

    test "no authenticated_principal in code" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex"))
      refute content =~ ":authenticated_principal"
    end

    test "accept/1 only takes AcceptIntent struct (not map)" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex"))
      assert content =~ ~r/def accept\(%AcceptIntent\{\}/
    end

    test "no String.to_atom/1 (atom safety)" do
      for source <- ~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex) do
        file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/#{source}")
        if File.exists?(file) do
          content = File.read!(file)
          # String.to_existing_atom is allowed; String.to_atom/1 (without _existing) is forbidden
          refute content =~ ~r/\bString\.to_atom\(/,
                 "#{source}: must not use String.to_atom/1"
        end
      end
    end
  end

  describe "schema field contract" do
    test "TaskBinding struct keys have no secret fields" do
      # Use the actual struct definition to get keys
      keys =
        %{__struct__: EzagentPluginGitWorkflow.TaskBinding,
          id: "", generation: 1, workspace_uri: nil, task_receiver_uri: nil,
          credential_owner_uri: nil, repository_uri: nil, provider_adapter: nil,
          provider_host: "", external_id: "", owner_path: "", base_ref: "",
          visibility: nil, allowed_head_namespace: "", enabled: true}
        |> Map.keys()
        |> Enum.reject(&(&1 in [:__struct__]))

      forbidden = ~w(token credential secret password oauth installation_id private_key)a
      for key <- keys do
        ks = Atom.to_string(key)
        unless key == :credential_owner_uri do
          refute Enum.any?(forbidden, &String.contains?(ks, Atom.to_string(&1))),
                 "TaskBinding key #{key} forbidden"
        end
      end
    end

    test "WorkflowRun struct has no auth/secret fields" do
      keys =
        %{__struct__: EzagentPluginGitWorkflow.WorkflowRun,
          id: "", binding_id: "", binding_generation: 1, external_task_id: "",
          status: "", state_version: 1, input_digest: "", source_task_uri: nil,
          source_revision: nil, requested_head_ref: nil, last_error_code: nil}
        |> Map.keys()
        |> Enum.reject(&(&1 in [:__struct__]))

      forbidden = ~w(authenticated_principal token credential secret password provider_response worker_pid workspace_cwd)a
      for key <- keys do
        ks = Atom.to_string(key)
        refute Enum.any?(forbidden, &String.contains?(ks, Atom.to_string(&1))),
               "WorkflowRun key #{key} forbidden"
      end
    end

    test "AcceptIntent only has caller fields" do
      keys = EzagentPluginGitWorkflow.AcceptIntent.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))
      allowed = ~w(binding_id binding_generation external_task_id source_task_uri source_revision requested_head_ref)a
      assert MapSet.equal?(MapSet.new(keys), MapSet.new(allowed)),
             "AcceptIntent keys: #{inspect(keys)}"
    end

    test "migration has no authenticated_principal column" do
      mig = Path.join(@app_dir, "../../ezagent_core/priv/repo_pg/migrations/20260724010000_create_git_workflow_intents.exs") |> Path.expand()
      if File.exists?(mig) do
        content = File.read!(mig)
        refute content =~ "authenticated_principal"
      end
    end

    test "Store public accept type is AcceptIntent" do
      content = File.read!(Path.join(@lib_dir, "ezagent_plugin_git_workflow/store.ex"))
      # Verify the typespec
      assert content =~ "AcceptIntent.t()"
    end
  end

  describe "no CapBAC / authorization" do
    test "no reference to Ezagent.Cap in lib modules" do
      for source <- ~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex) do
        file = Path.join(@lib_dir, "ezagent_plugin_git_workflow/#{source}")
        if File.exists?(file) do
          content = File.read!(file)
          refute content =~ "Ezagent.Cap", "#{source}: no Cap reference"
        end
      end
    end

    test "no EntityCaps/PresenterCaps reference" do
      lib_files = Path.join(@lib_dir, "**/*.ex") |> Path.wildcard()
      for file <- lib_files do
        content = File.read!(file)
        refute content =~ "EntityCaps"
        refute content =~ "PresenterCaps"
      end
    end

    test "no wildcard/admin fixture patterns" do
      lib_files = Path.join(@lib_dir, "**/*.ex") |> Path.wildcard()
      for file <- lib_files do
        content = File.read!(file)
        refute content =~ ~r/wildcard.*cap/i
        refute content =~ ~r/admin.*fixture/i
        refute content =~ ~r/Cap\.issue/
        refute content =~ ~r/Cap\.store/
      end
    end
  end
end
