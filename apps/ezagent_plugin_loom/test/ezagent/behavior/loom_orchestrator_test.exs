defmodule Ezagent.Behavior.LoomOrchestratorTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.LoomOrchestrator
  alias Ezagent.Message

  @policy URI.parse("entity://agent/system/loomworker_main_policy")
  @company URI.parse("entity://agent/system/loomworker_main_company")
  @orch URI.parse("entity://agent/system/loomorch_main")
  @session URI.parse("session://system/s_test")
  @user URI.parse("entity://user/system/tmp_x")

  defp workers, do: [%{uri: @policy, label: "policy"}, %{uri: @company, label: "company"}]

  describe "parse_dispatch/2 (dispatch-phase output → routable subtasks)" do
    test "maps each labelled subtask to its worker URI" do
      raw = ~s({"dispatch":[{"to":"policy","task":"梳理政策"},{"to":"company","task":"匹配企业"}]})
      assert {:ok, entries} = LoomOrchestrator.parse_dispatch(raw, workers())
      assert [%{uri: @policy, task: "梳理政策"}, %{uri: @company, task: "匹配企业"}] = entries
    end

    test "tolerates prose/fence around the JSON" do
      raw = "好的:\n```json\n{\"dispatch\":[{\"to\":\"policy\",\"task\":\"x\"}]}\n```"
      assert {:ok, [%{uri: @policy, task: "x"}]} = LoomOrchestrator.parse_dispatch(raw, workers())
    end

    test "malformed JSON → :error (caller degrades to direct answer)" do
      assert :error = LoomOrchestrator.parse_dispatch("not json at all", workers())
    end

    test "unknown worker label → :error (no routable entries)" do
      raw = ~s({"dispatch":[{"to":"nobody","task":"x"}]})
      assert :error = LoomOrchestrator.parse_dispatch(raw, workers())
    end

    test "empty dispatch array → :error" do
      assert :error = LoomOrchestrator.parse_dispatch(~s({"dispatch":[]}), workers())
    end
  end

  describe "find_turn_by_subtask/2" do
    test "finds the turn whose expected set contains the subtask id" do
      pending = %{
        "t1" => %{expected: MapSet.new(["a", "b"])},
        "t2" => %{expected: MapSet.new(["c"])}
      }

      assert LoomOrchestrator.find_turn_by_subtask(pending, "b") == "t1"
      assert LoomOrchestrator.find_turn_by_subtask(pending, "c") == "t2"
      assert LoomOrchestrator.find_turn_by_subtask(pending, "z") == nil
    end
  end

  describe "handle_receive/2 classification" do
    defp pending_slice do
      turn = %{
        session_uri: @session,
        user_uri: @user,
        persona: "visitor",
        expected: MapSet.new(["sub_policy", "sub_company"]),
        collected: %{}
      }

      %{LoomOrchestrator.init_slice(%{workers: workers()}) | pending: %{"turn1" => turn}}
    end

    # New-contract ctx: `:read` exposes the slice to the handler.
    defp ctx(slice),
      do: %{self_uri: @orch, caller: @session, read: fn k, d -> Map.get(slice, k, d) end}

    test "worker deliverable (ref matches) but not all collected → records fragment via :set, no dispatch" do
      slice = pending_slice()

      reply =
        Message.new(@policy, %{text: "张江专项扶持最高 500 万", attachments: []}, ref_id: "sub_policy")

      assert {:ok, %{}, effects} = LoomOrchestrator.handle_receive(%{message: reply}, ctx(slice))

      # Records the fragment via a `{:set, :pending, _}` effect …
      assert {:set, :pending, new_pending} =
               Enum.find(effects, &match?({:set, :pending, _}, &1))

      turn = new_pending["turn1"]
      assert turn.collected["sub_policy"] == "张江专项扶持最高 500 万"
      # company still outstanding → turn stays pending …
      refute Map.has_key?(turn.collected, "sub_company")
      # … and NO reply is dispatched yet (compose only fires when all collected).
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end

    test "loop-guard: agent message whose ref_id matches no pending subtask → no effects" do
      slice = pending_slice()
      stray = Message.new(@company, %{text: "无关", attachments: []}, ref_id: "not_a_subtask")
      assert {:ok, %{}, []} = LoomOrchestrator.handle_receive(%{message: stray}, ctx(slice))
    end

    test "loop-guard: agent message with no ref_id → no effects" do
      slice = pending_slice()
      stray = Message.new(@company, %{text: "随便说说", attachments: []})
      assert {:ok, %{}, []} = LoomOrchestrator.handle_receive(%{message: stray}, ctx(slice))
    end
  end

  describe "handle_kind_message/3 timeout" do
    test "unknown turn id (already completed) → :ignore" do
      slice = %{LoomOrchestrator.init_slice(%{}) | pending: %{}}

      assert :ignore =
               LoomOrchestrator.handle_kind_message({:agg_timeout, "gone"}, slice, %{
                 self_uri: @orch
               })
    end

    test "unrelated message → :ignore" do
      slice = LoomOrchestrator.init_slice(%{})
      assert :ignore = LoomOrchestrator.handle_kind_message(:tick, slice, %{self_uri: @orch})
    end
  end

  describe "handle_kind_message/3 {:cancel, _} (用户中止 / web_plug /stop)" do
    test "清空在飞回合 → 迟到的 worker deliverable 变 stray 被丢,这一轮彻底丢弃" do
      slice = pending_slice()
      assert map_size(slice.pending) == 1

      assert {:ok, cleared} =
               LoomOrchestrator.handle_kind_message({:cancel, :all}, slice, ctx(slice))

      assert cleared.pending == %{}
    end

    test "pending 已空时中止仍幂等返回(无在飞也不崩)" do
      slice = %{LoomOrchestrator.init_slice(%{}) | pending: %{}}

      assert {:ok, %{pending: %{}}} =
               LoomOrchestrator.handle_kind_message({:cancel, :all}, slice, ctx(slice))
    end

    test "cancel payload 不限于 :all(任意 payload 都清空)" do
      slice = pending_slice()

      assert {:ok, %{pending: %{}}} =
               LoomOrchestrator.handle_kind_message({:cancel, :whatever}, slice, ctx(slice))
    end
  end

  describe "worker_label/1 (S3-B roster discovery)" do
    test "labels loomworker agents by theme; ignores orchestrator + user" do
      assert LoomOrchestrator.worker_label(@policy) == "policy"
      assert LoomOrchestrator.worker_label(@company) == "company"
      assert LoomOrchestrator.worker_label(URI.parse("entity://agent/system/loomorch_s1")) == nil
      assert LoomOrchestrator.worker_label(URI.parse("entity://user/system/tmp_x")) == nil

      # 自定义 worker(worker-config 后,任意 theme suffix 都作 label,供编排器区分派发)。
      assert LoomOrchestrator.worker_label(URI.parse("entity://agent/system/loomworker_s1_extra")) ==
               "extra"
    end
  end
end
