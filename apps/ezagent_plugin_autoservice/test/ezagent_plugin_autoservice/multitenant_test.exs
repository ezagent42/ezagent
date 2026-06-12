defmodule EzagentPluginAutoservice.MultitenantTest do
  @moduledoc """
  Multi-tenant isolation proof — two tenants provisioned in one test env.

  Covers:
  1. Session URIs are tenant-namespaced (cinnox vs acme).
  2. Message written to cinnox session does NOT appear in acme customer feed.
  3. Routing rows are session-scoped (matcher carries the specific session URI).
  4. Alice (cinnox customer) holds NO cap scoped to acme's workspace.

  All tests use `create_agents: false` to avoid spawning real AI agents.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Identity
  alias Ezagent.Socialware.CustomerFeed
  alias Ezagent.Invocation
  alias EzagentPluginAutoservice.{Assembly, TurnDriver}

  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  defp priv_ctx do
    %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end

  # ---------------------------------------------------------------------------
  # Setup: provision two distinct tenants
  # ---------------------------------------------------------------------------

  setup do
    suffix = System.unique_integer([:positive])
    cinnox_tid = "cinnox-#{suffix}"
    acme_tid = "acme-#{suffix}"

    ctx = priv_ctx()

    assert {:ok, cinnox_result} =
             Assembly.provision_session(cinnox_tid, "alice", ctx, create_agents: false)

    assert {:ok, acme_result} =
             Assembly.provision_session(acme_tid, "bob", ctx, create_agents: false)

    cinnox_ws = Ezagent.URI.workspace(cinnox_tid)
    acme_ws = Ezagent.URI.workspace(acme_tid)

    cinnox_token =
      Ezagent.Socialware.CustomerAuth.issue_token(
        cinnox_result.session_uri,
        cinnox_ws
      )

    acme_token =
      Ezagent.Socialware.CustomerAuth.issue_token(
        acme_result.session_uri,
        acme_ws
      )

    %{
      cinnox_tid: cinnox_tid,
      acme_tid: acme_tid,
      cinnox_result: cinnox_result,
      acme_result: acme_result,
      cinnox_ws: cinnox_ws,
      acme_ws: acme_ws,
      cinnox_token: cinnox_token,
      acme_token: acme_token,
      ctx: ctx
    }
  end

  # ---------------------------------------------------------------------------
  # 1. Session URIs are under distinct workspaces
  # ---------------------------------------------------------------------------

  describe "session URI isolation" do
    test "alice's session is under cinnox, bob's under acme", %{
      cinnox_tid: cinnox_tid,
      acme_tid: acme_tid,
      cinnox_result: cinnox_result,
      acme_result: acme_result
    } do
      alice_session = cinnox_result.session_uri
      bob_session = acme_result.session_uri

      # Alice's session is under cinnox
      assert URI.to_string(alice_session) == "session://#{cinnox_tid}/cs/alice",
             "alice session URI should be session://#{cinnox_tid}/cs/alice; " <>
               "got: #{URI.to_string(alice_session)}"

      # Bob's session is under acme
      assert URI.to_string(bob_session) == "session://#{acme_tid}/cs/bob",
             "bob session URI should be session://#{acme_tid}/cs/bob; " <>
               "got: #{URI.to_string(bob_session)}"

      # They are distinct
      refute alice_session == bob_session
    end

    test "customer URIs are under distinct workspaces", %{
      cinnox_tid: cinnox_tid,
      acme_tid: acme_tid,
      cinnox_result: cinnox_result,
      acme_result: acme_result
    } do
      alice_uri = cinnox_result.customer_uri
      bob_uri = acme_result.customer_uri

      assert URI.to_string(alice_uri) == "entity://#{cinnox_tid}/user/alice"
      assert URI.to_string(bob_uri) == "entity://#{acme_tid}/user/bob"
      refute alice_uri == bob_uri
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Message isolation — alice's message does not appear in bob's feed
  # ---------------------------------------------------------------------------

  describe "message isolation" do
    test "message sent into alice's session does not appear in bob's CustomerFeed", %{
      cinnox_result: cinnox_result,
      acme_result: acme_result,
      acme_token: acme_token,
      ctx: ctx
    } do
      alice_session = cinnox_result.session_uri
      bob_session = acme_result.session_uri

      # Drive a turn via alice's orchestrator (simulates a customer message
      # arriving, then operator settling it to make it customer_visible).
      trigger = %{
        message_id: "mt-msg-#{System.unique_integer([:positive])}",
        text: "alice says hi"
      }

      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(alice_session, trigger, ctx)
      assert {:ok, _} = TurnDriver.compose(alice_session, turn_id, "alice says hi", ctx)
      assert {:ok, _} = TurnDriver.settle(alice_session, turn_id, ctx)

      # Give async settlement time
      Process.sleep(50)

      # Bob's CustomerFeed must NOT contain alice's message
      assert {:ok, bob_snapshot} = CustomerFeed.snapshot(bob_session, acme_token)

      refute Enum.any?(bob_snapshot.messages, &message_text?(&1, "alice says hi")),
             "bob's CustomerFeed must not contain alice's message; " <>
               "got: #{inspect(Enum.map(bob_snapshot.messages, & &1.body))}"
    end

    test "operator_claim on cinnox does not affect acme CustomerFeed", %{
      cinnox_result: cinnox_result,
      acme_result: acme_result,
      acme_token: acme_token,
      ctx: ctx
    } do
      alice_session = cinnox_result.session_uri
      alice_orch_uri = cinnox_result.orchestrator_uri
      bob_session = acme_result.session_uri

      orch_base = URI.to_string(alice_orch_uri)
      operator_uri = Ezagent.URI.user("cinnox-op-#{System.unique_integer([:positive])}", "op")

      trigger = %{
        message_id: "mt-op-#{System.unique_integer([:positive])}",
        text: "help from cinnox operator"
      }

      assert {:ok, %{turn_id: _}} = TurnDriver.open(alice_session, trigger, ctx)

      operator_claim_target =
        Ezagent.URI.new!(orch_base <> "?action=cs_orchestrator.operator_claim")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_claim_target,
                 mode: :call,
                 args: %{
                   turn_id: "ignored",
                   operator_text: "cinnox operator exclusive reply",
                   operator_uri: URI.to_string(operator_uri)
                 },
                 ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
               })

      # Settle the operator turn
      state = read_orchestrator_state(alice_orch_uri)
      new_turn_id = state[:open_turn_id]

      if is_binary(new_turn_id) do
        operator_settle_target =
          Ezagent.URI.new!(orch_base <> "?action=cs_orchestrator.operator_settle")

        assert {:ok, %{ok: true}} =
                 Invocation.dispatch(%Invocation{
                   target: operator_settle_target,
                   mode: :call,
                   args: %{turn_id: new_turn_id},
                   ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
                 })

        Process.sleep(50)
      end

      # Bob's CustomerFeed must NOT contain cinnox operator's message
      assert {:ok, bob_snap} = CustomerFeed.snapshot(bob_session, acme_token)

      refute Enum.any?(bob_snap.messages, &message_text?(&1, "cinnox operator exclusive reply")),
             "bob's CustomerFeed must not contain cinnox operator message; " <>
               "got: #{inspect(Enum.map(bob_snap.messages, & &1.body))}"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Routing row isolation — matcher carries specific session URI
  # ---------------------------------------------------------------------------

  describe "routing isolation" do
    test "acme's routing matcher never matches cinnox sessions", %{
      cinnox_result: cinnox_result,
      acme_result: acme_result
    } do
      alice_session_str = URI.to_string(cinnox_result.session_uri)
      bob_session_str = URI.to_string(acme_result.session_uri)
      acme_orch_str = URI.to_string(acme_result.orchestrator_uri)

      rules = Ezagent.Routing.RuleStore.list(@routing_table)

      # Find the routing rule for acme's orchestrator
      acme_rules = Enum.filter(rules, fn r -> acme_orch_str in (r.receivers || []) end)

      assert length(acme_rules) >= 1,
             "expected at least one routing rule for acme orchestrator #{acme_orch_str}"

      # Verify acme's matcher carries the acme session URI (not cinnox)
      Enum.each(acme_rules, fn rule ->
        matcher_str =
          case rule.matcher_data do
            s when is_binary(s) -> s
            m when is_map(m) -> Jason.encode!(m)
          end

        assert String.contains?(matcher_str, bob_session_str),
               "acme routing rule matcher should reference bob's session #{bob_session_str}; " <>
                 "got: #{matcher_str}"

        refute String.contains?(matcher_str, alice_session_str),
               "acme routing rule matcher must NOT reference alice's session #{alice_session_str}; " <>
                 "got: #{matcher_str}"
      end)
    end

    test "cinnox's routing matcher never matches acme sessions", %{
      cinnox_result: cinnox_result,
      acme_result: acme_result
    } do
      alice_session_str = URI.to_string(cinnox_result.session_uri)
      bob_session_str = URI.to_string(acme_result.session_uri)
      cinnox_orch_str = URI.to_string(cinnox_result.orchestrator_uri)

      rules = Ezagent.Routing.RuleStore.list(@routing_table)

      cinnox_rules = Enum.filter(rules, fn r -> cinnox_orch_str in (r.receivers || []) end)

      assert length(cinnox_rules) >= 1,
             "expected at least one routing rule for cinnox orchestrator #{cinnox_orch_str}"

      Enum.each(cinnox_rules, fn rule ->
        matcher_str =
          case rule.matcher_data do
            s when is_binary(s) -> s
            m when is_map(m) -> Jason.encode!(m)
          end

        assert String.contains?(matcher_str, alice_session_str),
               "cinnox routing rule matcher should reference alice's session #{alice_session_str}; " <>
                 "got: #{matcher_str}"

        refute String.contains?(matcher_str, bob_session_str),
               "cinnox routing rule matcher must NOT reference bob's session #{bob_session_str}; " <>
                 "got: #{matcher_str}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Cap isolation — alice holds NO cap scoped to acme's workspace
  # ---------------------------------------------------------------------------

  describe "cap isolation" do
    test "alice's caps are scoped only to cinnox workspace (or :any)", %{
      cinnox_result: cinnox_result,
      acme_ws: acme_ws
    } do
      alice_uri = cinnox_result.customer_uri
      alice_caps = Identity.list_caps_for(alice_uri)

      # Alice must hold NO cap with workspace_uri = acme_ws
      acme_scoped_caps =
        alice_caps
        |> Enum.filter(fn cap ->
          cap.workspace_uri == acme_ws
        end)

      assert acme_scoped_caps == [],
             "alice must have NO cap scoped to acme workspace #{URI.to_string(acme_ws)}; " <>
               "found: #{inspect(acme_scoped_caps)}"
    end

    test "bob's caps are scoped only to acme workspace (or :any)", %{
      acme_result: acme_result,
      cinnox_ws: cinnox_ws
    } do
      bob_uri = acme_result.customer_uri
      bob_caps = Identity.list_caps_for(bob_uri)

      cinnox_scoped_caps =
        bob_caps
        |> Enum.filter(fn cap ->
          cap.workspace_uri == cinnox_ws
        end)

      assert cinnox_scoped_caps == [],
             "bob must have NO cap scoped to cinnox workspace #{URI.to_string(cinnox_ws)}; " <>
               "found: #{inspect(cinnox_scoped_caps)}"
    end

    test "alice's role caps are scoped to cinnox workspace (not :any)", %{
      cinnox_result: cinnox_result,
      cinnox_ws: cinnox_ws
    } do
      alice_uri = cinnox_result.customer_uri
      alice_caps = Identity.list_caps_for(alice_uri)

      # The customer role caps (session:send, session:receive) must be scoped to cinnox
      role_caps =
        alice_caps
        |> Enum.filter(fn cap -> cap.kind == :session end)

      refute role_caps == [],
             "alice should have session role caps; all caps: #{inspect(MapSet.to_list(alice_caps))}"

      assert Enum.all?(role_caps, fn cap -> cap.workspace_uri == cinnox_ws end),
             "alice's session caps must be scoped to cinnox_ws #{URI.to_string(cinnox_ws)}; " <>
               "got: #{inspect(Enum.map(role_caps, & &1.workspace_uri))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp read_orchestrator_state(%URI{} = orch_uri) do
    case Ezagent.KindRegistry.lookup(orch_uri) do
      {:ok, pid} ->
        server_state = :sys.get_state(pid, 1_000)
        slice = get_in(server_state, [:state, :cs_orchestrator])

        case slice do
          %{state: state} -> state
          state when is_map(state) -> state
          _ -> %{}
        end

      :error ->
        %{}
    end
  end
end
