defmodule EzagentPluginCurlAgent.Integration.CurlFlavorOnAgentTest do
  @moduledoc """
  PR-6 (im/session/agent decomposition §3.5 / §OQ-1, codex HIGH-1) — the
  curl flavor folded into the UNIFIED `Ezagent.Entity.Agent` Kind.

  The architectural gates this PR must hold:

    1. A FRESH curl agent spawns on `Entity.Agent` (NOT the standalone
       `Entity.CurlAgent`) with the curl STATE behavior in its per-instance
       set, so its `:curl_agent` slice materializes.
    2. The curl `:in_process_sync` adapter is registered for the `"curl"`
       flavor and resolves the agent's flavor via the stored attribute.
    3. `agent.receive` is flavor-blind: for the curl `:in_process_sync`
       class it re-dispatches the adapter's result into the curl Behavior's
       `:sync_result` action (the durable persist step), keeping
       `Behavior.Agent.Receive` curl-agnostic.
    4. The legacy `Entity.CurlAgent` Kind + Behavior still resolve (cold-load
       for EXISTING agents; PR-7 migrates them).

  No real DeepSeek HTTP — the no-api-key path is deterministic + network-free
  (`feedback_let_it_crash_no_workarounds`: the REAL contract path, not a
  mock-of-everything; the HTTP wire is covered by ApiClient + scenario 07).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Kind, KindRegistry}
  alias Ezagent.Behavior.Agent.Receive, as: AgentReceive
  alias Ezagent.Message

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

  describe "fresh curl agent on Entity.Agent" do
    test "spawns on Entity.Agent with the curl :curl_agent slice materialized" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_fold-#{System.unique_integer([:positive])}"
        )

      # The curl Template spawns Entity.Agent with the curl per-instance
      # behavior set — exercise that exact spawn shape here.
      {:ok, _pid} =
        Kind.spawn(Ezagent.Entity.Agent, %{
          uri: uri,
          behaviors: Ezagent.Entity.Agent.curl_behaviors(),
          provider: "deepseek",
          model: "deepseek-chat"
        })

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The :curl_agent slice materialized on Entity.Agent (proves the
      # reparented Behavior is in this instance's effective set).
      assert {:ok, curl_slice} = Kind.get_slice(uri, :curl_agent)
      assert curl_slice.provider == "deepseek"
      assert curl_slice.conversation == []

      # The base Agent behaviors are STILL present (api_keys is in the
      # curl set, so curl's credential need is satisfied with no dup).
      assert {:ok, _api_keys} = Kind.get_slice(uri, :api_keys)

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end

    test "a NON-curl Entity.Agent does NOT materialize a :curl_agent slice (no pollution)" do
      # A cc/codex/echo-style agent spawns WITHOUT an explicit :behaviors set
      # → nil :kind_base → `nil_capture_behavior_set/0` = the BASE subset,
      # which EXCLUDES Behavior.CurlAgent. No :curl_agent slice, byte-identical
      # to pre-PR-6.
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_nopollute-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} = Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # No :curl_agent slice materialized — `Behavior.CurlAgent` is NOT in a
      # nil-:kind_base agent's effective set, so the slice is absent (the
      # runtime returns {:ok, nil} for an un-materialized slice key).
      assert {:ok, nil} = Kind.get_slice(uri, :curl_agent)
      # base behaviors still there
      assert {:ok, api_keys} = Kind.get_slice(uri, :api_keys)
      assert is_map(api_keys)

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end

  describe "agent.receive is flavor-blind (re-dispatches the :in_process_sync result)" do
    test "curl flavor → handle_receive emits a {:dispatch, :sync_result} effect carrying the adapter result" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_recv-#{System.unique_integer([:positive])}"
        )

      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")
      sender = Ezagent.URI.new!("entity://team-alpha/user/alice")

      # Spawn the curl agent on Entity.Agent + register the stored curl
      # flavor so AgentBridge picks the :in_process_sync adapter. No key →
      # the adapter returns {:error, {:no_api_key, _}} WITHOUT a network call.
      {:ok, _pid} =
        Kind.spawn(Ezagent.Entity.Agent, %{
          uri: uri,
          behaviors: Ezagent.Entity.Agent.curl_behaviors(),
          provider: "deepseek"
        })

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
      :ok = Ezagent.AgentFlavorAttributes.put(uri, "curl")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(uri) end)

      msg = Message.new(sender, %{text: "hello curl", attachments: []})
      ctx = %{self_uri: uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      # agent.receive runs the adapter inline (in_process_sync) and emits a
      # {:dispatch, %Cmd{action: :sync_result}} effect carrying the result.
      # Call the handler directly (the Invoker support module is private to
      # ezagent_domain_instance_message's test env).
      assert {:ok, %{}, effects} = AgentReceive.handle_receive(%{message: msg}, ctx)

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert [{:dispatch, cmd}] = dispatches
      assert cmd.action == :sync_result
      # The adapter short-circuited on the missing key (no HTTP).
      assert {:error, {:no_api_key, "deepseek"}} = cmd.args.result
      assert cmd.args.user_text == "hello curl"
      assert cmd.args.source_session == session_uri

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end

  describe "legacy Entity.CurlAgent still resolves (PR-7 migrates it)" do
    test "the legacy Kind + Behavior binding survive the fold" do
      # BehaviorRegistry still routes the curl actions on the legacy Kind so
      # EXISTING curl_agent snapshots keep working through the rollback window.
      for action <- Ezagent.Behavior.CurlAgent.actions() do
        assert {:ok, Ezagent.Behavior.CurlAgent} =
                 Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.CurlAgent, action)
      end
    end
  end
end
