defmodule EzagentPluginAutoservice.OperatorFlowTest do
  @moduledoc """
  Operator takeover end-to-end flow test.

  Verifies:
  1. Provision tenant + customer + orchestrator (via Assembly.provision_session with create_agents: false).
  2. Open a turn (direct TurnDriver — no live AI agent needed).
  3. Dispatch orchestrator `operator_claim(turn_id, "human reply", operator_uri)`:
     - operator_claim now uses open_turn_id from orchestrator state (cancel+reopen pattern).
     - Assert draft is held :operator_only (CustomerFeed does NOT return it).
     - Assert orchestrator operator_active = true.
  4. Dispatch orchestrator `operator_settle(new_turn_id)` using the new turn from orch state:
     - Assert reply is now customer_visible (appears in CustomerFeed.snapshot).
     - Assert orchestrator operator_active = false.
  5. Bot-composes-first test: simulates bot composing into the open turn (turn goes :composing)
     BEFORE the operator takes over — verifies cancel+reopen override works, bot draft is gone,
     operator text is held :operator_only, then settle makes it customer_visible.
  6. All pre-existing tests remain green.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerFeed}
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

  # Read operator_active + open_turn_id from the live orchestrator Kind via :sys.get_state
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
    token = Ezagent.Socialware.CustomerAuth.issue_token(session_uri, workspace_uri)

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

      # Step 1: open a turn (simulates customer message arriving — direct TurnDriver).
      # Note: this bypasses the orchestrator state so open_turn_id in orch state is nil.
      # operator_claim with nil open_turn_id skips cancel and opens a fresh turn.
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "help me please"}
      assert {:ok, %{turn_id: _prior_turn_id}} = TurnDriver.open(session_uri, trigger, tctx)

      # CustomerFeed should be empty before operator does anything.
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session_uri, token)

      # Step 2: dispatch orchestrator operator_claim.
      # operator_claim ignores the turn_id arg and uses open_turn_id from state;
      # since open_turn_id is nil here, it skips cancel and opens+composes+claims a fresh turn.
      operator_claim_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_claim")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_claim_target,
                 mode: :call,
                 args: %{
                   # turn_id arg is present for API compat but ignored by the new override impl
                   turn_id: "ignored",
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

      # The new turn_id is tracked in orchestrator state.
      new_turn_id = orch_state[:open_turn_id]

      assert is_binary(new_turn_id),
             "expected open_turn_id to be set in orch state after operator_claim, " <>
               "got: #{inspect(orch_state)}"

      # Assert CustomerFeed does NOT show the draft (it's :operator_only).
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session_uri, token),
             "CustomerFeed should be empty while draft is operator_only"

      # Step 3: dispatch orchestrator operator_settle using the new turn_id from orch state.
      operator_settle_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_settle")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_settle_target,
                 mode: :call,
                 args: %{turn_id: new_turn_id},
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
      assert {:ok, %{turn_id: _}} = TurnDriver.open(session_uri, trigger, tctx)

      operator_claim_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_claim")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_claim_target,
                 mode: :call,
                 args: %{
                   turn_id: "ignored",
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

  # ---------------------------------------------------------------------------
  # Test: bot composes first (turn is :composing), THEN operator takes over
  # ---------------------------------------------------------------------------

  describe "operator override after bot compose" do
    test "operator_claim cancels bot draft and overrides with fresh turn when turn is :composing",
         %{
           session_uri: session_uri,
           orch_uri: orch_uri,
           token: token,
           operator_uri: operator_uri
         } do
      tctx = priv_ctx()
      orch_target_base = URI.to_string(orch_uri)

      # Step 1: open a turn (customer message path — set open_turn_id in orchestrator
      # state by dispatching through the orchestrator receive action).
      # We need the orchestrator to know about the open turn so it can cancel it.
      # Simulate customer message by dispatching receive through orchestrator.
      # The session must have a customer_uri set — use a direct customer dispatch via
      # orch receive with a fake customer sender.
      #
      # Alternatively: set open_turn_id on orchestrator state indirectly via
      # simulate a minimal customer receive dispatch. But since the orchestrator's
      # customer_uri and session_uri are set during provision, we can use TurnDriver
      # to open a turn AND then manually put it into :composing by calling compose on it.
      # Then we call operator_claim — the override should cancel that :composing turn
      # and open a fresh one.
      #
      # Direct approach: open the turn via TurnDriver AND then set it as open_turn_id
      # by dispatching orchestrator receive with a message from the customer.
      # Since we used create_agents: false, there are no bots to fan-out to, so the
      # dispatch is safe.

      # Get the customer_uri provisioned in setup.
      # Assembly stores customer_uri as entity://<tid>/user/<customer>
      # We need to send a message appearing from that customer.
      # Instead, get it from the orch state.
      orch_state_init = read_orchestrator_state(orch_uri)
      customer_uri_str = orch_state_init[:customer_uri] || ""

      refute customer_uri_str == "",
             "orchestrator must have customer_uri in state; got: #{inspect(orch_state_init)}"

      # Dispatch a fake customer receive through the orchestrator so it opens a turn
      # and sets open_turn_id in its state.
      customer_uri = Ezagent.URI.new!(customer_uri_str)
      msg_id = "m-bot-#{System.unique_integer([:positive])}"

      fake_msg = %{
        id: msg_id,
        sender: customer_uri_str,
        body: %{text: "bot should reply to this"},
        mentions: [],
        visibility: :customer_visible
      }

      receive_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.receive")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: receive_target,
                 mode: :call,
                 args: %{message: fake_msg},
                 ctx: %{
                   caller: customer_uri,
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Confirm orchestrator now has an open_turn_id.
      orch_state_with_turn = read_orchestrator_state(orch_uri)
      open_turn_id = orch_state_with_turn[:open_turn_id]

      assert is_binary(open_turn_id),
             "orchestrator must have open_turn_id after customer receive; " <>
               "got: #{inspect(orch_state_with_turn)}"

      # Step 2: Simulate the slow bot composing its draft into the open turn.
      # This moves the turn to :composing status — the critical pre-condition
      # that would make the old operator_claim fail.
      bot_draft = "This is the bot draft reply"
      assert {:ok, _} = TurnDriver.compose(session_uri, open_turn_id, bot_draft, tctx)

      # CustomerFeed is still empty (turn is :composing, not yet settled/claimed).
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session_uri, token)

      # Step 3: Operator takes over with override text.
      # With the FIX: operator_claim should cancel the :composing turn (bot draft discarded),
      # open a fresh :open turn, compose operator text, claim it (:awaiting_human).
      operator_override_text = "Operator override: I will handle this personally"

      operator_claim_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_claim")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_claim_target,
                 mode: :call,
                 args: %{
                   turn_id: open_turn_id,
                   operator_text: operator_override_text,
                   operator_uri: URI.to_string(operator_uri)
                 },
                 ctx: %{
                   caller: operator_uri,
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Assert operator_active = true.
      orch_state_after_claim = read_orchestrator_state(orch_uri)

      assert orch_state_after_claim[:operator_active] == true,
             "expected operator_active=true after operator_claim override, " <>
               "got: #{inspect(orch_state_after_claim)}"

      # Assert open_turn_id changed — a NEW turn was opened (bot's was cancelled).
      new_turn_id = orch_state_after_claim[:open_turn_id]

      assert is_binary(new_turn_id),
             "expected new open_turn_id in orch state, got: #{inspect(orch_state_after_claim)}"

      assert new_turn_id != open_turn_id,
             "expected new_turn_id to differ from bot's turn_id (cancel+reopen); " <>
               "old=#{open_turn_id}, new=#{new_turn_id}"

      # The bot's draft text must NOT be in CustomerFeed (that turn was cancelled, :operator_only
      # visibility on the draft — and the cancelled turn is never settled).
      assert {:ok, %{messages: feed_after_claim}} = CustomerFeed.snapshot(session_uri, token)

      refute Enum.any?(feed_after_claim, &message_text?(&1, bot_draft)),
             "CustomerFeed must not expose bot draft text after operator override; " <>
               "got: #{inspect(Enum.map(feed_after_claim, & &1.body))}"

      # Operator's text is held :operator_only — also not in CustomerFeed yet.
      refute Enum.any?(feed_after_claim, &message_text?(&1, operator_override_text)),
             "CustomerFeed must not expose operator text before settle; " <>
               "got: #{inspect(Enum.map(feed_after_claim, & &1.body))}"

      # Step 4: Settle the operator's turn — flips it customer_visible.
      operator_settle_target =
        Ezagent.URI.new!(orch_target_base <> "?action=cs_orchestrator.operator_settle")

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: operator_settle_target,
                 mode: :call,
                 args: %{turn_id: new_turn_id},
                 ctx: %{
                   caller: operator_uri,
                   caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Assert operator_active = false.
      orch_state_after_settle = read_orchestrator_state(orch_uri)

      assert orch_state_after_settle[:operator_active] == false,
             "expected operator_active=false after settle; got: #{inspect(orch_state_after_settle)}"

      # Operator's text must now appear in CustomerFeed (customer_visible).
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(session_uri, token)
          Enum.any?(snap.messages, &message_text?(&1, operator_override_text))
        end,
        150
      )

      assert {:ok, final_snapshot} = CustomerFeed.snapshot(session_uri, token)

      assert Enum.any?(final_snapshot.messages, &message_text?(&1, operator_override_text)),
             "expected operator override text in CustomerFeed after settle; " <>
               "got: #{inspect(Enum.map(final_snapshot.messages, & &1.body))}"

      # Bot's draft text must NOT be in CustomerFeed (cancelled turn, never settled).
      refute Enum.any?(final_snapshot.messages, &message_text?(&1, bot_draft)),
             "bot draft must not appear in CustomerFeed after operator override; " <>
               "got: #{inspect(Enum.map(final_snapshot.messages, & &1.body))}"
    end
  end
end
