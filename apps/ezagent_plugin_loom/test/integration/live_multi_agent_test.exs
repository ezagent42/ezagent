defmodule EzagentPluginLoom.Integration.LiveMultiAgentTest do
  @moduledoc """
  LIVE: 完整多 agent 编排 —— decompose → 并发 themed worker → 聚合 compose。

  需 `DEEPSEEK_API_KEY`(provider key),默认排除(`:live`)。跑:
  `DEEPSEEK_API_KEY=sk-... mix test --include live \
     apps/ezagent_plugin_loom/test/integration/live_multi_agent_test.exs`

  验证 `Orchestrator.run/1` 走完整多 agent 路径(非单 agent 兜底)产出可用 result_refs。
  """
  use ExUnit.Case, async: false
  @moduletag :live
  @moduletag timeout: 180_000

  alias EzagentPluginLoom.Orchestrator

  @valid_node_types ~w(text services companies detail steps form choices notice application intent page)

  test "run/1 decomposes, fans out themed workers, and composes a scene" do
    assert {:ok, result_refs} =
             Orchestrator.run("帮我做一个卖手冲咖啡的落地页，要有产品、冲煮指南和下单入口")

    assert [%{kind: :chat, text: chat}, %{kind: :page, tree: page}] = result_refs
    assert is_binary(chat) and chat != ""

    assert %{"type" => root_type, "children" => children} = page
    assert root_type in @valid_node_types
    assert is_list(children)
    # 多主题素材聚合后,页面通常有若干子节点
    assert length(children) >= 1

    # 所有节点 type 合法(normalize_tree 保证)
    assert Enum.all?(flatten_types(page), &(&1 in @valid_node_types))
  end

  defp flatten_types(%{"type" => t, "children" => children}) do
    [t | Enum.flat_map(children, &flatten_types/1)]
  end

  defp flatten_types(_), do: []
end
