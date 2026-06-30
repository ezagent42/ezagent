defmodule Ezagent.Behavior.Kanban.SharedTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Kanban.Shared

  describe "session_dispatch/3（B1 — 动作进路由的纯 helper）" do
    test "绑定 session → 一条 {:dispatch} 到该 session 的 session.send" do
      self_uri = Ezagent.URI.agent("system", "board-mgr")
      session = Ezagent.URI.new!("session://system/default/main")

      assert [{:dispatch, cmd}] =
               Shared.session_dispatch(session, self_uri, "[kanban:claimed] n6")

      assert cmd.action == :send
      assert cmd.ctx.caller == self_uri
      assert cmd.ctx.reply == :ignore
      assert cmd.target.scheme == "session"
      # 自铸了一条 session-send cap（caller=看板 agent 自己）
      assert Enum.any?(cmd.ctx.caps, &match?(%Ezagent.Capability{action: :send}, &1))
    end

    test "未绑定（nil）/ 非 session URI / 无 self_uri → []（动作照常成功，只是不进路由）" do
      self_uri = Ezagent.URI.agent("system", "board-mgr")
      session = Ezagent.URI.new!("session://system/default/main")

      assert Shared.session_dispatch(nil, self_uri, "x") == []
      assert Shared.session_dispatch("entity://system/agent/foo", self_uri, "x") == []
      assert Shared.session_dispatch("not a uri", self_uri, "x") == []
      assert Shared.session_dispatch(session, nil, "x") == []
    end

    test "字符串形式的 session URI 也认" do
      self_uri = Ezagent.URI.agent("system", "board-mgr")

      assert [{:dispatch, _}] =
               Shared.session_dispatch("session://system/default/main", self_uri, "x")
    end
  end
end
