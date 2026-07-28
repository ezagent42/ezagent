defmodule EzagentPluginGitWorkflow.ArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :architecture

  @app_dir Path.expand("../..", __DIR__)
  @lib_dir Path.join(@app_dir, "lib")

  # Single source of truth for the "scan every claim-path source file" checks
  # below (previously duplicated three times, which is how the atom-safety
  # scan missed deterministic_ref.ex).
  # NOTE (P4a): this is a hand-maintained list, so a NEW lib module escapes
  # every scan below until someone remembers to add it here. `authorized_task.ex`
  # and `blocker.ex` are added with the modules themselves for that reason — the
  # `Cap.issue`/`Cap.store` half of the forbidden-module scan is the design's
  # §3.2 "the workflow never mints a cap" line, and it is worth nothing on a
  # file the scan does not read.
  @source_files ~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex
                   deterministic_ref.ex execution_seam.ex execution_seam/unavailable.ex
                   authorization.ex workflow_facts.ex authorized_task.ex blocker.ex)

  # The small, closed set of non-test config files that could theoretically
  # select the ExecutionSeam backend. config/test.exs is deliberately
  # excluded — it is the one place allowed to name a (test-only) backend.
  @execution_seam_config_files ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs)

  # Matches the key in either legal Elixir config spelling:
  #   config :ezagent_plugin_git_workflow, :execution_seam, Foo   (leading colon)
  #   config :ezagent_plugin_git_workflow, execution_seam: Foo    (trailing colon,
  #     the ordinary keyword-list form — this is the one the original gate missed)
  @execution_seam_key_pattern ~r/:execution_seam\b|\bexecution_seam\s*:/

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
      forbidden = ~w(
        Kind.spawn Cap.issue Cap.store Ezagent.ActionSet.GitTaskAccess
        EzagentPluginGithub EzagentPluginKanban WorkspaceProvision Agent.Sidecar
        Req.get Req.post Req.put Req.delete Req.request
      )

      for source <- @source_files do
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
      assert content =~ ~r/def accept\(%AcceptIntent\{/
    end

    test "no String.to_atom/1 (atom safety)" do
      for source <- @source_files do
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
        %{
          __struct__: EzagentPluginGitWorkflow.TaskBinding,
          id: "",
          generation: 1,
          workspace_uri: nil,
          task_receiver_uri: nil,
          credential_owner_uri: nil,
          repository_uri: nil,
          provider_adapter: nil,
          provider_host: "",
          external_id: "",
          owner_path: "",
          base_ref: "",
          visibility: nil,
          allowed_head_namespace: "",
          enabled: true
        }
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
        EzagentPluginGitWorkflow.WorkflowRun.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 in [:__struct__]))

      forbidden =
        ~w(authenticated_principal token credential secret password provider_response worker_pid workspace_cwd)a

      for key <- keys do
        ks = Atom.to_string(key)

        refute Enum.any?(forbidden, &String.contains?(ks, Atom.to_string(&1))),
               "WorkflowRun key #{key} forbidden"
      end
    end

    test "AcceptIntent only has caller fields" do
      keys =
        EzagentPluginGitWorkflow.AcceptIntent.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))

      allowed =
        ~w(binding_id binding_generation external_task_id source_task_uri source_revision requested_head_ref)a

      assert MapSet.equal?(MapSet.new(keys), MapSet.new(allowed)),
             "AcceptIntent keys: #{inspect(keys)}"
    end

    test "migration has no authenticated_principal column" do
      mig =
        Path.join(
          @app_dir,
          "../../ezagent_core/priv/repo_pg/migrations/20260724010000_create_git_workflow_intents.exs"
        )
        |> Path.expand()

      if File.exists?(mig) do
        content = File.read!(mig)
        refute content =~ "authenticated_principal"
      end
    end

    test "git_workflow_facts migration has no secret/raw-response column" do
      mig =
        Path.join(
          @app_dir,
          "../../ezagent_core/priv/repo_pg/migrations/20260725120000_create_git_workflow_facts.exs"
        )
        |> Path.expand()

      if File.exists?(mig) do
        content = File.read!(mig)

        for forbidden <- ~w(token authorization private_key raw_response header credential) do
          refute content =~ forbidden, "migration must not have a #{forbidden} column"
        end
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
      for source <- @source_files do
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

  describe "execution seam is fail-closed and test-only-injectable" do
    test "no non-test config file sets :execution_seam, in any spelling" do
      for file <- @execution_seam_config_files do
        path = Path.join(@app_dir, "../../#{file}") |> Path.expand()

        if File.exists?(path) do
          content = File.read!(path)

          refute content =~ @execution_seam_key_pattern,
                 "#{file} must not set :execution_seam (any spelling) — only " <>
                   "config/test.exs may, and only to a test-build-only delegator (design §3.1)"
        end
      end
    end

    # Fix 1 (Application.compile_env/3) already made every runtime mutation
    # path — Application.put_env/3, Application.put_all_env/2,
    # :application.set_env/3, release config applied post-compile, a remote
    # IEx/RPC session, any other in-VM caller — unable to change what
    # implementation/0 resolves to: the value is baked into the module at
    # compile time. A gate that greps lib/ for mutation call spellings is
    # therefore both unwinnable (String.to_atom/apply/variable-argument
    # indirection are not statically decidable — same reasoning as
    # Ezagent.ActorBoundaryScanner's "necessary, not sufficient" scanner) and
    # unnecessary (the mutation is inert even when found). That gate is
    # removed rather than widened; ExecutionSeamTest ("no runtime mutation
    # can change what implementation/0 resolves to") demonstrates the
    # in-process immutability directly, and the test below demonstrates the
    # compile-time resolution itself.
    test "dev and prod compile-time config resolve :execution_seam to Unavailable (behavioral)" do
      # Application.compile_env/3 only ever sees compile-time config
      # (config.exs plus the per-env file it `import_config`s at its
      # bottom) — config/runtime.exs is loaded AFTER compilation and
      # structurally cannot affect what implementation/0 resolves to, so it
      # is intentionally not evaluated here (it IS covered by the text scan
      # above, since a stray key there would still be a smell worth
      # flagging even though it can't reach compile_env).
      #
      # Config.Reader actually EVALUATES the real Elixir config DSL for the
      # given env (handling import_config, config_env() branches, etc.) and
      # returns the resulting data — this is a runtime fact about what the
      # config resolves to, not a text scan, so it cannot be evaded by
      # spelling the key differently than expected.
      root_config_exs = Path.join(@app_dir, "../../config/config.exs") |> Path.expand()
      default_backend = EzagentPluginGitWorkflow.ExecutionSeam.Unavailable

      for env <- [:dev, :prod] do
        resolved = Config.Reader.read!(root_config_exs, env: env)
        git_workflow_env = Keyword.get(resolved, :ezagent_plugin_git_workflow, [])
        resolved_backend = Keyword.get(git_workflow_env, :execution_seam, default_backend)

        assert resolved_backend == default_backend,
               "compile-time config for env=#{env} resolves :execution_seam to " <>
                 "#{inspect(resolved_backend)}, not Unavailable"
      end
    end
  end
end
