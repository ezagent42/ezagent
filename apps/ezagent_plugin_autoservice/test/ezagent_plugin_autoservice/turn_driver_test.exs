defmodule EzagentPluginAutoservice.TurnDriverTest do
  @moduledoc """
  TurnDriver unit tests with stateful ctx.

  TurnDriver calls Turn.handle_* directly (v3 §6.6.1), returning
  3-tuples {status, result, effects}. Effects must be committed by the
  caller. These tests simulate the Lifecycle effect commit by threading
  state through an Agent.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginAutoservice.TurnDriver

  defmodule CtxAgent do
    @moduledoc false
    use Agent

    def start_link(init_state) do
      Agent.start_link(fn -> init_state end)
    end

    def get(agent), do: Agent.get(agent, & &1)
  end

  defp session_uri, do: Ezagent.URI.new!("session://test/cs/td-test")

  # Build a ctx that reads/writes through an Agent for state tracking.
  defp stateful_ctx(agent) do
    %{
      caller: Ezagent.URI.new!("entity://test/user/admin"),
      self_uri: session_uri(),
      caps: MapSet.new(),
      read: fn key, default ->
        Agent.get(agent, fn state -> Map.get(state, key, default) end)
      end
    }
  end

  # Apply Turn effects to the Agent state (simulates Lifecycle effect processing).
  defp commit_effects(agent, effects) do
    Agent.update(agent, fn state ->
      Enum.reduce(effects, state, fn
        {:set, key, value}, acc -> Map.put(acc, key, value)
        _, acc -> acc
      end)
    end)
  end

  describe "open + compose + settle flow" do
    test "full lifecycle with stateful ctx" do
      {:ok, agent} = CtxAgent.start_link(%{turns: %{}, turn_seq: 0})
      ctx = stateful_ctx(agent)
      sess = session_uri()

      # open
      trigger = %{message_id: "m-1", text: "hello"}
      assert {:ok, %{turn_id: tid}, effects} = TurnDriver.open(sess, trigger, ctx)
      commit_effects(agent, effects)
      assert is_binary(tid)

      # compose
      assert {:ok, %{status: :composing}, effects2} =
               TurnDriver.compose(sess, tid, "bot reply", ctx)
      commit_effects(agent, effects2)

      # settle
      assert {:ok, _, effects3} = TurnDriver.settle(sess, tid, ctx)
      commit_effects(agent, effects3)

      # Verify turn is settled in state
      state = CtxAgent.get(agent)
      turn = Map.get(state[:turns] || %{}, tid)
      assert turn != nil
      assert turn.status == :settled
    end
  end

  describe "claim flow" do
    test "open → compose → claim → settle with stateful ctx" do
      {:ok, agent} = CtxAgent.start_link(%{turns: %{}, turn_seq: 0})
      ctx = stateful_ctx(agent)
      sess = session_uri()

      trigger = %{message_id: "m-claim", text: "help"}
      {:ok, %{turn_id: tid}, e1} = TurnDriver.open(sess, trigger, ctx)
      commit_effects(agent, e1)

      {:ok, %{status: :composing}, e2} =
        TurnDriver.compose(sess, tid, "operator draft", ctx)
      commit_effects(agent, e2)

      op_uri = Ezagent.URI.new!("entity://test/user/op")
      assert {:ok, %{status: :awaiting_human}, e3} =
               TurnDriver.claim(sess, tid, op_uri, ctx)
      commit_effects(agent, e3)

      # settle after claim
      assert {:ok, _, e4} = TurnDriver.settle(sess, tid, ctx)
      commit_effects(agent, e4)

      state = CtxAgent.get(agent)
      turn = Map.get(state[:turns] || %{}, tid)
      assert turn.status == :settled
    end
  end

  describe "cancel" do
    test "cancel an open turn" do
      {:ok, agent} = CtxAgent.start_link(%{turns: %{}, turn_seq: 0})
      ctx = stateful_ctx(agent)
      sess = session_uri()

      trigger = %{message_id: "m-cancel", text: "test"}
      {:ok, %{turn_id: tid}, e1} = TurnDriver.open(sess, trigger, ctx)
      commit_effects(agent, e1)

      assert {:ok, %{status: :cancelled}, e2} = TurnDriver.cancel(sess, tid, ctx)
      commit_effects(agent, e2)

      state = CtxAgent.get(agent)
      turn = Map.get(state[:turns] || %{}, tid)
      assert turn.status == :cancelled
    end
  end

  describe "error cases" do
    test "compose on unknown turn" do
      {:ok, agent} = CtxAgent.start_link(%{turns: %{}, turn_seq: 0})
      ctx = stateful_ctx(agent)

      assert {:error, :unknown_turn} =
               TurnDriver.compose(session_uri(), "nonexistent", "text", ctx)
    end

    test "settle on unknown turn" do
      {:ok, agent} = CtxAgent.start_link(%{turns: %{}, turn_seq: 0})
      ctx = stateful_ctx(agent)

      assert {:error, :unknown_turn} =
               TurnDriver.settle(session_uri(), "nonexistent", ctx)
    end

    test "claim without compose fails" do
      {:ok, agent} = CtxAgent.start_link(%{turns: %{}, turn_seq: 0})
      ctx = stateful_ctx(agent)
      sess = session_uri()

      trigger = %{message_id: "m-no-comp", text: "open only"}
      {:ok, %{turn_id: tid}, e1} = TurnDriver.open(sess, trigger, ctx)
      commit_effects(agent, e1)

      assert {:error, {:illegal_transition, :open}} =
               TurnDriver.claim(sess, tid,
                 Ezagent.URI.new!("entity://test/user/op"), ctx)
    end
  end
end
