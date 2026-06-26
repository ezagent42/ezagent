defmodule Ezagent.Behavior.Kanban.RelayTest do
  @moduledoc """
  B1 验收 — 动作进路由的注入链：`post_handle/4` + `BoardConfig.session_uri` +
  `Shared.session_dispatch/3` 合起来证明「接力动作成功 → 注入 {:dispatch} 到板绑定会话的
  session.send」。这是 sanctioned、可复现的行为级证据（routing/agent-trigger 是通用
  ezagent 设施、已在别处测）。
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Kanban
  alias EzagentPluginKanban.BoardConfig

  setup do
    board = Ezagent.URI.agent("system", "relay-board-#{System.unique_integer([:positive])}")
    caller = Ezagent.URI.new!("entity://system/user/alice")
    {:ok, board: board, caller: caller}
  end

  test "绑定会话的看板：接力动作(claim/status/pr)成功 → 注入一条 session.send dispatch",
       %{board: board, caller: caller} do
    :ok = BoardConfig.write(board, %{session_uri: "session://system/default/main"})
    ctx = %{self_uri: board, caller: caller}

    for action <- [:claim_node, :set_status, :register_pr] do
      assert {:ok, %{}, effects} = Kanban.post_handle(action, %{}, [{:set, :tree, %{}}], ctx)

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert length(dispatches) == 1, "#{action} 应注入恰好一条 {:dispatch}"

      [{:dispatch, cmd}] = dispatches
      assert cmd.action == :send
      assert cmd.target.scheme == "session"
      # 原有的 commit effect 仍在（注入是追加、不替换）
      assert Enum.any?(effects, &match?({:set, :tree, _}, &1))
    end
  end

  test "未绑定会话的看板：接力动作 → 不注入（:cont）", %{board: board, caller: caller} do
    # 没 BoardConfig.write → session_uri = nil
    ctx = %{self_uri: board, caller: caller}
    assert :cont = Kanban.post_handle(:claim_node, %{}, [{:set, :tree, %{}}], ctx)
  end

  test "非接力动作（如 get_tree）→ 不注入（:cont）", %{board: board, caller: caller} do
    :ok = BoardConfig.write(board, %{session_uri: "session://system/default/main"})
    ctx = %{self_uri: board, caller: caller}
    assert :cont = Kanban.post_handle(:get_tree, %{}, [], ctx)
    assert :cont = Kanban.post_handle(:add_node, %{}, [], ctx)
  end

  test "bind_session 与 set_board_config 互不覆盖（BoardConfig 合并写）", %{board: board} do
    ctx = %{self_uri: board}

    assert {:ok, %{github_repo: "o/r"}, []} =
             Kanban.Connectors.set_board_config(
               %{github_repo: "o/r", miro_board: ""},
               ctx
             )

    assert {:ok, %{session_uri: "session://system/default/main"}, []} =
             Kanban.Connectors.bind_session(%{session_uri: "session://system/default/main"}, ctx)

    # 两者都还在
    cfg = BoardConfig.read(board)
    assert cfg.github_repo == "o/r"
    assert cfg.session_uri == "session://system/default/main"
  end
end
