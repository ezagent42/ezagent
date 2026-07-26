defmodule EzagentPluginNative.Integration.NativeFlavorSpawnTest do
  @moduledoc """
  Role-foundation RF-8 — the `native` flavor: the generic, no-engine /
  no-sidecar host for role agents.

  Gates:

    1. A `native`-flavor agent spawns on the UNIFIED `Ezagent.Entity.Agent`
       Kind with NO external engine / sidecar / bridge — just the base Agent
       behavior set; the ROLE supplies extra behaviors per-instance (RF-5a).
    2. native declares NOTHING role-specific: a native instance does NOT
       inherit a sibling flavor's behaviors (no `:curl_agent` slice).
    3. The `native` flavor + its `:cap_policy` are registered in
       `Ezagent.AgentFlavorRegistry`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Kind, KindRegistry}

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  describe "native-flavor agent on Entity.Agent" do
    test "spawns on Entity.Agent with NO engine/sidecar — base behaviors only" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/native_host-#{System.unique_integer([:positive])}"
        )

      # The native Template spawns Entity.Agent with NO explicit :behaviors
      # set — exercise that exact shape. No sidecar/engine is started.
      {:ok, _pid} = Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The base Agent behaviors are present (identity / sandbox / api_keys).
      assert {:ok, _api_keys} = Kind.read(uri, :api_keys, spawn: :never)
      assert {:ok, _sandbox} = Kind.read(uri, :sandbox, spawn: :never)

      # native declares NOTHING role-specific — no sibling flavor's behavior
      # leaks in (curl's :curl_agent slice is absent).
      assert {:ok, nil} = Kind.read(uri, :curl_agent, spawn: :never)

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end

    test "the native Template instantiate/3 spawns Entity.Agent with no engine" do
      name = "native_tmpl-#{System.unique_integer([:positive])}"
      agent_uri = Ezagent.URI.agent("team-alpha", name)

      tmpl = %{
        "class" => "native.agent",
        "agent_uri" => URI.to_string(agent_uri)
      }

      assert {:ok, [^agent_uri], %{fresh?: true}} =
               Ezagent.PluginNative.Template.instantiate(
                 "native.agent",
                 tmpl,
                 Ezagent.URI.workspace("team-alpha")
               )

      wait_until(fn -> Ezagent.ReadyGate.status(agent_uri) == :ready end)
      assert {:ok, _sandbox} = Kind.read(agent_uri, :sandbox, spawn: :never)

      Kind.terminate(agent_uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(agent_uri)) == :error end)
    end
  end

  describe "AgentFlavorRegistry registration" do
    test "the native flavor + its cap_policy are registered" do
      assert {:ok, decl} = Ezagent.AgentFlavorRegistry.lookup("native")
      assert decl.kind == Ezagent.Entity.Agent
      assert decl.template_class == Ezagent.PluginNative.Template
      assert is_function(decl.cap_policy, 1)
      # native declares NO per-instance behavior thunk — the role supplies
      # behaviors per-instance.
      assert decl.instance_behaviors == nil
    end
  end
end
