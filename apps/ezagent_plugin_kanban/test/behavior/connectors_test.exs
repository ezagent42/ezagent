defmodule Ezagent.Behavior.Kanban.ConnectorsTest do
  @moduledoc """
  Connectors 纯逻辑 + 行为级单测（Phase 2 入站触发 slice）：

    * doctest —— `pr_already_registered?/2`（register_pr 自幂等判断）+ `pr_sync_action/2`
      （session-gated 入站 poller 触发决策）的纯函数契约；
    * `register_pr/2` 自幂等 —— 同 (节点, PR) 第二次不重复 append artifact（守门员要的去重）。

  真起 poller / 跨插件 dispatch 回 github 网关是 live e2e（github 插件不在 kanban 测试节点），
  本文件不覆——只锁纯决策 + 真相源侧去重。

  `async: false`：setup 写共享的 `BoardConfig`（全局 `kanban-boards.json`，无文件锁的
  read-modify-write），与别的 async BoardConfig 写者并发会丢更新——同步跑避开竞态。
  """
  use ExUnit.Case, async: false

  alias Ezagent.Behavior.Kanban.Connectors
  alias Ezagent.Capability
  alias EzagentPluginKanban.BoardConfig

  doctest Connectors

  describe "register_pr/2 自幂等（按 (repo, node_id, pr) 去重）" do
    setup do
      board = Ezagent.URI.agent("system", "regpr-board-#{System.unique_integer([:positive])}")
      :ok = BoardConfig.write(board, %{github_repo: "o/r"})
      # admin（wildcard `:any` cap）→ 过 owner_or_admin? 闸，专注测去重而非授权。
      caps = MapSet.new([Capability.cap(:any, Connectors, :register_pr)])
      {:ok, board: board, caps: caps}
    end

    test "第一次登记 → commit 一条 pr artifact；第二次同 PR → 不重复 append", %{
      board: board,
      caps: caps
    } do
      tree0 = %{nodes: %{"n1" => %{owner: nil, artifacts: []}}, root_id: "n1", seq: 1, drops: []}
      ctx1 = %{self_uri: board, caps: caps, read: fn :tree, default -> tree0 || default end}

      assert {:ok, %{}, [{:set, :tree, t1}]} =
               Connectors.register_pr(%{id: "n1", pr: "42"}, ctx1)

      assert [%{kind: "pr", ref: "#42"}] = t1.nodes["n1"].artifacts

      # 第二次：树已含该 PR → 自幂等，返回成功但**无 commit**（不重复 append）。
      ctx2 = %{self_uri: board, caps: caps, read: fn :tree, default -> t1 || default end}
      assert {:ok, %{}, []} = Connectors.register_pr(%{id: "n1", pr: "42"}, ctx2)
    end

    test "不同 PR 号 → 不去重，照常 append", %{board: board, caps: caps} do
      tree0 = %{
        nodes: %{"n1" => %{owner: nil, artifacts: [%{tool: "github", kind: "pr", ref: "#42"}]}},
        root_id: "n1",
        seq: 1,
        drops: []
      }

      ctx = %{self_uri: board, caps: caps, read: fn :tree, default -> tree0 || default end}

      assert {:ok, %{}, [{:set, :tree, t1}]} =
               Connectors.register_pr(%{id: "n1", pr: "43"}, ctx)

      refs = Enum.map(t1.nodes["n1"].artifacts, & &1.ref)
      assert "#42" in refs and "#43" in refs
    end
  end
end
