defmodule Ezagent.TestSupport.TemplateAgentSpawn do
  @moduledoc false

  alias Ezagent.Entity.{Agent, User}

  @known_flavors %{
    "cc" => %{kind: Ezagent.Entity.Agent, template_class: Ezagent.PluginCc.Template.CcAgent},
    "codex" => %{
      kind: Ezagent.Entity.Agent,
      template_class: Ezagent.PluginCodex.Template.CodexAgent
    },
    # PR-6+7 (curl-as-flavor) — curl resolves to the UNIFIED `Entity.Agent` Kind
    # (the standalone `Entity.CurlAgent` is DELETED); the curl behavior SET is
    # selected per-instance via the `instance_behaviors` thunk. This decl MUST
    # byte-match the curl plugin's `agent_flavors/0` registration (same kind +
    # template_class + the SAME `&Agent.curl_behaviors/0` capture, which compares
    # equal) so re-registering here is idempotent, not a duplicate-flavor clash.
    "curl" => %{
      kind: Agent,
      template_class: Ezagent.PluginCurlAgent.Template,
      instance_behaviors: &Agent.curl_behaviors/0
    },
    "echo" => %{kind: Ezagent.Entity.Echo, template_class: Ezagent.PluginEcho.Template.EchoAgent},
    "np" => %{kind: Ezagent.Entity.NpAgent, template_class: Ezagent.PluginNp.Template.NpAgent},
    "test" => %{kind: Ezagent.Entity.Agent, template_class: Ezagent.TestSupport.NoopAgentTemplate}
  }

  @doc false
  @spec spawn_agent(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent(%URI{} = agent_uri, flavor) when is_binary(flavor) do
    spawn_agent_with_flavor(agent_uri, flavor, [])
  end

  @doc false
  @spec spawn_agent(URI.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent(%URI{} = agent_uri, flavor, opts) when is_binary(flavor) and is_list(opts) do
    spawn_agent_with_flavor(agent_uri, flavor, opts)
  end

  @doc false
  @spec spawn_agent_with_flavor(URI.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent_with_flavor(%URI{} = agent_uri, flavor) when is_binary(flavor) do
    spawn_agent_with_flavor(agent_uri, flavor, [])
  end

  @doc false
  @spec spawn_agent_with_flavor(URI.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent_with_flavor(%URI{} = agent_uri, flavor, opts)
      when is_binary(flavor) and is_list(opts) do
    agent_uri = Ezagent.URI.new!(URI.to_string(agent_uri))
    bootstrap_flavor = bootstrap_flavor()

    with :ok <- ensure_flavor_registered(bootstrap_flavor, noop_decl()),
         :ok <- ensure_target_flavor_registered(flavor),
         {:ok, %{workers: workers}} <-
           Agent.spawn_from_template_content(
             template_content(bootstrap_flavor),
             agent_uri,
             User.admin_uri(),
             workspace_uri!(agent_uri)
           ),
         :ok <- assert_worker_returned(workers, agent_uri),
         :ok <- write_stored_flavor(agent_uri, flavor),
         :ok <- maybe_forget_lineage(agent_uri, opts),
         {:ok, pid} <- Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, pid}
    end
  end

  @doc false
  @spec spawn_agent!(URI.t(), String.t()) :: pid()
  def spawn_agent!(%URI{} = agent_uri, flavor) when is_binary(flavor) do
    {:ok, pid} = spawn_agent(agent_uri, flavor)
    pid
  end

  @doc false
  @spec spawn_agent_with_flavor!(URI.t(), String.t()) :: pid()
  def spawn_agent_with_flavor!(%URI{} = agent_uri, flavor) when is_binary(flavor) do
    {:ok, pid} = spawn_agent_with_flavor(agent_uri, flavor)
    pid
  end

  defp bootstrap_flavor do
    "test_noop_#{System.unique_integer([:positive])}"
  end

  defp template_content(flavor) do
    %{
      name: flavor,
      description: "test-only noop agent fixture",
      flavor: flavor,
      project_cwd: System.tmp_dir!(),
      config_dir: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z]
    }
  end

  defp noop_decl do
    %{kind: Ezagent.Entity.Agent, template_class: Ezagent.TestSupport.NoopAgentTemplate}
  end

  defp ensure_target_flavor_registered(flavor) do
    case Map.fetch(@known_flavors, flavor) do
      {:ok, decl} -> ensure_flavor_registered(flavor, decl)
      :error -> {:error, {:unknown_test_agent_flavor, flavor}}
    end
  end

  defp ensure_flavor_registered(flavor, %{kind: kind, template_class: template_class} = decl) do
    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: kind,
        template_class: template_class,
        # carry the per-instance behavior-set thunk (curl) so the registered
        # value byte-matches the plugin's decl → idempotent re-register; `nil`
        # for the dedicated-Kind flavors (cc/codex/echo/np/test).
        instance_behaviors: Map.get(decl, :instance_behaviors)
      })

    :ok
  end

  defp write_stored_flavor(agent_uri, flavor) do
    %{template_class: template_class} = Map.fetch!(@known_flavors, flavor)
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, flavor)

    _ = Ezagent.ReadyGate.await(agent_uri, 5_000)
    target = Ezagent.URI.with_action(agent_uri, :sandbox, :update_config)

    {:ok, update_cap} =
      Ezagent.Cap.issue_for_action({:admin, User.admin_uri()}, agent_uri, target)

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{
             config_dir_path: nil,
             template_class: template_class,
             respawn_template_data: %{"class" => template_class_name(flavor), "flavor" => flavor}
           },
           ctx: %{
            caller: agent_uri,
            caps: [update_cap],
            reply: {:caller_inbox, self()}
           },
           origin: :trusted_internal
         }) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp template_class_name("cc"), do: "cc.agent"
  defp template_class_name("codex"), do: "codex.agent"
  defp template_class_name("curl"), do: "curl.agent"
  defp template_class_name("echo"), do: "echo.agent"
  defp template_class_name("np"), do: "np.agent"
  defp template_class_name("test"), do: Ezagent.TestSupport.NoopAgentTemplate.template_name()

  defp assert_worker_returned(workers, agent_uri) when is_list(workers) do
    agent_uri_str = URI.to_string(agent_uri)

    if Enum.any?(workers, &(URI.to_string(&1) == agent_uri_str)) do
      :ok
    else
      {:error, {:unexpected_spawned_workers, workers, agent_uri}}
    end
  end

  defp maybe_forget_lineage(agent_uri, opts) do
    if Keyword.get(opts, :lineage?, true) do
      :ok
    else
      Ezagent.AgentLineage.forget(agent_uri)
    end
  end

  defp workspace_uri!(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :agent) do
      Ezagent.URI.entity_workspace_uri(uri)
    else
      raise ArgumentError, "expected entity agent URI, got: #{inspect(uri)}"
    end
  end

  defp workspace_uri!(uri),
    do: raise(ArgumentError, "expected entity agent URI, got: #{inspect(uri)}")
end
