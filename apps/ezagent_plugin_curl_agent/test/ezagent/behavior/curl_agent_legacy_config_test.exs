defmodule Ezagent.Behavior.CurlAgentLegacyConfigTest do
  @moduledoc """
  codex round-2 P2 (PR-6) — the LEGACY cap-axis split for the public
  `:reset_conversation` / `:configure` actions.

  PR-6 reparented `Ezagent.Behavior.CurlAgent` onto the unified
  `Ezagent.Entity.Agent` Kind, pinning its `required_caps/0` to the `:agent`
  axis. The same behavior stays bound on the LEGACY `Ezagent.Entity.CurlAgent`
  Kind through the rollback window — but existing curl agents/users hold
  `:curl_agent` caps there. If the `:agent`-axis behavior owned reset/configure
  on the legacy Kind, a non-wildcard caller who could previously reset/configure
  a legacy curl agent would be DENIED.

  `Ezagent.Behavior.CurlAgentLegacyConfig` restores the `:curl_agent` cap axis
  for those two actions on the legacy Kind ONLY. These tests FAIL if the split
  regresses: if the legacy Kind's reset/configure stops accepting a
  `:curl_agent` cap, or if the unified Kind stops requiring `:agent`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Kind, KindRegistry}
  alias Ezagent.Behavior.{CurlAgent, CurlAgentLegacyConfig}

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

  describe "registry routing (legacy Kind only)" do
    test "{Entity.CurlAgent, :reset_conversation|:configure} → CurlAgentLegacyConfig" do
      assert {:ok, CurlAgentLegacyConfig} =
               Ezagent.BehaviorRegistry.lookup(
                 Ezagent.Entity.CurlAgent,
                 :reset_conversation
               )

      assert {:ok, CurlAgentLegacyConfig} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.CurlAgent, :configure)
    end

    test "the unified Entity.Agent keeps the reparented Behavior.CurlAgent" do
      assert {:ok, CurlAgent} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :reset_conversation)

      assert {:ok, CurlAgent} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :configure)
    end
  end

  describe "cap-axis declarations" do
    test "legacy companion declares :curl_agent caps" do
      caps = CurlAgentLegacyConfig.required_caps()
      assert caps.reset_conversation.kind == :curl_agent
      assert caps.configure.kind == :curl_agent
    end

    test "reparented unified behavior keeps :agent caps" do
      caps = CurlAgent.required_caps()
      assert caps.reset_conversation.kind == :agent
      assert caps.configure.kind == :agent
    end

    test "companion shares the :curl_agent slice and owns exactly reset/configure" do
      assert MapSet.new(CurlAgentLegacyConfig.actions()) ==
               MapSet.new([:reset_conversation, :configure])

      assert CurlAgentLegacyConfig.state_slice() == :curl_agent
    end
  end

  describe "a legacy :curl_agent grant still authorizes reset/configure end-to-end" do
    test "a caller holding ONLY a :curl_agent configure cap can configure a legacy agent" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_legacycfg-#{System.unique_integer([:positive])}"
        )

      caller = Ezagent.URI.new!("entity://team-alpha/user/bob")

      {:ok, _pid} = Kind.spawn(Ezagent.Entity.CurlAgent, %{uri: uri, provider: "deepseek"})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The EXACT cap a pre-fold legacy grant carried: the `:curl_agent` axis.
      # An `:agent`-axis cap would NOT authorize the legacy Kind (proven by the
      # negative test below), so this is a faithful regression of the split.
      legacy_cap =
        Capability.cap(:curl_agent, CurlAgentLegacyConfig, :configure)

      target = Ezagent.URI.with_action(uri, :curl_agent, :configure)

      assert {:ok, %{ok: true}} =
               Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 target: target,
                 mode: :call,
                 args: %{
                   provider: "deepseek",
                   api_url: "https://api.deepseek.com/chat/completions",
                   model: "deepseek-reasoner",
                   system_prompt: "you are a legacy curl agent",
                   max_history: 20
                 },
                 ctx: %{caller: caller, caps: MapSet.new([legacy_cap]), reply: :inline}
               })

      assert {:ok, %{model: "deepseek-reasoner"}} = Kind.get_slice(uri, :curl_agent)

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end

    test "an :agent-axis cap is DENIED on the legacy Kind (the split is load-bearing)" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_legacydeny-#{System.unique_integer([:positive])}"
        )

      caller = Ezagent.URI.new!("entity://team-alpha/user/carol")

      {:ok, _pid} = Kind.spawn(Ezagent.Entity.CurlAgent, %{uri: uri, provider: "deepseek"})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The UNIFIED-path axis. On the legacy Kind the needed cap is
      # `:curl_agent`, so this `:agent` cap must NOT authorize — confirming the
      # split actually distinguishes the two axes (otherwise the positive test
      # could pass trivially).
      agent_axis_cap = Capability.cap(:agent, CurlAgent, :configure)

      target = Ezagent.URI.with_action(uri, :curl_agent, :configure)

      assert {:error, :unauthorized} =
               Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 target: target,
                 mode: :call,
                 args: %{model: "should-not-apply"},
                 ctx: %{caller: caller, caps: MapSet.new([agent_axis_cap]), reply: :inline}
               })

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end
end
