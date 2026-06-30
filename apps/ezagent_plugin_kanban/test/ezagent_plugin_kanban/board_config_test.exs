defmodule EzagentPluginKanban.BoardConfigTest do
  @moduledoc """
  `BoardConfig` 反查（session→板）单测（Layer-3 session tab 条件渲染前置）。

  `async: false`：写共享的全局 `kanban-boards.json`（无文件锁的 read-modify-write），
  与别的 async BoardConfig 写者并发会丢更新——同步跑避开竞态（对齐 ConnectorsTest）。
  """
  use ExUnit.Case, async: false

  alias EzagentPluginKanban.BoardConfig

  defp uniq, do: System.unique_integer([:positive])

  describe "boards_for_session/1 + session_bound?/1 反查" do
    test "bind_session 写后，反查返回补存的完整 board URI" do
      board = Ezagent.URI.agent("system", "bf-board-#{uniq()}")
      session = "session://system/default/bf-#{uniq()}"

      :ok = BoardConfig.write(board, %{session_uri: session})

      assert BoardConfig.boards_for_session(session) == [URI.to_string(board)]
      assert BoardConfig.session_bound?(session) == true
    end

    test "未绑定的 session → 空 / false" do
      session = "session://system/default/unbound-#{uniq()}"
      assert BoardConfig.boards_for_session(session) == []
      assert BoardConfig.session_bound?(session) == false
    end

    test "只配出站（无 session_uri）的板不会冒出来" do
      board = Ezagent.URI.agent("system", "bf-noses-#{uniq()}")
      session = "session://system/default/probe-#{uniq()}"
      :ok = BoardConfig.write(board, %{github_repo: "o/r"})

      assert BoardConfig.boards_for_session(session) == []
    end

    test "接受 %URI{} session 入参（与 string 等价）" do
      board = Ezagent.URI.agent("system", "bf-uri-#{uniq()}")
      session_uri = Ezagent.URI.new!("session://system/default/bfuri-#{uniq()}")
      :ok = BoardConfig.write(board, %{session_uri: URI.to_string(session_uri)})

      assert BoardConfig.boards_for_session(session_uri) == [URI.to_string(board)]
      assert BoardConfig.session_bound?(session_uri) == true
    end

    test "write/2 把 board URI 補存进 entry（key 是 stable_key 可能不可逆）" do
      board = Ezagent.URI.agent("system", "bf-back-#{uniq()}")
      :ok = BoardConfig.write(board, %{github_repo: "o/r"})

      key = Ezagent.URI.stable_key(board)
      assert BoardConfig.read_all()[key]["uri"] == URI.to_string(board)
    end
  end
end
