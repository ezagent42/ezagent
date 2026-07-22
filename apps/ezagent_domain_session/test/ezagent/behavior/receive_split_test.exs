defmodule Ezagent.ActionSet.ReceiveSplitTest do
  @moduledoc """
  PR-2 (im/session/agent decomposition §OQ-4 / §3.3) — the architectural
  gate for splitting the single `:receive` action (which used to branch
  internally on `ctx.kind_module` inside `Ezagent.ActionSet.Session`) into
  TWO first-class Behaviors registered per-Kind:

    - `Ezagent.ActionSet.User.Receive`  (`user.receive`,  on `Entity.User`)
    - `Ezagent.ActionSet.Agent.Receive` (`agent.receive`, on `Entity.Agent`)

  These tests FAIL if the split regresses: if `:receive` reappears on
  `Behavior.Session`, if the internal `case kind_module` is reintroduced,
  if the registry stops routing per-Kind, or if the User receive-state
  slice key drifts off `:session` (which would force a snapshot
  migration).
  """

  # The unified authorization fixture signs the held member-cap against the
  # holder's current authority, which is DB-backed and starts a concrete Kind.
  # Keep the test on DataCase's shared sandbox owner so that globally
  # supervised Kind may use the same connection deterministically.
  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Capability, Message}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.ActionSet.User.Receive, as: UserReceive
  alias Ezagent.ActionSet.Agent.Receive, as: AgentReceive
  alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

  # Membership-cap unification A2.2 — `:receive` now authorizes in-handler on the
  # recipient's HELD member-cap over `ctx.caller`. These tests assert slice
  # MECHANICS (the held-cap gate itself is proven in
  # `Ezagent.Session.HeldCapReceiveTest`), so they grant the recipient the
  # matching member-cap in the pre-loaded `:identity` sibling to clear the gate.
  defp with_member_cap(ctx) do
    caller = Map.fetch!(ctx, :caller)

    cap = %Capability{
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        caller,
        Capability.workspace_of(caller)
      )
      | granted_by: URI.new!("entity://system/user/owner"),
        granted_at: DateTime.utc_now()
    }

    Map.put(ctx, :siblings, %{identity: %{caps: MapSet.new([cap])}})
  end

  describe "registry routes :receive per-Kind to the two new Behaviors" do
    test "{User, :receive} → Behavior.User.Receive" do
      assert {:ok, UserReceive} = BehaviorRegistry.lookup(Ezagent.Entity.User, :receive)
    end

    test "{Agent, :receive} → Behavior.Agent.Receive" do
      assert {:ok, AgentReceive} = BehaviorRegistry.lookup(Ezagent.Entity.Agent, :receive)
    end
  end

  describe "the internal case-on-kind is retired from Session" do
    test "Behavior.Session no longer declares :receive" do
      refute :receive in SessionBehavior.actions()
    end

    test "Behavior.Session no longer exports a handle_receive/2" do
      refute function_exported?(SessionBehavior, :handle_receive, 2)
    end
  end

  describe "User.Receive — slice ownership (no snapshot migration)" do
    test "state_slice is :session (shares the User Kind's receive-state slice key)" do
      # Pinned via `state_slice: :session` override so a pre-split User
      # snapshot's `:session` slice (with :last_received / :recent_messages)
      # round-trips unchanged — NO migration. The auto-derived key would be
      # `:receive`, which would orphan the existing data.
      assert UserReceive.state_slice() == :session
    end

    test "handle_receive writes :last_received + the cursor-ring :recent_messages" do
      user_uri =
        URI.new!("entity://team-alpha/user/recv-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://team-alpha/agent/cc-builder")
      msg = Message.new(sender, %{text: "incoming", attachments: []})

      ctx = %{
        self_uri: user_uri,
        kind_module: Ezagent.Entity.User,
        caller: sender,
        slice_change_cursor: 7
      }

      assert {:ok, new_slice} =
               Invoker.invoke(UserReceive, :receive, %{}, %{message: msg}, with_member_cap(ctx))

      assert new_slice.last_received.message_id == msg.id
      assert %DateTime{} = new_slice.last_received.at
      assert [{7, rid} | _] = new_slice.recent_messages
      assert rid == msg.id
    end

    test "recent_messages ring is bounded at the SPEC-pinned depth" do
      depth = UserReceive.recent_messages_ring_depth()
      assert depth == 20

      user_uri =
        URI.new!("entity://team-alpha/user/cap-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://team-alpha/user/sender")
      prefill = for i <- 1..depth, do: {i, "msg-#{i}"}
      msg = Message.new(sender, %{text: "newest", attachments: []})

      ctx = %{
        self_uri: user_uri,
        kind_module: Ezagent.Entity.User,
        caller: sender,
        slice_change_cursor: 999
      }

      assert {:ok, new_slice} =
               Invoker.invoke(
                 UserReceive,
                 :receive,
                 %{recent_messages: prefill},
                 %{message: msg},
                 with_member_cap(ctx)
               )

      assert length(new_slice.recent_messages) == depth
      assert [{999, _} | _] = new_slice.recent_messages
    end

    test "a cold-revival replay does not replace a newer last_received value" do
      user_uri =
        URI.new!("entity://team-alpha/user/replay-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://team-alpha/user/sender")
      replayed = Message.new(sender, %{text: "replayed", attachments: []})
      newer_at = DateTime.utc_now()

      prior = %{
        last_received: %{message_id: "newer-message", at: newer_at},
        recent_messages: [{8, "newer-message"}, {7, replayed.id}]
      }

      ctx = %{
        self_uri: user_uri,
        kind_module: Ezagent.Entity.User,
        caller: sender,
        slice_change_cursor: 9
      }

      assert {:ok, ^prior} =
               Invoker.invoke(
                 UserReceive,
                 :receive,
                 prior,
                 %{message: replayed},
                 with_member_cap(ctx)
               )
    end
  end

  describe "Agent.Receive — live delivery, no slice state" do
    test "delivers via AgentBridge and returns the slice unchanged" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_recv-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://system/user/admin")

      session_uri =
        URI.new!("session://team-alpha/default/recv-#{System.unique_integer([:positive])}")

      msg = Message.new(sender, %{text: "hi agent", attachments: []})

      :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, self())
      :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "cc")

      on_exit(fn ->
        Ezagent.AgentBridge.Registry.unbind(agent_uri)
        Ezagent.AgentFlavorAttributes.delete(agent_uri)
      end)

      ctx = %{self_uri: agent_uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      assert {:ok, %{}} =
               Invoker.invoke(AgentReceive, :receive, %{}, %{message: msg}, with_member_cap(ctx))

      # The flavor-neutral payload reached the bound bridge channel.
      assert_receive {:agent_bridge_push, "to_claude", %{"content" => content, "meta" => meta}},
                     500

      assert content == "hi agent"
      assert meta["session"] == URI.to_string(session_uri)
    end

    test "reads_siblings declares :sandbox (flavor resolution for adapter pick)" do
      assert :sandbox in AgentReceive.reads_siblings()
    end
  end
end
