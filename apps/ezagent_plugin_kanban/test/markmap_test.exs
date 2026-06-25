defmodule EzagentPluginKanban.MarkmapTest do
  @moduledoc """
  Markmap 纯函数 render/parse 的往返与边界测试。
  节点 map 形状：`%{id => %{parent_id: id|nil, title: String.t(), order: int}}`。
  parse 用确定性 id（DFS 顺序 n1..nN，n1=根）。
  """
  use ExUnit.Case, async: true

  alias EzagentPluginKanban.Markmap

  describe "render/1" do
    test "单根" do
      tree = %{nodes: %{"n1" => %{parent_id: nil, title: "根", order: 0}}, root_id: "n1"}
      assert Markmap.render(tree) == "# 根\n"
    end

    test "三层 + 中文，按 order 排兄弟" do
      tree = %{
        root_id: "n1",
        nodes: %{
          "n1" => %{parent_id: nil, title: "根", order: 0},
          "n2" => %{parent_id: "n1", title: "子1", order: 0},
          "n3" => %{parent_id: "n2", title: "孙", order: 0},
          "n4" => %{parent_id: "n1", title: "子2", order: 1}
        }
      }

      assert Markmap.render(tree) == "# 根\n## 子1\n### 孙\n## 子2\n"
    end
  end

  describe "parse/1" do
    test "解析三层，确定性 id（DFS 顺序）" do
      md = "# 根\n## 子1\n### 孙\n## 子2\n"
      assert {:ok, %{nodes: nodes, root_id: "n1", seq: 4}} = Markmap.parse(md)
      assert nodes["n1"] == %{parent_id: nil, title: "根", order: 0}
      assert nodes["n2"] == %{parent_id: "n1", title: "子1", order: 0}
      assert nodes["n3"] == %{parent_id: "n2", title: "孙", order: 0}
      assert nodes["n4"] == %{parent_id: "n1", title: "子2", order: 1}
    end

    test "空 markdown → parse_failed" do
      assert {:error, {:parse_failed, _}} = Markmap.parse("")
      assert {:error, {:parse_failed, _}} = Markmap.parse("\n\n  \n")
    end

    test "首个标题不是单 # 根 → parse_failed 带行号" do
      assert {:error, {:parse_failed, 1}} = Markmap.parse("## 不是根\n")
    end
  end

  describe "往返不变式" do
    test "render(parse(md)) == md（规范 md）" do
      md = "# 根\n## 子1\n### 孙\n## 子2\n"
      assert {:ok, tree} = Markmap.parse(md)
      assert Markmap.render(tree) == md
    end

    test "render(parse(render(tree))) == render(tree)（幂等）" do
      tree = %{
        root_id: "n1",
        nodes: %{
          "n1" => %{parent_id: nil, title: "Root", order: 0},
          "n2" => %{parent_id: "n1", title: "A", order: 0},
          "n3" => %{parent_id: "n1", title: "B", order: 1}
        }
      }

      once = Markmap.render(tree)
      assert {:ok, t2} = Markmap.parse(once)
      assert Markmap.render(t2) == once
    end
  end
end
