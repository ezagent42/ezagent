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

  describe "self-reply loop guard (codex P2)" do
    test "an agent's OWN message addressed to itself is NOT forwarded to the adapter" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_selfloop-#{System.unique_integer([:positive])}"
        )

      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

      {:ok, _pid} =
        Kind.spawn(Ezagent.Entity.Agent, %{
          uri: uri,
          behaviors: Ezagent.Entity.Agent.curl_behaviors(),
          provider: "deepseek"
        })

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
      :ok = Ezagent.AgentFlavorAttributes.put(uri, "curl")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(uri) end)

      # The echo: a message whose SENDER is this agent's OWN uri (a literal-URI
      # routing rule delivered the agent's own session.send reply back to it).
      self_msg = Message.new(uri, %{text: "this is my own reply", attachments: []})
      ctx = %{self_uri: uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      # Must be ignored — NO {:dispatch, :sync_result} (which would call the
      # upstream LLM API on the agent's own reply → loop).
      assert {:ok, %{ignored: :self_message}, effects} =
               AgentReceive.handle_receive(%{message: self_msg}, ctx)

      assert effects == [],
             "self-message was forwarded to the adapter (loop): #{inspect(effects)}"

      # Sanity: a message from a DIFFERENT sender IS still delivered.
      other = Ezagent.URI.new!("entity://team-alpha/user/alice")
      other_msg = Message.new(other, %{text: "hi from alice", attachments: []})

      assert {:ok, %{}, [{:dispatch, cmd}]} =
               AgentReceive.handle_receive(%{message: other_msg}, ctx)

      assert cmd.action == :sync_result

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end

  describe "curl flavor survives a cold-load (codex P1 — durable, not ETS-only)" do
    test "rehydrated curl agent (snapshot only, ETS gone) still routes :receive to the in_process_sync adapter" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_rehydrate-#{System.unique_integer([:positive])}"
        )

      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")
      sender = Ezagent.URI.new!("entity://team-alpha/user/alice")

      # 1. Fresh spawn on Entity.Agent with the curl per-instance set. The
      #    curl Behavior's create/1 persists `flavor: "curl"` in the durable
      #    :curl_agent slice (snapshot-on-change writes it at init).
      {:ok, pid1} =
        Kind.spawn(Ezagent.Entity.Agent, %{
          uri: uri,
          behaviors: Ezagent.Entity.Agent.curl_behaviors(),
          provider: "deepseek"
        })

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # The durable slice carries the flavor (this is the O-2 stored field).
      assert {:ok, %{flavor: "curl"}} = Kind.get_slice(uri, :curl_agent)

      # 2. Permanently terminate the live process — the snapshot row survives,
      #    and CRUCIALLY delete the ETS launch attribute to SIMULATE a cold
      #    BEAM restart where the ephemeral ETS row is gone. Only the durable
      #    snapshot remains.
      ref = Process.monitor(pid1)
      :ok = Kind.terminate(uri)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 2_000
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
      :ok = Ezagent.AgentFlavorAttributes.delete(uri)
      assert :none = Ezagent.AgentFlavorAttributes.get(uri)

      # 3. Cold-load — re-spawn the same URI WITHOUT re-passing :behaviors (the
      #    persisted kind_base rehydrates the curl set) and WITHOUT re-seeding
      #    the ETS attribute. create/1 is SKIPPED (ever-created); the flavor
      #    comes only from the rehydrated snapshot slice.
      {:ok, pid2} = Kind.spawn(Ezagent.Entity.Agent, %{uri: uri})
      refute pid1 == pid2
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
      assert :none = Ezagent.AgentFlavorAttributes.get(uri)

      # 4. agent.receive MUST resolve :in_process_sync from the durable slice
      #    and re-dispatch the adapter result to :sync_result. If the flavor
      #    were ETS-only it would resolve :none here → the receive would be
      #    treated as :subprocess_ws and silently DROPPED (no {:dispatch, _}).
      msg = Message.new(sender, %{text: "after restart", attachments: []})
      ctx = %{self_uri: uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      assert {:ok, %{}, effects} = AgentReceive.handle_receive(%{message: msg}, ctx)

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))

      assert [{:dispatch, cmd}] = dispatches,
             "rehydrated curl agent dropped its receive (flavor resolved :none from ETS-only) " <>
               "instead of routing to the :in_process_sync adapter"

      assert cmd.action == :sync_result
      assert {:error, {:no_api_key, "deepseek"}} = cmd.args.result
      assert cmd.args.user_text == "after restart"

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
