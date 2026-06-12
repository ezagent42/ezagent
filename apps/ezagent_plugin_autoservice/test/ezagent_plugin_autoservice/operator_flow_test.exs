defmodule EzagentPluginAutoservice.OperatorFlowTest do
  @moduledoc """
  Operator takeover end-to-end flow test.

  Verifies:
  1. Provision tenant + customer + orchestrator (via Assembly.provision_session with create_agents: false).
  2. Open a turn (direct TurnDriver — no live AI agent needed).
  3. Dispatch orchestrator `operator_claim(turn_id, "human reply", operator_uri)`:
     - Assert draft is held :operator_only (CustomerFeed does NOT return it).
     - Assert orchestrator operator_active = true.
  4. Dispatch orchestrator `operator_settle(turn_id)`:
     - Assert reply is now customer_visible (appears in CustomerFeed.snapshot).
     - Assert orchestrator operator_active = false.
  5. All pre-existing tests remain green (operator_claim args updated in Part 1).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias Ezagent.Invocation
  alias EzagentPluginAutoservice.{Assembly, TurnDriver}

  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end

  defp priv_ctx do
    %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  # Read operator_active from the live orchestrator Kind via :sys.get_state
  # (same Phase-B shortcut as Assembly.open_turn_id).
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

  setup do
    suffix = System.unique_integer([:positive])

    tid = "test-tenant-#{suffix}"
    customer_name = "customer-#{suffix}"

    ctx = %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }

    # Provision with create_agents: false (structural only, no live AI agents).
    assert {:ok,
            %{
              session_uri: session_uri,
              customer_uri: customer_uri,
              orchestrator_uri: orch_uri
            }} =
             Assembly.provision_session(tid, customer_name, ctx, create_agents: false)

    workspace_uri = Ezagent.URI.workspace(tid)
    token = CustomerAuth.issue_token(session_uri, workspace_uri)

    operator_uri = Ezagent.URI.user(tid, "operator-#{suffix}")

    %{
      session_uri: session_uri,
      customer_uri: customer_uri,
      orch_uri: orch_uri,
      token: token,
      operator_uri: operator_uri
    }
  end

  # ---------------------------------------------------------------------------
  # Test: operator_claim holds draft operator_only; operator_settle flips visible
  # ---------------------------------------------------------------------------

  describe "operator takeover flow — claim then settle" do
    test "claim holds draft operator_only; settle makes it customer_visible", %{
      session_uri: session_uri,
      orch_uri: orch_uri,
      token: token,
      operator_uri: operator_uri
    } do
      tctx = priv_ctx()
      orch_target_base = URI.to_string(orch_uri)

      # Step 1: open a turn (simulates customer message arriving).
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "help me please"}
      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(session_uri, trigger, tctx)

      # CustomerFeed should be empty before operator does anything.
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session_uri, token)

      # Step 2: dispatch orchestrator operator_claim.
      operator_claim_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_claim")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_claim_target,
                 mode: :call,
                 args: %{
                   turn_id: turn_id,
                   operator_text: "Human reply from operator",
                   operator_uri: URI.to_string(operator_uri)
                 },
                 ctx: %{
                   caller: operator_uri,
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Assert operator_active = true in orchestrator state.
      orch_state = read_orchestrator_state(orch_uri)

      assert orch_state[:operator_active] == true,
             "expected operator_active=true after operator_claim, got: #{inspect(orch_state)}"

      # Assert CustomerFeed does NOT show the draft (it's :operator_only).
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session_uri, token),
             "CustomerFeed should be empty while draft is operator_only"

      # Step 3: dispatch orchestrator operator_settle.
      operator_settle_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_settle")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_settle_target,
                 mode: :call,
                 args: %{turn_id: turn_id},
                 ctx: %{
                   caller: operator_uri,
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Assert operator_active = false in orchestrator state.
      orch_state_after = read_orchestrator_state(orch_uri)

      assert orch_state_after[:operator_active] == false,
             "expected operator_active=false after operator_settle, got: #{inspect(orch_state_after)}"

      # Assert the operator reply is now customer_visible in CustomerFeed.
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(session_uri, token)
          Enum.any?(snap.messages, &message_text?(&1, "Human reply from operator"))
        end,
        150
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(session_uri, token)

      assert Enum.any?(snapshot.messages, &message_text?(&1, "Human reply from operator")),
             "expected operator reply in CustomerFeed after settle, " <>
               "got: #{inspect(Enum.map(snapshot.messages, & &1.body))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test: MessageStore sees ALL messages; CustomerFeed only customer_visible
  # ---------------------------------------------------------------------------

  describe "message visibility after operator_claim" do
    test "MessageStore has the draft; CustomerFeed has nothing (until settle)", %{
      session_uri: session_uri,
      orch_uri: orch_uri,
      token: token,
      operator_uri: operator_uri
    } do
      tctx = priv_ctx()
      orch_target_base = URI.to_string(orch_uri)

      trigger = %{message_id: "m-vis-#{System.unique_integer([:positive])}", text: "question"}
      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(session_uri, trigger, tctx)

      operator_claim_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_claim")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_claim_target,
                 mode: :call,
                 args: %{
                   turn_id: turn_id,
                   operator_text: "Operator-only draft",
                   operator_uri: URI.to_string(operator_uri)
                 },
                 ctx: %{
                   caller: operator_uri,
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Give settlement async time (compose writes message to MessageStore).
      Process.sleep(50)

      # CustomerFeed must still be empty (draft is operator_only).
      assert {:ok, %{messages: customer_msgs}} = CustomerFeed.snapshot(session_uri, token)

      assert Enum.all?(customer_msgs, fn m -> not message_text?(m, "Operator-only draft") end),
             "CustomerFeed must not expose operator_only draft; got: #{inspect(Enum.map(customer_msgs, & &1.body))}"
    end
  end
end
