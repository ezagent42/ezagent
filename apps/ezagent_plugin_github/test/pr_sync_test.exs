defmodule EzagentPluginGithub.PrSyncTest do
  @moduledoc """
  纯逻辑单测：PR↔节点匹配约定（`node_id_for_branch/1`）+ 去重键（`dedup_key/3`）。

  实际轮询（shell out 真 gh）+ 跨插件 dispatch 回 kanban 是 live e2e，本文件不起进程、
  不打真网。
  """
  use ExUnit.Case, async: true

  doctest EzagentPluginGithub.PrSync

  alias EzagentPluginGithub.PrSync

  describe "node_id_for_branch/1（PR↔节点匹配约定）" do
    test "kanban/<node_id> → 节点" do
      assert PrSync.node_id_for_branch("kanban/n7") == {:ok, "n7"}
      assert PrSync.node_id_for_branch("kanban/n123") == {:ok, "n123"}
    end

    test "kanban/<node_id>-slug → 节点（- 分隔）" do
      assert PrSync.node_id_for_branch("kanban/n7-login-form") == {:ok, "n7"}
    end

    test "kanban/<node_id>/slug → 节点（/ 分隔）" do
      assert PrSync.node_id_for_branch("kanban/n12/feature-x") == {:ok, "n12"}
    end

    test "非 kanban 前缀 → :none（非 kanban 跟踪的 PR）" do
      assert PrSync.node_id_for_branch("main") == :none
      assert PrSync.node_id_for_branch("feature/login") == :none
      assert PrSync.node_id_for_branch("n7") == :none
    end

    test "kanban 前缀但 node 段非 n+数字 → :none" do
      assert PrSync.node_id_for_branch("kanban/nope") == :none
      assert PrSync.node_id_for_branch("kanban/n") == :none
      # n7 后紧跟非分隔符（x）→ 不匹配（约定要求边界是 end / `-` / `/`）。
      assert PrSync.node_id_for_branch("kanban/n7x") == :none
    end

    test "nil / 非串 → :none（不 crash）" do
      assert PrSync.node_id_for_branch(nil) == :none
      assert PrSync.node_id_for_branch(42) == :none
      assert PrSync.node_id_for_branch(%{}) == :none
    end
  end

  describe "dedup_key/3（去重键）" do
    test "稳定 + 区分 repo/node/pr" do
      assert PrSync.dedup_key("o/r", "n7", 42) == {:github_pr_registered, "o/r", "n7", 42}
      # 同 repo+node 不同 PR → 不同键。
      refute PrSync.dedup_key("o/r", "n7", 42) == PrSync.dedup_key("o/r", "n7", 43)
      # 同 PR 号不同 node → 不同键。
      refute PrSync.dedup_key("o/r", "n7", 42) == PrSync.dedup_key("o/r", "n8", 42)
      # 同 PR 号不同 repo → 不同键。
      refute PrSync.dedup_key("a/b", "n7", 42) == PrSync.dedup_key("c/d", "n7", 42)
    end
  end
end
