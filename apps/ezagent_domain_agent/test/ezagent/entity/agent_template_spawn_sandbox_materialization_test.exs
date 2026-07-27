defmodule Ezagent.Entity.AgentTemplateSpawnSandboxMaterializationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn
  alias Ezagent.Entity.Profile
  alias Ezagent.Agent.TemplateOverlayTestBehavior
  alias Ezagent.Kind.Template.PreStart
  alias Ezagent.TestSupport.TemplatePreStartProbe
  alias EzagentDomainAgent.TestSupport.FreshPreStartTemplateClass
  alias EzagentDomainAgent.TestSupport.PreStartTemplateClass
  alias EzagentDomainAgent.TestSupport.ProfileFailureTemplate

  defmodule PreinitializedSandboxTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.preinitialized_sandbox_agent"

    @impl true
    def config_dir_namespace, do: "cc"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
      config_dir = Map.fetch!(data, "allocated_config_dir")

      respawn_data =
        data
        |> Map.put("agent_config_dir", config_dir)
        |> Map.put("flavor", "preinit-sandbox")

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: agent_uri,
             config_dir_path: config_dir,
             template_class: __MODULE__,
             respawn_template_data: respawn_data
           }) do
        {:ok, _pid} ->
          :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)

          {:ok, [agent_uri],
           %{fresh?: true, config_dir_path: config_dir, respawn_template_data: respawn_data}}

        {:error, {:already_started, _pid}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A template that spawns Entity.Agent WITHOUT seeding the `:sandbox` slice in
  # its Kind spawn args (like the real `py`/`np` role agents) — so
  # `sandbox_state_matches?/4` is false and `do_record_sandbox_state/4` takes
  # the FALLBACK dispatch path (the one the go-live fire-and-forget fix touched).
  defmodule FallbackSandboxTemplate do
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "test.fallback_sandbox_agent"

    @impl true
    def config_dir_namespace, do: "cc"

    @impl true
    def validate(_data), do: :ok

    @impl true
    def instantiate(_name, data, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
      config_dir = Map.fetch!(data, "allocated_config_dir")

      respawn_data =
        data
        |> Map.put("agent_config_dir", config_dir)
        |> Map.put("flavor", "fallback-sandbox")

      # No `config_dir_path`/`respawn_template_data` in spawn args → the
      # `:sandbox` slice stays empty → the post-spawn write goes through the
      # fallback dispatch (mirrors the py/np role-agent path).
      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, template_class: __MODULE__}) do
        {:ok, _pid} ->
          :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)

          {:ok, [agent_uri],
           %{fresh?: true, config_dir_path: config_dir, respawn_template_data: respawn_data}}

        {:error, {:already_started, _pid}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [agent_uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  test "fallback sandbox.update_config is fire-and-forget: does NOT block the spawner on a not-ready agent, buffers the write" do
    unique = System.unique_integer([:positive])
    flavor = "fallback-sandbox"
    agent_uri = Ezagent.URI.new!("entity://fallback-sandbox-#{unique}/agent/fallback_sandbox")
    owner_uri = Ezagent.URI.new!("entity://fallback-sandbox-#{unique}/user/owner")
    workspace_uri = Ezagent.URI.new!("workspace://fallback-sandbox-#{unique}")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FallbackSandboxTemplate
      })

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(agent_uri)
      :ok
    end)

    content = %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "fallback-sandbox-source-#{unique}")
    }

    {elapsed_us, result} =
      :timer.tc(fn ->
        TemplateSpawn.spawn_from_template_content(content, agent_uri, owner_uri, workspace_uri)
      end)

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} = result

    # The agent is held at `:not_ready`. Under the OLD blocking path this call
    # sat on `ReadyGate.await(_, 5_000)` for the full 5s; the fire-and-forget
    # `:cast` must return promptly (well under the 5s create-session budget).
    assert elapsed_us < 2_000_000,
           "spawn blocked #{div(elapsed_us, 1000)}ms on a not-ready agent — expected fire-and-forget (<2s)"

    assert Ezagent.ReadyGate.status(agent_uri) == :not_ready

    # The write was not dropped: a `:cast` to the not-ready agent is buffered via
    # PendingDelivery and delivered once the agent flips `:ready`.
    assert Ezagent.PendingDelivery.buffer_size(agent_uri) >= 1,
           "expected the sandbox.update_config cast to be buffered for later delivery"

    # Now DELIVER it (what `ReadyTransition` does when the agent flips `:ready`)
    # and assert it lands WITHOUT crashing the agent Kind. Regression guard: the
    # cast ctx MUST carry `reply: :ignore`, else `Kind.Server.handle_cast`'s
    # unconditional `Invocation.reply/2` raises FunctionClause on the missing
    # `:reply` key and kills the agent — which broke the whole hello install.
    {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri)

    :ready =
      Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
        URI.to_string(agent_uri),
        agent_pid
      )

    # The agent survived the delivery (no reply crash) and the sandbox slice now
    # carries the respawn data (a subsequent `:call` is processed AFTER the cast).
    assert Process.alive?(agent_pid)
    assert Ezagent.PendingDelivery.buffer_size(agent_uri) == 0
    assert {:ok, sandbox_slice} = Ezagent.Kind.read(agent_uri, :sandbox, spawn: :never)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)
    assert sandbox.config_dir_path != nil
    assert is_map(sandbox.respawn_template_data) and map_size(sandbox.respawn_template_data) > 0
  end

  describe "fresh template spawn display profiles" do
    setup do
      # The Session domain owns the production `entity://` resolver that
      # dispatches Agent entities to their host Kind. This child app otherwise
      # only starts Identity's User-only resolver.
      {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)
      :ok
    end

    test "persists unique names only for fresh workers" do
      unique = System.unique_integer([:positive])
      workspace_name = "display-profile-#{unique}"
      flavor = "display-profile-#{unique}"
      first_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      second_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      adopted_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      blank_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      owner_uri = Ezagent.URI.user(workspace_name, "owner")
      workspace_uri = Ezagent.URI.workspace(workspace_name)

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: PreinitializedSandboxTemplate
        })

      case Ezagent.Resource.FsResolver.register_type("cc-agents", %{
             backend_component: "cc-agents",
             authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
           }) do
        :ok ->
          on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type("cc-agents") end)

        {:error, {:already_registered, "cc-agents"}} ->
          :ok
      end

      on_exit(fn ->
        _ = Ezagent.Kind.terminate(first_uri)
        _ = Ezagent.Kind.terminate(second_uri)
        _ = Ezagent.Kind.terminate(adopted_uri)
        _ = Ezagent.Kind.terminate(blank_uri)
        :ok
      end)

      first_content = %{
        "name" => "  front-desk  ",
        flavor: flavor,
        project_cwd: System.tmp_dir!(),
        config_dir: Path.join(System.tmp_dir!(), "display-profile-first-#{unique}")
      }

      second_content = %{
        name: "front-desk",
        flavor: flavor,
        project_cwd: System.tmp_dir!(),
        config_dir: Path.join(System.tmp_dir!(), "display-profile-second-#{unique}")
      }

      adopted_content = %{
        name: "adopted-without-profile",
        flavor: flavor,
        project_cwd: System.tmp_dir!(),
        config_dir: Path.join(System.tmp_dir!(), "display-profile-adopted-#{unique}")
      }

      blank_content = %{
        name: "   ",
        flavor: flavor,
        project_cwd: System.tmp_dir!(),
        config_dir: Path.join(System.tmp_dir!(), "display-profile-blank-#{unique}")
      }

      assert {:ok, %{workers: [^first_uri], fresh?: true}} =
               TemplateSpawn.spawn_from_template_content(
                 first_content,
                 first_uri,
                 owner_uri,
                 workspace_uri
               )

      assert {:ok, %{workers: [^second_uri], fresh?: true}} =
               TemplateSpawn.spawn_from_template_content(
                 second_content,
                 second_uri,
                 owner_uri,
                 workspace_uri
               )

      assert {:error, :agent_uri_already_live} =
               TemplateSpawn.spawn_from_template_content(
                 first_content,
                 first_uri,
                 owner_uri,
                 workspace_uri
               )

      assert {:ok, _pid} =
               Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
                 uri: adopted_uri,
                 behaviors: Ezagent.Entity.Agent.base_behaviors()
               })

      assert Profile.get(adopted_uri) == nil

      assert {:error, :agent_uri_already_live} =
               TemplateSpawn.spawn_from_template_content(
                 adopted_content,
                 adopted_uri,
                 owner_uri,
                 workspace_uri
               )

      assert {:ok, %{workers: [^blank_uri], fresh?: true}} =
               TemplateSpawn.spawn_from_template_content(
                 blank_content,
                 blank_uri,
                 owner_uri,
                 workspace_uri
               )

      assert %Profile{display_name: "front-desk"} = Profile.get(first_uri)
      assert %Profile{display_name: "front-desk-2"} = Profile.get(second_uri)
      assert Profile.get(adopted_uri) == nil
      assert Profile.get(blank_uri) == nil
    end

    test "overlong profile failure rolls back every fresh-spawn artifact" do
      unique = System.unique_integer([:positive])
      workspace_name = "display-profile-failure-#{unique}"
      flavor = "display-profile-failure-#{unique}"
      agent_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      owner_uri = Ezagent.URI.user(workspace_name, "owner")
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      namespace = ProfileFailureTemplate.config_dir_namespace()

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: ProfileFailureTemplate
        })

      resource_type = "#{namespace}-agents"

      case Ezagent.Resource.FsResolver.register_type(resource_type, %{
             backend_component: resource_type,
             authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
           }) do
        :ok ->
          on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(resource_type) end)

        {:error, {:already_registered, ^resource_type}} ->
          :ok
      end

      config_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, namespace)

      on_exit(fn ->
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
        _ = File.rm_rf(config_dir)
        :ok
      end)

      assert {:error, {:agent_display_profile_failed, %Ecto.Changeset{} = changeset}} =
               TemplateSpawn.spawn_from_template_content(
                 %{
                   name: String.duplicate("x", 256),
                   flavor: flavor,
                   project_cwd: System.tmp_dir!(),
                   config_dir: "profile-failure-source"
                 },
                 agent_uri,
                 owner_uri,
                 workspace_uri
               )

      assert "should be at most 255 character(s)" in errors_on(changeset).display_name
      assert :error = Ezagent.KindRegistry.lookup(agent_uri)
      assert :error = Ezagent.AgentLineage.lookup(agent_uri)
      assert :error = Ezagent.WorkspaceRegistry.lookup(agent_uri)
      assert Profile.get(agent_uri) == nil
      refute File.exists?(config_dir)
      assert Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(agent_uri)) == nil

      assert {:error, :creation_attempt_not_found} =
               Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri)

      assert agent_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(owner_uri)
    end

    test "failure after profile insertion rolls back every fresh-spawn artifact" do
      unique = System.unique_integer([:positive])
      workspace_name = "display-profile-post-insert-failure-#{unique}"
      flavor = "display-profile-post-insert-failure-#{unique}"
      agent_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      owner_uri = Ezagent.URI.user(workspace_name, "owner")
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      namespace = ProfileFailureTemplate.config_dir_namespace()

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: ProfileFailureTemplate
        })

      resource_type = "#{namespace}-agents"

      case Ezagent.Resource.FsResolver.register_type(resource_type, %{
             backend_component: resource_type,
             authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
           }) do
        :ok ->
          on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(resource_type) end)

        {:error, {:already_registered, ^resource_type}} ->
          :ok
      end

      config_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, namespace)
      Ezagent.Agent.TestTemplateSpawn.inject(:fail_after_display_profile, self())

      on_exit(fn ->
        Ezagent.Agent.TestTemplateSpawn.clear()
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
        _ = File.rm_rf(config_dir)
        :ok
      end)

      assert {:error, :injected_post_profile_failure} =
               TemplateSpawn.spawn_from_template_content(
                 %{
                   name: "post-insert-profile",
                   flavor: flavor,
                   project_cwd: System.tmp_dir!(),
                   config_dir: "profile-post-insert-failure-source"
                 },
                 agent_uri,
                 owner_uri,
                 workspace_uri
               )

      assert_receive {:template_spawn_after_display_profile, ^agent_uri, :inserted}
      assert :error = Ezagent.KindRegistry.lookup(agent_uri)
      assert :error = Ezagent.AgentLineage.lookup(agent_uri)
      assert :error = Ezagent.WorkspaceRegistry.lookup(agent_uri)
      assert :none = Ezagent.AgentFlavorAttributes.get(agent_uri)
      assert Profile.get(agent_uri) == nil
      refute File.exists?(config_dir)
      assert Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(agent_uri)) == nil

      assert {:error, :creation_attempt_not_found} =
               Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri)

      assert agent_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(owner_uri)
    end

    test "failure after finding a pre-existing same-URI profile preserves it" do
      unique = System.unique_integer([:positive])
      workspace_name = "display-profile-pre-existing-#{unique}"
      flavor = "display-profile-pre-existing-#{unique}"
      agent_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      owner_uri = Ezagent.URI.user(workspace_name, "owner")
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      namespace = ProfileFailureTemplate.config_dir_namespace()

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: ProfileFailureTemplate
        })

      resource_type = "#{namespace}-agents"

      case Ezagent.Resource.FsResolver.register_type(resource_type, %{
             backend_component: resource_type,
             authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
           }) do
        :ok ->
          on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(resource_type) end)

        {:error, {:already_registered, ^resource_type}} ->
          :ok
      end

      assert {:ok, %Profile{display_name: "preserved"} = existing_profile} =
               Profile.ensure_agent_display_name(agent_uri, "preserved")

      config_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, namespace)
      Ezagent.Agent.TestTemplateSpawn.inject(:fail_after_display_profile, self())

      on_exit(fn ->
        Ezagent.Agent.TestTemplateSpawn.clear()
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
        _ = File.rm_rf(config_dir)
        :ok
      end)

      assert {:error, :injected_post_profile_failure} =
               TemplateSpawn.spawn_from_template_content(
                 %{
                   name: "must-not-overwrite",
                   flavor: flavor,
                   project_cwd: System.tmp_dir!(),
                   config_dir: "profile-pre-existing-failure-source"
                 },
                 agent_uri,
                 owner_uri,
                 workspace_uri
               )

      assert_receive {:template_spawn_after_display_profile, ^agent_uri, :exists}
      assert :error = Ezagent.KindRegistry.lookup(agent_uri)
      assert :error = Ezagent.AgentLineage.lookup(agent_uri)
      assert :error = Ezagent.WorkspaceRegistry.lookup(agent_uri)
      assert :none = Ezagent.AgentFlavorAttributes.get(agent_uri)
      assert Profile.get(agent_uri) == existing_profile
      refute File.exists?(config_dir)
      assert Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(agent_uri)) == nil

      assert {:error, :creation_attempt_not_found} =
               Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri)

      assert agent_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(owner_uri)
    end

    test "profile failure preserves an exact pre-existing lineage fact" do
      unique = System.unique_integer([:positive])
      workspace_name = "display-profile-existing-lineage-#{unique}"
      flavor = "display-profile-existing-lineage-#{unique}"
      agent_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
      owner_uri = Ezagent.URI.user(workspace_name, "owner")
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      namespace = ProfileFailureTemplate.config_dir_namespace()

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: ProfileFailureTemplate
        })

      resource_type = "#{namespace}-agents"

      case Ezagent.Resource.FsResolver.register_type(resource_type, %{
             backend_component: resource_type,
             authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
           }) do
        :ok ->
          on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(resource_type) end)

        {:error, {:already_registered, ^resource_type}} ->
          :ok
      end

      config_dir = Ezagent.Sandbox.ConfigDir.path(agent_uri, namespace)

      on_exit(fn ->
        _ = Ezagent.Kind.terminate(agent_uri)
        _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
        _ = Ezagent.AgentLineage.forget(agent_uri)
        _ = File.rm_rf(config_dir)
        :ok
      end)

      assert :ok = Ezagent.AgentLineage.record(agent_uri, owner_uri)
      assert {:ok, ^owner_uri} = Ezagent.AgentLineage.lookup(agent_uri)
      assert agent_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(owner_uri)

      assert {:error, {:agent_display_profile_failed, %Ecto.Changeset{}}} =
               TemplateSpawn.spawn_from_template_content(
                 %{
                   name: String.duplicate("x", 256),
                   flavor: flavor,
                   project_cwd: System.tmp_dir!(),
                   config_dir: "profile-failure-existing-lineage-source"
                 },
                 agent_uri,
                 owner_uri,
                 workspace_uri
               )

      assert :error = Ezagent.KindRegistry.lookup(agent_uri)
      assert {:ok, ^owner_uri} = Ezagent.AgentLineage.lookup(agent_uri)
      assert agent_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(owner_uri)
    end
  end

  test "spawn skips sandbox.update_config dispatch when sandbox was initialized by Kind spawn args" do
    unique = System.unique_integer([:positive])
    flavor = "preinit-sandbox"
    agent_uri = Ezagent.URI.new!("entity://preinit-sandbox-#{unique}/agent/preinit_sandbox")
    owner_uri = Ezagent.URI.new!("entity://preinit-sandbox-#{unique}/user/owner")
    workspace_uri = Ezagent.URI.new!("workspace://preinit-sandbox-#{unique}")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: PreinitializedSandboxTemplate
      })

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(agent_uri)
      :ok
    end)

    content = %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "preinit-sandbox-source-#{unique}")
    }

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             TemplateSpawn.spawn_from_template_content(
               content,
               agent_uri,
               owner_uri,
               workspace_uri
             )

    assert Ezagent.ReadyGate.status(agent_uri) == :not_ready
    assert {:ok, sandbox_slice} = Ezagent.Kind.read(agent_uri, :sandbox, spawn: :never)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)

    assert sandbox.config_dir_path =~ "preinit-sandbox-#{unique}/preinit_sandbox"
    assert sandbox.template_class == PreinitializedSandboxTemplate
    assert sandbox.respawn_template_data["agent_config_dir"] == sandbox.config_dir_path
  end

  test "same-URI spawn rejects an adopted worker without changing its state" do
    unique = System.unique_integer([:positive])
    workspace_name = "same-uri-adopted-#{unique}"
    flavor = "same-uri-adopted-new-#{unique}"
    original_flavor = "same-uri-adopted-original-#{unique}"
    instance_uri = Ezagent.URI.agent(workspace_name, Ecto.UUID.generate())
    owner_uri = Ezagent.URI.user(workspace_name, "owner")
    original_owner_uri = Ezagent.URI.user(workspace_name, "original-owner")
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    original_workspace_uri = Ezagent.URI.workspace("same-uri-original-#{unique}")
    original_config_dir = Path.join(System.tmp_dir!(), "same-uri-original-config-#{unique}")

    original_respawn_data = %{
      "agent_config_dir" => original_config_dir,
      "flavor" => original_flavor
    }

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: PreinitializedSandboxTemplate
      })

    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: instance_uri,
               config_dir_path: original_config_dir,
               template_class: PreinitializedSandboxTemplate,
               respawn_template_data: original_respawn_data
             })

    :ok = Ezagent.AgentFlavorAttributes.put(instance_uri, original_flavor)
    :ok = Ezagent.AgentLineage.record(instance_uri, original_owner_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(instance_uri, original_workspace_uri)

    assert {:ok, %Profile{} = original_profile} =
             Profile.ensure_agent_display_name(instance_uri, "original same-uri profile")

    assert {:ok, original_grant} =
             Ezagent.Credential.GrantRow.insert(%{
               agent_uri: URI.to_string(instance_uri),
               credential_source_uri: URI.to_string(original_owner_uri),
               approved_by: URI.to_string(original_owner_uri),
               approved_scope: URI.to_string(original_owner_uri),
               version: 1
             })

    assert {:ok, original_sandbox_slice} = Ezagent.Kind.read(instance_uri, :sandbox, spawn: :never)
    original_sandbox = Ezagent.Kind.normalize_slice_view(original_sandbox_slice)

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(instance_uri)
      _ = Ezagent.AgentFlavorAttributes.delete(instance_uri)
      _ = Ezagent.AgentLineage.forget(instance_uri)
      _ = Ezagent.WorkspaceRegistry.unbind(instance_uri)
      _ = Ezagent.Credential.GrantRow.delete(URI.to_string(instance_uri))
      :ok
    end)

    content = %{
      name: "must-not-replace-original-profile",
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "same-uri-adopted-source-#{unique}")
    }

    assert {:error, :agent_uri_already_live} =
             TemplateSpawn.spawn_from_template_content(
               content,
               instance_uri,
               owner_uri,
               workspace_uri,
               []
             )

    assert {:ok, ^original_flavor} = Ezagent.AgentFlavorAttributes.get(instance_uri)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(instance_uri)
    assert {:ok, ^original_owner_uri} = Ezagent.AgentLineage.lookup(instance_uri)
    assert {:ok, ^original_workspace_uri} = Ezagent.WorkspaceRegistry.lookup(instance_uri)

    assert instance_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(
             original_owner_uri
           )

    refute instance_uri in Ezagent.Provenance.DerivationEdges.ownership_descendants(owner_uri)
    assert Profile.get(instance_uri) == original_profile

    assert {:ok, sandbox_slice} = Ezagent.Kind.read(instance_uri, :sandbox, spawn: :never)
    assert Ezagent.Kind.normalize_slice_view(sandbox_slice) == original_sandbox

    assert Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(instance_uri)) ==
             original_grant
  end

  test "behavior_overlay mounts only for fresh template-spawned workers" do
    unique = System.unique_integer([:positive])
    flavor = "overlay-fresh"
    agent_uri = Ezagent.URI.new!("entity://overlay-fresh-#{unique}/agent/overlay_fresh")
    owner_uri = Ezagent.URI.new!("entity://overlay-fresh-#{unique}/user/owner")
    workspace_uri = Ezagent.URI.new!("workspace://overlay-fresh-#{unique}")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FallbackSandboxTemplate
      })

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(agent_uri)
      :ok
    end)

    content = %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "overlay-fresh-source-#{unique}")
    }

    assert {:ok, %{workers: [^agent_uri], fresh?: true}} =
             TemplateSpawn.spawn_from_template_content(
               content,
               agent_uri,
               owner_uri,
               workspace_uri,
               behavior_overlay: [TemplateOverlayTestBehavior]
             )

    assert {:ok, %{pinged: false}} =
             Ezagent.Kind.read(agent_uri, :template_overlay_test, spawn: :never)
  end

  test "behavior_overlay does not retrofit adopted workers" do
    unique = System.unique_integer([:positive])
    flavor = "overlay-adopted"
    agent_uri = Ezagent.URI.new!("entity://overlay-adopted-#{unique}/agent/overlay_adopted")
    owner_uri = Ezagent.URI.new!("entity://overlay-adopted-#{unique}/user/owner")
    workspace_uri = Ezagent.URI.new!("workspace://overlay-adopted-#{unique}")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FallbackSandboxTemplate
      })

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: agent_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(agent_uri)
      :ok
    end)

    content = %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "overlay-adopted-source-#{unique}")
    }

    assert {:error, :agent_uri_already_live} =
             TemplateSpawn.spawn_from_template_content(
               content,
               agent_uri,
               owner_uri,
               workspace_uri,
               behavior_overlay: [TemplateOverlayTestBehavior]
             )

    assert {:ok, nil} = Ezagent.Kind.read(agent_uri, :template_overlay_test, spawn: :never)
  end

  test "behavior_overlay mount failure rolls back the fresh worker" do
    unique = System.unique_integer([:positive])
    flavor = "overlay-invalid"
    agent_uri = Ezagent.URI.new!("entity://overlay-invalid-#{unique}/agent/overlay_invalid")
    owner_uri = Ezagent.URI.new!("entity://overlay-invalid-#{unique}/user/owner")
    workspace_uri = Ezagent.URI.new!("workspace://overlay-invalid-#{unique}")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FallbackSandboxTemplate
      })

    content = %{
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: Path.join(System.tmp_dir!(), "overlay-invalid-source-#{unique}")
    }

    assert {:error,
            {:behavior_overlay_mount_failed, ^agent_uri, String, {:not_a_behavior, String}}} =
             TemplateSpawn.spawn_from_template_content(
               content,
               agent_uri,
               owner_uri,
               workspace_uri,
               behavior_overlay: [String]
             )

    assert wait_until_deregistered(agent_uri)
  end

  describe "trusted pre-start option" do
    setup do
      unique = System.unique_integer([:positive])
      flavor = "pre-start-#{unique}"
      Application.put_env(:ezagent_core, :template_pre_start_test_owner, self())
      Application.delete_env(:ezagent_core, :template_pre_start_complete_result)
      Application.put_env(:ezagent_domain_agent, :pre_start_test_owner, self())
      :ok = PreStart.replace_for_test(TemplatePreStartProbe)

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: PreStartTemplateClass
        })

      Application.put_env(
        :ezagent_core,
        :template_pre_start_prepare_result,
        {:ok, %{cwd: "/safe/task", claim: "claim-one", launch_context: make_ref()}}
      )

      on_exit(fn ->
        :ok = PreStart.replace_for_test(nil)
        Application.delete_env(:ezagent_core, :template_pre_start_test_owner)
        Application.delete_env(:ezagent_core, :template_pre_start_prepare_result)
        Application.delete_env(:ezagent_core, :template_pre_start_complete_result)
        Application.delete_env(:ezagent_domain_agent, :pre_start_test_owner)
        Application.delete_env(:ezagent_domain_agent, :pre_start_test_mode)
      end)

      %{
        content: %{flavor: flavor, project_cwd: "/authored/cwd"},
        instance_uri: Ezagent.URI.agent("pre-start-#{unique}", "worker"),
        owner_uri: Ezagent.URI.user("pre-start-#{unique}", "owner"),
        workspace_uri: Ezagent.URI.workspace("pre-start-#{unique}")
      }
    end

    test "preparation failure prevents instantiate", fixture do
      Application.put_env(
        :ezagent_core,
        :template_pre_start_prepare_result,
        {:error, :workspace_not_ready}
      )

      assert {:error, :workspace_not_ready} = spawn_with_reference(fixture)
      refute_receive {:instantiate_called, _}
      refute_receive {:pre_start_complete, _, _}
    end

    test "missing implementation fails closed before instantiate", fixture do
      :ok = PreStart.replace_for_test(nil)

      assert {:error, :template_pre_start_not_registered} = spawn_with_reference(fixture)
      refute_receive {:instantiate_called, _}
    end

    test "prepared launch context requires instantiate/4 before template effects", fixture do
      prepare_success()
      flavor = "missing-launch-context-#{System.unique_integer([:positive])}"

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: EzagentDomainAgent.TestSupport.MissingLaunchContextTemplateClass
        })

      assert {:error, :template_launch_context_not_supported} =
               spawn_with_reference(%{fixture | content: %{fixture.content | flavor: flavor}})

      refute_receive :missing_arity_effect

      assert_receive {:pre_start_complete, "claim-one",
                      {:error, :template_launch_context_not_supported}}
    end

    test "adopted pre-start rejects before overwriting flavor metadata",
         fixture do
      prepare_success()
      :ok = Ezagent.AgentFlavorAttributes.put(fixture.instance_uri, "preexisting-flavor")

      assert {:error, :agent_uri_already_live} = spawn_with_reference(fixture)
      # #201 PR-2 — the instantiate-time flavor read is the attempt's OWN
      # data flavor (authored by to_template_data), never the global ETS row…
      assert_receive {:flavor_during_instantiate, {:ok, flavor}}
      assert flavor == fixture.content.flavor
      assert_receive {:instantiate_called, data}
      assert data["cwd"] == "/safe/task"
      refute Map.has_key?(fixture.content, :pre_start_ref)
      refute Map.has_key?(data, "pre_start_ref")
      # …while the PRE-EXISTING global row is left exactly as it was: a
      # losing/adopt attempt performs ZERO creation-state mutations.
      assert {:ok, "preexisting-flavor"} = Ezagent.AgentFlavorAttributes.get(fixture.instance_uri)

      assert_receive {:pre_start_complete, "claim-one", {:error, :agent_uri_already_live}}
    end

    test "instantiate error completes exactly once", fixture do
      prepare_success()
      Application.put_env(:ezagent_domain_agent, :pre_start_test_mode, :error)

      assert {:error, :instantiate_failed} = spawn_with_reference(fixture)
      assert_receive {:pre_start_complete, "claim-one", {:error, :instantiate_failed}}
      refute_receive {:pre_start_complete, _, _}
    end

    test "claimed fresh without an actor-init receipt fails before completion starts it",
         fixture do
      Application.put_env(
        :ezagent_core,
        :template_pre_start_prepare_result,
        {:ok,
         %{
           cwd: "/safe/task",
           claim: "claim-one",
           creation_attempt_id: Ecto.UUID.generate(),
           launch_context: make_ref()
         }}
      )

      Application.put_env(:ezagent_domain_agent, :pre_start_test_mode, :claimed_fresh)

      assert {:error, :ownership_receipt_missing} = spawn_with_reference(fixture)
      assert :error = Ezagent.KindRegistry.lookup(fixture.instance_uri)
      assert_receive {:pre_start_complete, "claim-one", {:error, :ownership_receipt_missing}}
      refute_receive {:pre_start_complete, _, _}
    end

    test "instantiate raise and exit both complete exactly once before propagating", fixture do
      for {mode, expected_kind} <- [raise: :error, exit: :exit] do
        prepare_success()
        Application.put_env(:ezagent_domain_agent, :pre_start_test_mode, mode)
        test_pid = self()

        Application.put_env(:ezagent_core, :template_pre_start_complete_result, fn ->
          send(test_pid, {:completion_failure_attempted, mode})

          case mode do
            :raise -> raise "completion raised"
            :exit -> exit(:completion_exited)
          end
        end)

        {caught_kind, caught_reason, caught_stacktrace} =
          try do
            spawn_with_reference(fixture)
            :not_raised
          catch
            kind, reason -> {kind, reason, __STACKTRACE__}
          end

        assert caught_kind == expected_kind

        case mode do
          :raise -> assert %RuntimeError{message: "instantiate raised"} = caught_reason
          :exit -> assert caught_reason == :instantiate_exited
        end

        assert Enum.any?(caught_stacktrace, fn
                 {PreStartTemplateClass, :instantiate_with_opts, 1, _location} -> true
                 _frame -> false
               end)

        assert_receive {:pre_start_complete, "claim-one", {:error, {^expected_kind, _reason}}}
        assert_receive {:completion_failure_attempted, ^mode}
        refute_receive {:completion_failure_attempted, ^mode}
        refute_receive {:pre_start_complete, _, _}
      end
    end

    test "no reference preserves the existing path without consulting the gate", fixture do
      assert {:error, :agent_uri_already_live} =
               TemplateSpawn.spawn_from_template_content(
                 fixture.content,
                 fixture.instance_uri,
                 fixture.owner_uri,
                 fixture.workspace_uri,
                 []
               )

      assert_receive {:instantiate_called, %{"cwd" => "/authored/cwd"}}
      refute_receive {:pre_start_prepare, _}
      refute_receive {:pre_start_complete, _, _}
    end
  end

  describe "trusted pre-start fresh lifecycle" do
    setup do
      unique = System.unique_integer([:positive])
      flavor = "fresh-pre-start-#{unique}"
      worker = Ezagent.URI.agent("fresh-pre-start-#{unique}", "worker")
      spawned_by = Ezagent.URI.user("fresh-pre-start-#{unique}", "owner")
      workspace = Ezagent.URI.workspace("fresh-pre-start-#{unique}")

      Application.put_env(:ezagent_core, :template_pre_start_test_owner, self())
      Application.delete_env(:ezagent_core, :template_pre_start_complete_result)
      Application.put_env(:ezagent_domain_agent, :fresh_pre_start_owner, self())
      :ok = PreStart.replace_for_test(TemplatePreStartProbe)

      :ok =
        Ezagent.AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: FreshPreStartTemplateClass
        })

      on_exit(fn ->
        _ = Ezagent.Kind.terminate(worker)
        :ok = PreStart.replace_for_test(nil)
        Application.delete_env(:ezagent_core, :template_pre_start_test_owner)
        Application.delete_env(:ezagent_core, :template_pre_start_prepare_result)
        Application.delete_env(:ezagent_core, :template_pre_start_complete_result)
        Application.delete_env(:ezagent_domain_agent, :fresh_pre_start_owner)
      end)

      %{
        content: %{flavor: flavor, project_cwd: "/authored/cwd"},
        instance_uri: worker,
        owner_uri: spawned_by,
        workspace_uri: workspace
      }
    end

    test "completion observes every helper-owned fresh-spawn obligation", fixture do
      prepare_legacy_success()
      worker = fixture.instance_uri
      spawned_by = fixture.owner_uri
      workspace = fixture.workspace_uri

      Application.put_env(:ezagent_core, :template_pre_start_complete_result, fn ->
        assert {:ok, _attempt} =
                 Ezagent.Agent.CreationInventory.find_attempt(worker, workspace)

        assert {:ok, ^spawned_by} = Ezagent.AgentLineage.lookup(worker)
        assert {:ok, ^workspace} = Ezagent.WorkspaceRegistry.lookup(worker)
        assert {:ok, _flavor} = Ezagent.AgentFlavorAttributes.get(worker)
        :ok
      end)

      assert {:ok, %{workers: [^worker], fresh?: true}} = spawn_with_reference(fixture)
      assert_receive {:instantiate_called, ^worker}

      assert_receive {:pre_start_complete, "claim-one",
                      {:ok, %{workers: [^worker], fresh?: true}}}

      refute_receive {:pre_start_complete, _, _}
    end

    test "successful-spawn completion error is returned without rolling back", fixture do
      prepare_legacy_success()
      worker = fixture.instance_uri
      owner = fixture.owner_uri
      workspace = fixture.workspace_uri
      Application.put_env(:ezagent_core, :template_pre_start_complete_result, {:error, :rejected})

      assert {:error, :rejected} = spawn_with_reference(fixture)
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(worker)
      assert {:ok, ^owner} = Ezagent.AgentLineage.lookup(worker)
      assert {:ok, ^workspace} = Ezagent.WorkspaceRegistry.lookup(worker)
      assert_receive {:pre_start_complete, "claim-one", {:ok, %{workers: [^worker]}}}
      refute_receive {:pre_start_complete, _, _}
    end

    test "post-spawn failure completes once after the existing rollback", fixture do
      prepare_legacy_success()
      worker = fixture.instance_uri

      Application.put_env(:ezagent_core, :template_pre_start_complete_result, fn ->
        assert :error = Ezagent.KindRegistry.lookup(worker)
        assert :error = Ezagent.AgentLineage.lookup(worker)
        assert :error = Ezagent.WorkspaceRegistry.lookup(worker)

        assert {:ok, attempt_id} =
                 Ezagent.Agent.CreationInventory.find_attempt(worker, fixture.workspace_uri)

        assert {:ok, _receipt} =
                 Ezagent.Agent.CreationInventory.exact(
                   attempt_id,
                   worker,
                   fixture.owner_uri,
                   fixture.workspace_uri
                 )

        assert :none = Ezagent.AgentFlavorAttributes.get(worker)
        :ok
      end)

      assert {:error,
              {:behavior_overlay_mount_failed, ^worker, String, {:not_a_behavior, String}}} =
               TemplateSpawn.spawn_from_template_content(
                 fixture.content,
                 worker,
                 fixture.owner_uri,
                 fixture.workspace_uri,
                 pre_start_ref: %{opaque: :reference},
                 behavior_overlay: [String]
               )

      assert_receive {:pre_start_complete, "claim-one",
                      {:error,
                       {:behavior_overlay_mount_failed, ^worker, String,
                        {:not_a_behavior, String}}}}

      refute_receive {:pre_start_complete, _, _}
    end
  end

  defp spawn_with_reference(fixture) do
    TemplateSpawn.spawn_from_template_content(
      fixture.content,
      fixture.instance_uri,
      fixture.owner_uri,
      fixture.workspace_uri,
      pre_start_ref: %{opaque: :reference}
    )
  end

  defp prepare_success do
    Application.put_env(
      :ezagent_core,
      :template_pre_start_prepare_result,
      {:ok, %{cwd: "/safe/task", claim: "claim-one", launch_context: make_ref()}}
    )
  end

  defp prepare_legacy_success do
    Application.put_env(
      :ezagent_core,
      :template_pre_start_prepare_result,
      {:ok, %{cwd: "/safe/task", claim: "claim-one"}}
    )
  end

  defp wait_until_deregistered(uri, attempts \\ 50)
  defp wait_until_deregistered(_uri, 0), do: false

  defp wait_until_deregistered(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        true

      {:ok, _pid} ->
        Process.sleep(10)
        wait_until_deregistered(uri, attempts - 1)
    end
  end
end
