defmodule EzagentPluginAutoservice.CsOrchestratorTest do
  @moduledoc """
  CS Orchestrator — handler-level + integration tests.

  ## Test structure

  1. Handler-level — call `Ezagent.Behavior.CsOrchestrator.handle_receive/2`
     etc. directly with a fake ctx.  No DB, no dispatch. Pure function tests.

  2. Integration — spawn a real orchestrator Kind via the Lifecycle path,
     dispatch `chat.receive` through Invocation, and assert outcomes via
     `CustomerFeed.snapshot/2`.

  ## Session harness

  Reused from `TurnDriverTest`: spawn `SocialwareSession`, bind workspace,
  issue CustomerAuth token.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias Ezagent.{Invocation, Message}
  alias Ezagent.Behavior.CsOrchestrator
  alias Ezagent.Entity.CsOrchestrator, as: CsOrchestratorKind

  # Privileged ctx identical to TurnDriverTest.
  defp priv_ctx do
    %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

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

  # ---------------------------------------------------------------------------
  # Session + orchestrator harness
  # ---------------------------------------------------------------------------

  setup do
    suffix = System.unique_integer([:positive])

    session =
      Ezagent.URI.session(:team_alpha, :cs, "orch-test-#{suffix}")

    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)

    customer_uri = Ezagent.URI.user(:team_alpha, "customer-#{suffix}")
    fast_uri = Ezagent.URI.agent(:team_alpha, "fast-#{suffix}")
    slow_uri = Ezagent.URI.agent(:team_alpha, "slow-#{suffix}")

    orch_uri = Ezagent.URI.agent(:team_alpha, "orch_cs_#{suffix}")

    %{
      session: session,
      workspace: workspace,
      token: token,
      customer_uri: customer_uri,
      fast_uri: fast_uri,
      slow_uri: slow_uri,
      orch_uri: orch_uri
    }
  end

  # Helper to build a fake Lifecycle ctx for direct handler invocation.
  defp fake_ctx(state) do
    self_uri = Ezagent.URI.agent(:team_alpha, "orch_test")

    %{
      self_uri: self_uri,
      caller: self_uri,
      caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
      read: fn key, default -> Map.get(state, key, default) end
    }
  end

  defp test_message(sender_uri, text) do
    Message.new(sender_uri, %{text: text, attachments: []})
  end

  # ---------------------------------------------------------------------------
  # Handler-level tests (pure functions, no dispatch)
  # ---------------------------------------------------------------------------

  describe "handle_receive/2 — customer message (no operator_active)" do
    test "returns set open_turn_id effect + 2 dispatch effects to fast/slow", ctx_map do
      %{session: session, customer_uri: customer_uri, fast_uri: fast_uri, slow_uri: slow_uri} =
        ctx_map

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: URI.to_string(fast_uri),
        slow_uri: URI.to_string(slow_uri),
        open_turn_id: nil,
        operator_active: false
      }

      # We need a real session for TurnDriver.open to work — this is an
      # integration step for the customer message path. Use priv_ctx + the
      # already-spawned session from setup.
      msg = test_message(customer_uri, "I need help")

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      assert {:ok, %{ok: true}, effects} =
               CsOrchestrator.handle_receive(%{message: msg}, ctx)

      # Must have a :set for open_turn_id.
      set_effects = Enum.filter(effects, &match?({:set, :open_turn_id, _}, &1))
      assert length(set_effects) == 1
      [{:set, :open_turn_id, tid}] = set_effects
      assert is_binary(tid)

      # Must have 2 dispatch_after_commit effects (P22 — dead agent must not abort commit).
      dispatches = Enum.filter(effects, &match?({:dispatch_after_commit, _}, &1))
      assert length(dispatches) == 2

      targets =
        Enum.map(dispatches, fn {:dispatch_after_commit, cmd} -> URI.to_string(cmd.target) end)

      fast_str = URI.to_string(fast_uri)
      slow_str = URI.to_string(slow_uri)

      assert Enum.any?(targets, &String.starts_with?(&1, fast_str)),
             "expected fast_uri target in dispatches, got: #{inspect(targets)}"

      assert Enum.any?(targets, &String.starts_with?(&1, slow_str)),
             "expected slow_uri target in dispatches, got: #{inspect(targets)}"

      # Both targets must carry ?action=chat.receive.
      assert Enum.all?(targets, &String.contains?(&1, "action=chat.receive")),
             "expected all dispatch targets to have ?action=chat.receive, got: #{inspect(targets)}"
    end
  end

  describe "handle_receive/2 — customer message with operator_active" do
    test "Turn.open runs (set effect present) but no dispatch effects", ctx_map do
      %{session: session, customer_uri: customer_uri, fast_uri: fast_uri, slow_uri: slow_uri} =
        ctx_map

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: URI.to_string(fast_uri),
        slow_uri: URI.to_string(slow_uri),
        open_turn_id: nil,
        operator_active: true
      }

      msg = test_message(customer_uri, "Urgent help")

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      assert {:ok, %{ok: true}, effects} =
               CsOrchestrator.handle_receive(%{message: msg}, ctx)

      # Set effect for open_turn_id must be present.
      set_effects = Enum.filter(effects, &match?({:set, :open_turn_id, _}, &1))
      assert length(set_effects) == 1

      # No dispatch_after_commit effects — operator has taken over.
      dispatches = Enum.filter(effects, &match?({:dispatch_after_commit, _}, &1))

      assert dispatches == [],
             "expected no dispatch_after_commit effects with operator_active=true, got: #{inspect(dispatches)}"
    end
  end

  describe "handle_receive/2 — unknown sender" do
    test "no effects returned", ctx_map do
      %{session: session, customer_uri: customer_uri} = ctx_map

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: "",
        slow_uri: "",
        open_turn_id: nil,
        operator_active: false
      }

      # Unknown sender — not customer, not fast, not slow.
      unknown_sender =
        Ezagent.URI.user(:team_alpha, "random-#{System.unique_integer([:positive])}")

      msg = test_message(unknown_sender, "Who am I?")

      ctx = fake_ctx(state)

      assert {:ok, %{ok: true}, []} =
               CsOrchestrator.handle_receive(%{message: msg}, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler-level — operator_claim
  # ---------------------------------------------------------------------------

  describe "handle_operator_claim/2" do
    test "returns {:set, :operator_active, true} after successful claim", ctx_map do
      %{session: session, customer_uri: customer_uri, fast_uri: fast_uri, slow_uri: slow_uri} =
        ctx_map

      # Open a turn (status :open, empty expected) — handle_operator_claim will
      # compose the operator's text then claim. Do NOT pre-compose here since
      # Turn.compose only allows :open (empty expected) or :aggregating status;
      # a pre-composed (:composing) turn would cause the handler's compose to fail.
      tctx = priv_ctx()
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "help me"}

      assert {:ok, %{turn_id: turn_id}} =
               EzagentPluginAutoservice.TurnDriver.open(session, trigger, tctx)

      operator_uri =
        Ezagent.URI.entity(:team_alpha, :user, "op-#{System.unique_integer([:positive])}")

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: URI.to_string(fast_uri),
        slow_uri: URI.to_string(slow_uri),
        open_turn_id: turn_id,
        operator_active: false
      }

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      assert {:ok, %{ok: true}, effects} =
               CsOrchestrator.handle_operator_claim(
                 %{
                   turn_id: turn_id,
                   operator_text: "Operator edited reply",
                   operator_uri: URI.to_string(operator_uri)
                 },
                 ctx
               )

      assert {:set, :operator_active, true} in effects
    end
  end

  # ---------------------------------------------------------------------------
  # Handler-level — operator_settle
  # ---------------------------------------------------------------------------

  describe "handle_operator_settle/2" do
    test "resets operator_active and open_turn_id after successful settle", ctx_map do
      %{session: session, customer_uri: customer_uri, fast_uri: fast_uri, slow_uri: slow_uri} =
        ctx_map

      # open → compose → claim (so settle can transition from :awaiting_human).
      tctx = priv_ctx()
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "take over"}

      assert {:ok, %{turn_id: turn_id}} =
               EzagentPluginAutoservice.TurnDriver.open(session, trigger, tctx)

      assert {:ok, _} =
               EzagentPluginAutoservice.TurnDriver.compose(session, turn_id, "draft", tctx)

      operator_uri =
        Ezagent.URI.entity(:team_alpha, :user, "op-settle-#{System.unique_integer([:positive])}")

      assert {:ok, _} =
               EzagentPluginAutoservice.TurnDriver.claim(session, turn_id, operator_uri, tctx)

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: URI.to_string(fast_uri),
        slow_uri: URI.to_string(slow_uri),
        open_turn_id: turn_id,
        operator_active: true
      }

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      assert {:ok, %{ok: true}, effects} =
               CsOrchestrator.handle_operator_settle(%{turn_id: turn_id}, ctx)

      assert {:set, :operator_active, false} in effects
      assert {:set, :open_turn_id, nil} in effects
    end

    test "settles the TRACKED turn, ignoring a stale/bogus arg turn_id", ctx_map do
      # New contract (live-E2E operator fix): operator_claim opens a fresh turn
      # and tracks it as open_turn_id; OperatorLive's settle passes "" (it does
      # not know the fresh id). So operator_settle must settle its OWN tracked
      # turn, NOT a caller-supplied arg. Here the tracked turn is a real claimed
      # (settle-able) turn and the arg is bogus — the tracked turn must settle.
      %{session: session, customer_uri: customer_uri, fast_uri: fast_uri, slow_uri: slow_uri} =
        ctx_map

      tctx = priv_ctx()

      tracked_trigger = %{
        message_id: "m-tracked-#{System.unique_integer([:positive])}",
        text: "tracked"
      }

      assert {:ok, %{turn_id: tracked_tid}} =
               EzagentPluginAutoservice.TurnDriver.open(session, tracked_trigger, tctx)

      assert {:ok, _} =
               EzagentPluginAutoservice.TurnDriver.compose(session, tracked_tid, "draft", tctx)

      operator_uri =
        Ezagent.URI.entity(:team_alpha, :user, "op-tracked-#{System.unique_integer([:positive])}")

      assert {:ok, _} =
               EzagentPluginAutoservice.TurnDriver.claim(session, tracked_tid, operator_uri, tctx)

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: URI.to_string(fast_uri),
        slow_uri: URI.to_string(slow_uri),
        open_turn_id: tracked_tid,
        operator_active: true
      }

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      # Arg turn_id is bogus — the tracked turn must be the one that settles.
      assert {:ok, %{ok: true}, effects} =
               CsOrchestrator.handle_operator_settle(%{turn_id: "bogus-arg-turn-id"}, ctx)

      assert {:set, :open_turn_id, nil} in effects

      # The tracked turn is now settled (terminal) — a second settle is illegal.
      assert {:error, {:illegal_transition, _}} =
               EzagentPluginAutoservice.TurnDriver.settle(session, tracked_tid, tctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — slow reply settles to customer feed
  # ---------------------------------------------------------------------------

  describe "slow reply integration — end-to-end" do
    test "slow-agent reply text appears in CustomerFeed after settle", ctx_map do
      %{
        session: session,
        token: token,
        customer_uri: customer_uri,
        slow_uri: slow_uri
      } = ctx_map

      # Feed starts empty.
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session, token)

      # Simulate the slow agent's reply: compose + settle on an open turn.
      # First open a turn (as customer message arrival would).
      tctx = priv_ctx()
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "I need help"}

      assert {:ok, %{turn_id: tid}} =
               EzagentPluginAutoservice.TurnDriver.open(session, trigger, tctx)

      # Build state with open_turn_id set, slow_uri = slow_uri.
      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: "",
        slow_uri: URI.to_string(slow_uri),
        open_turn_id: tid,
        operator_active: false
      }

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      slow_reply_text = "Here is the solution for you"
      msg = test_message(slow_uri, slow_reply_text)

      assert {:ok, %{ok: true}, effects} =
               CsOrchestrator.handle_receive(%{message: msg}, ctx)

      # Effect must clear open_turn_id.
      assert {:set, :open_turn_id, nil} in effects

      # After the handler ran (which called TurnDriver.settle synchronously),
      # the feed should show the reply.
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(session, token)
          Enum.any?(snap.messages, &message_text?(&1, slow_reply_text))
        end,
        100
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(session, token)

      assert Enum.any?(snapshot.messages, &message_text?(&1, slow_reply_text)),
             "expected '#{slow_reply_text}' in feed, got: #{inspect(Enum.map(snapshot.messages, & &1.body))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — fast reply ACK turn settles to customer feed
  # ---------------------------------------------------------------------------

  describe "fast reply integration — ACK turn settles to customer feed" do
    test "fast reply text appears in CustomerFeed after ACK settle", ctx_map do
      %{
        session: session,
        token: token,
        customer_uri: customer_uri,
        fast_uri: fast_uri
      } = ctx_map

      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(session, token)

      state = %{
        session_uri: URI.to_string(session),
        customer_uri: URI.to_string(customer_uri),
        fast_uri: URI.to_string(fast_uri),
        slow_uri: "",
        open_turn_id: nil,
        operator_active: false
      }

      ctx =
        fake_ctx(state)
        |> Map.put(:caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))

      fast_reply_text = "Quick ACK: got your request"
      msg = test_message(fast_uri, fast_reply_text)

      assert {:ok, %{ok: true}, []} =
               CsOrchestrator.handle_receive(%{message: msg}, ctx)

      # ACK turn: open→compose→settle happened synchronously inside the handler.
      # Wait for settlement to propagate to the feed.
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(session, token)
          Enum.any?(snap.messages, &message_text?(&1, fast_reply_text))
        end,
        100
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(session, token)

      assert Enum.any?(snapshot.messages, &message_text?(&1, fast_reply_text)),
             "expected '#{fast_reply_text}' in feed, got: #{inspect(Enum.map(snapshot.messages, & &1.body))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — real Kind spawn + dispatch
  # ---------------------------------------------------------------------------

  describe "real Kind spawn + dispatch integration" do
    test "customer message dispatch opens turn; slow reply dispatch settles to feed", ctx_map do
      %{
        session: session,
        token: token,
        customer_uri: customer_uri,
        slow_uri: slow_uri
      } = ctx_map

      # Provision the orchestrator Kind inline (mirrors after_boot in C4).
      # Use empty fast_uri so no fan-out to a non-existent fast actor is attempted.
      # Use empty slow_uri too for the first (customer message) dispatch — the
      # fan-out `:dispatch` effect aborts when the target Kind doesn't exist.
      # The slow-reply compose+settle path is tested via the handler-level
      # integration tests above (TurnDriver directly). Here we test the
      # full Invocation path for state tracking: customer → turn opened,
      # then a second dispatch (slow_uri sender) → compose+settle.
      #
      # To enable the slow reply dispatch we configure slow_uri but no fast_uri,
      # and test two separate orchestrators sharing the same session.

      # Orchestrator A: no fan-out (fast="", slow="") — test customer turn open.
      orch_a = Ezagent.URI.agent(:team_alpha, "orch_a_#{System.unique_integer([:positive])}")
      :ok = Ezagent.AgentFlavorAttributes.put(orch_a, "cs_orchestrator")

      {:ok, _pid_a} =
        Ezagent.Kind.spawn(CsOrchestratorKind, %{
          uri: orch_a,
          session_uri: URI.to_string(session),
          customer_uri: URI.to_string(customer_uri),
          fast_uri: "",
          slow_uri: ""
        })

      customer_msg = test_message(customer_uri, "Hello I need support A")
      target_a = Ezagent.URI.with_action(orch_a, :chat, :receive)

      # Customer message → opens turn, no fan-out (empty fast/slow).
      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: target_a,
                 mode: :call,
                 args: %{message: customer_msg},
                 ctx: %{
                   caller: session,
                   caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # Orchestrator B: slow_uri set, fast_uri blank — test slow reply path.
      orch_b = Ezagent.URI.agent(:team_alpha, "orch_b_#{System.unique_integer([:positive])}")
      :ok = Ezagent.AgentFlavorAttributes.put(orch_b, "cs_orchestrator")

      {:ok, _pid_b} =
        Ezagent.Kind.spawn(CsOrchestratorKind, %{
          uri: orch_b,
          session_uri: URI.to_string(session),
          customer_uri: URI.to_string(customer_uri),
          fast_uri: "",
          slow_uri: URI.to_string(slow_uri)
        })

      # Customer message to orch_b to open a turn (no fan-out: fast="" slow set
      # but slow_uri not a live kind → would fail fan-out). Use "" slow too.
      # NOTE: We need the turn opened by the customer message to be accessible
      # to the slow reply. Since we can't fan-out to non-existent agents,
      # we skip the fan-out step by using a third orchestrator with slow="" too,
      # open the turn, then manually reconfigure (not possible in Lifecycle state).
      #
      # Realistic approach: test orchestrator C with slow_uri set, open turn
      # via customer message with fan-out disabled (fast="" slow=""), then
      # send slow reply. The orchestrator will self-heal (open_turn_id=nil →
      # open new degenerate turn) on the slow reply.

      orch_c = Ezagent.URI.agent(:team_alpha, "orch_c_#{System.unique_integer([:positive])}")
      :ok = Ezagent.AgentFlavorAttributes.put(orch_c, "cs_orchestrator")

      {:ok, _pid_c} =
        Ezagent.Kind.spawn(CsOrchestratorKind, %{
          uri: orch_c,
          session_uri: URI.to_string(session),
          customer_uri: URI.to_string(customer_uri),
          fast_uri: "",
          slow_uri: URI.to_string(slow_uri)
        })

      # Dispatch slow reply directly (open_turn_id=nil → self-heal triggers
      # a new degenerate turn, then compose+settle).
      slow_reply_text = "Here is your support answer"
      slow_msg = test_message(slow_uri, slow_reply_text)
      target_c = Ezagent.URI.with_action(orch_c, :chat, :receive)

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: target_c,
                 mode: :call,
                 args: %{message: slow_msg},
                 ctx: %{
                   caller: session,
                   caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # After slow reply, the settled turn should appear in the feed.
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(session, token)
          Enum.any?(snap.messages, &message_text?(&1, slow_reply_text))
        end,
        200
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(session, token)

      assert Enum.any?(snapshot.messages, &message_text?(&1, slow_reply_text)),
             "expected slow reply in feed after orchestrator dispatch, got: #{inspect(Enum.map(snapshot.messages, & &1.body))}"
    end

    test "slow reply delivered as chat.SEND (bridge path) settles identically", ctx_map do
      # Regression for the live-E2E #4 fix: the agent bridge's dispatch_reply/5
      # delivers a sub-agent's reply to the orchestrator as `chat.send` (:send),
      # NOT `chat.receive`. The orchestrator's :send action delegates to
      # handle_receive/2, so the slow reply must settle to the feed exactly as
      # the :receive path does. Before the fix this dropped with
      # {:unknown_action, :send} and the customer saw no answer.
      %{session: session, token: token, customer_uri: customer_uri, slow_uri: slow_uri} = ctx_map

      orch = Ezagent.URI.agent(:team_alpha, "orch_send_#{System.unique_integer([:positive])}")
      :ok = Ezagent.AgentFlavorAttributes.put(orch, "cs_orchestrator")

      {:ok, _pid} =
        Ezagent.Kind.spawn(CsOrchestratorKind, %{
          uri: orch,
          session_uri: URI.to_string(session),
          customer_uri: URI.to_string(customer_uri),
          fast_uri: "",
          slow_uri: URI.to_string(slow_uri)
        })

      slow_reply_text = "Answer delivered via chat.send"
      slow_msg = test_message(slow_uri, slow_reply_text)
      # The bridge targets ?action=chat.send (not chat.receive).
      target = Ezagent.URI.with_action(orch, :chat, :send)

      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: target,
                 mode: :call,
                 args: %{message: slow_msg},
                 ctx: %{
                   caller: session,
                   caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
                   reply: {:caller_inbox, self()}
                 }
               })

      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(session, token)
          Enum.any?(snap.messages, &message_text?(&1, slow_reply_text))
        end,
        200
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(session, token)

      assert Enum.any?(snapshot.messages, &message_text?(&1, slow_reply_text)),
             "expected the chat.send-delivered slow reply to settle to the feed, got: " <>
               "#{inspect(Enum.map(snapshot.messages, & &1.body))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — fan-out to nonexistent agents must not abort turn commit (P22)
  # ---------------------------------------------------------------------------

  describe "fan-out failure does not abort turn-open commit (P22 — dispatch_after_commit)" do
    test "customer dispatch succeeds and open_turn_id is SET even when fast/slow URIs are dead",
         ctx_map do
      %{
        session: session,
        token: _token,
        customer_uri: customer_uri,
        orch_uri: orch_uri
      } = ctx_map

      suffix = System.unique_integer([:positive])

      # Ghost URIs — real entity-shaped URIs with no Kind/snapshot registered.
      ghost_fast = Ezagent.URI.agent(:team_alpha, "ghost-fast-#{suffix}")
      ghost_slow = Ezagent.URI.agent(:team_alpha, "ghost-slow-#{suffix}")

      :ok = Ezagent.AgentFlavorAttributes.put(orch_uri, "cs_orchestrator")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.CsOrchestrator, %{
          uri: orch_uri,
          session_uri: URI.to_string(session),
          customer_uri: URI.to_string(customer_uri),
          fast_uri: URI.to_string(ghost_fast),
          slow_uri: URI.to_string(ghost_slow)
        })

      customer_msg = test_message(customer_uri, "Need help — ghosts ahead")
      target = Ezagent.URI.with_action(orch_uri, :chat, :receive)

      # The call must succeed: dead fan-out targets must NOT abort the turn-open commit.
      assert {:ok, %{ok: true}} =
               Invocation.dispatch(%Invocation{
                 target: target,
                 mode: :call,
                 args: %{message: customer_msg},
                 ctx: %{
                   caller: session,
                   caps: Ezagent.SystemPrincipal.caps("system://chat-router"),
                   reply: {:caller_inbox, self()}
                 }
               })

      # open_turn_id must be SET in the live orchestrator state. The dispatch was
      # :call so the commit has already completed before we return. Read state
      # directly from the running Kind server via :sys.get_state (same pattern as
      # pty_test.exs) — no Snapshot.load needed.
      # Kind.Server state shape: %{state: %{cs_orchestrator: %{state: %{...}, transients: %{}}}}
      # (Lifecycle two-container slice, keyed by the auto-derived state_slice/0 atom).
      {:ok, kind_pid} = Ezagent.KindRegistry.lookup(orch_uri)
      server_state = :sys.get_state(kind_pid, 500)
      slice = get_in(server_state, [:state, :cs_orchestrator])

      open_turn_id =
        case slice do
          %{state: %{open_turn_id: tid}} -> tid
          %{open_turn_id: tid} -> tid
          _ -> nil
        end

      assert is_binary(open_turn_id),
             "expected open_turn_id to be a binary after customer dispatch with dead fan-out URIs, " <>
               "got: #{inspect(open_turn_id)}. P22 violation — dead sub-agent aborted the turn commit."
    end
  end

  # ---------------------------------------------------------------------------
  # Handler-level — create/1 receives args
  # ---------------------------------------------------------------------------

  describe "create/1" do
    test "builds initial state from args (atom keys)" do
      assert {:ok, state} =
               CsOrchestrator.create(%{
                 session_uri: "session://ws/cs/s1",
                 customer_uri: "entity://ws/user/c1",
                 fast_uri: "entity://ws/agent/fast1",
                 slow_uri: "entity://ws/agent/slow1"
               })

      assert state.session_uri == "session://ws/cs/s1"
      assert state.customer_uri == "entity://ws/user/c1"
      assert state.fast_uri == "entity://ws/agent/fast1"
      assert state.slow_uri == "entity://ws/agent/slow1"
      assert state.open_turn_id == nil
      assert state.operator_active == false
    end

    test "builds initial state from args (string keys — defensive)" do
      assert {:ok, state} =
               CsOrchestrator.create(%{
                 "session_uri" => "session://ws/cs/s2",
                 "customer_uri" => "entity://ws/user/c2",
                 "fast_uri" => "entity://ws/agent/fast2",
                 "slow_uri" => "entity://ws/agent/slow2"
               })

      assert state.session_uri == "session://ws/cs/s2"
      assert state.open_turn_id == nil
      assert state.operator_active == false
    end
  end
end
