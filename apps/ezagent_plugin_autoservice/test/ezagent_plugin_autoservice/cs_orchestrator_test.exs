defmodule EzagentPluginAutoservice.CsOrchestratorTest do
  @moduledoc """
  CsOrchestrator Behavior unit tests for Session + Behavior architecture.

  Uses stateful ctx (Agent-backed) to simulate Lifecycle effect commit.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Message
  alias Ezagent.Behavior.CsOrchestrator

  @uri Ezagent.URI

  defmodule CtxAgent do
    use Agent
    def start_link(state), do: Agent.start_link(fn -> state end)
    def get(a), do: Agent.get(a, & &1)
    def update(a, f), do: Agent.update(a, f)
  end

  defp session_uri, do: @uri.new!("session://test/cs/test-orch")
  defp operator_uri, do: @uri.new!("entity://test/user/op")

  defp bootstrap_caps do
    MapSet.new([
      %Ezagent.Capability{
        kind: :any, behavior: :any, action: :any,
        instance: :any, workspace_uri: :any,
        granted_by: @uri.new!("system://bootstrap/default"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
    ])
  end

  defp customer_msg(text) do
    Message.new(@uri.new!("entity://test/user/customer"), %{text: text, attachments: []})
  end

  # ---- Lifecycle hooks ----

  describe "Lifecycle hooks" do
    test "create/1" do
      assert {:ok, %{open_turn_id: nil, operator_active: false}} =
               CsOrchestrator.create(%{})
    end

    test "activate/2" do
      assert {:ok, %{}} = CsOrchestrator.activate(%{}, %{})
    end

    test "reads_siblings" do
      assert CsOrchestrator.reads_siblings() == [:turns]
    end
  end

  # ---- process_message: customer with stateful ctx ----

  describe "handle_process_message/2 — customer (stateful)" do
    test "opens turn and returns effects" do
      {:ok, agent} = CtxAgent.start_link(%{
        cs_orchestrator: %{open_turn_id: nil, operator_active: false},
        turns: %{}, turn_seq: 0
      })
      ctx = fake_ctx(agent)
      msg = customer_msg("hello")

      result = CsOrchestrator.handle_process_message(%{message: msg}, ctx)
      assert {:ok, %{ok: true}, effects} = result

      # Apply effects to state
      apply_effects(agent, effects)
      state = CtxAgent.get(agent)

      cs = state[:cs_orchestrator]
      assert is_binary(cs[:open_turn_id])
      assert map_size(state[:turns] || %{}) >= 1
    end
  end

  # ---- operator_claim: cancel + reopen ----

  describe "handle_operator_claim/2 (stateful)" do
    test "opens fresh turn when no bot turn" do
      {:ok, agent} = CtxAgent.start_link(%{
        cs_orchestrator: %{open_turn_id: nil, operator_active: false},
        turns: %{}, turn_seq: 0
      })
      ctx = fake_ctx(agent)

      result = CsOrchestrator.handle_operator_claim(%{
        operator_uri: operator_uri(),
        operator_text: "接管"
      }, ctx)

      # The claim handler chains open → compose → claim. This works
      # because apply_turn_effects patches :read between calls.
      assert {:ok, %{ok: true, turn_id: tid}, effects} = result
      assert is_binary(tid)

      apply_effects(agent, effects)
      cs = CtxAgent.get(agent)[:cs_orchestrator]
      assert cs[:operator_active] == true
      assert is_binary(cs[:open_turn_id])
    end

    test "operator_claim with existing bot turn (cancel first)" do
      {:ok, agent} = CtxAgent.start_link(%{
        cs_orchestrator: %{open_turn_id: "bot-turn-1", operator_active: false},
        turns: %{"bot-turn-1" => %{status: :composing, mode: :auto}},
        turn_seq: 3
      })
      ctx = fake_ctx(agent)

      result = CsOrchestrator.handle_operator_claim(%{
        operator_uri: operator_uri(),
        operator_text: "接管"
      }, ctx)

      assert {:ok, %{ok: true, turn_id: tid}, effects} = result
      assert is_binary(tid)

      apply_effects(agent, effects)
      state = CtxAgent.get(agent)
      cs = state[:cs_orchestrator]
      assert cs[:operator_active] == true
      # Old bot turn should be cancelled
      bot_turn = Map.get(state[:turns] || %{}, "bot-turn-1")
      assert bot_turn.status == :cancelled
    end
  end

  # ---- operator_settle ----

  describe "handle_operator_settle/2 (stateful)" do
    test "returns ok: false when nil open_turn_id" do
      {:ok, agent} = CtxAgent.start_link(%{
        cs_orchestrator: %{open_turn_id: nil, operator_active: false},
        turns: %{}, turn_seq: 0
      })
      ctx = fake_ctx(agent)

      assert {:ok, %{ok: false}, []} =
               CsOrchestrator.handle_operator_settle(%{}, ctx)
    end
  end

  # ---- Minimal handler tests (pure result shapes) ----

  describe "handle_process_message/2 return shapes" do
    test "returns 3-tuple {status, result, effects}" do
      {:ok, agent} = CtxAgent.start_link(%{
        cs_orchestrator: %{open_turn_id: nil, operator_active: false},
        turns: %{}, turn_seq: 0
      })
      msg = customer_msg("hello")

      case CsOrchestrator.handle_process_message(%{message: msg}, fake_ctx(agent)) do
        {:ok, result, effects} when is_map(result) and is_list(effects) -> assert true
        other -> flunk("Expected {:ok, %{}, []} got #{inspect(other)}")
      end
    end
  end

  # ---- Helpers ----

  defp fake_ctx(agent) do
    agent_pid = agent

    read_fn = fn key, default ->
      state = CtxAgent.get(agent_pid)
      case key do
        k when k in [:open_turn_id, :operator_active] ->
          Map.get(state[:cs_orchestrator] || %{}, k, default)
        _ ->
          Map.get(state, key, default)
      end
    end

    %{
      self_uri: session_uri(),
      caller: @uri.new!("entity://test/user/customer"),
      caps: bootstrap_caps(),
      read: read_fn,
      siblings: %{}
    }
  end

  defp apply_effects(agent, effects) do
    CtxAgent.update(agent, fn state ->
      Enum.reduce(effects, state, fn
        {:set, :open_turn_id, value}, acc ->
          cs = Map.get(acc, :cs_orchestrator, %{})
          Map.put(acc, :cs_orchestrator, Map.put(cs, :open_turn_id, value))

        {:set, :operator_active, value}, acc ->
          cs = Map.get(acc, :cs_orchestrator, %{})
          Map.put(acc, :cs_orchestrator, Map.put(cs, :operator_active, value))

        {:set, key, value}, acc ->
          Map.put(acc, key, value)

        _, acc ->
          acc
      end)
    end)
  end
end
