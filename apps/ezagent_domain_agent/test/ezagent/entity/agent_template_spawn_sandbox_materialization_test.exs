defmodule Ezagent.Entity.AgentTemplateSpawnSandboxMaterializationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn

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
    assert {:ok, sandbox_slice} = Ezagent.Kind.get_slice(agent_uri, :sandbox)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)

    assert sandbox.config_dir_path =~ "preinit-sandbox-#{unique}/preinit_sandbox"
    assert sandbox.template_class == PreinitializedSandboxTemplate
    assert sandbox.respawn_template_data["agent_config_dir"] == sandbox.config_dir_path
  end
end
