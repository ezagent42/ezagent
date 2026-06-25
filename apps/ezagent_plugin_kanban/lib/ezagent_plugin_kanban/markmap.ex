defmodule EzagentPluginKanban.Markmap do
  @moduledoc """
  思维导图节点树 ↔ markmap markdown 的纯函数互转（无副作用，可往返测试）。

  - 节点 map 形状：`%{id => %{parent_id: id | nil, title: String.t(), order: integer()}}`
  - markdown 用标题层级表达树深：`#`=根（深度 1），`##`=深度 2，依此类推。
  - `parse/1` 用确定性 id（DFS 顺序 `n1..nN`，`n1`=根），所以 `render(parse(md)) == md`
    且 `render(parse(render(tree)))` 幂等。XMind / markmap 都能打开此 markdown。
  """

  @type node_id :: String.t()
  @type tree :: %{nodes: %{node_id => map()}, root_id: node_id | nil}

  @doc "节点树 → markmap markdown（确定性：DFS，兄弟按 `:order` 升序）。"
  @spec render(tree()) :: String.t()
  def render(%{nodes: nodes, root_id: root_id}) when is_map(nodes) and not is_nil(root_id) do
    (do_render(root_id, nodes, 1) |> Enum.join("\n")) <> "\n"
  end

  defp do_render(id, nodes, depth) do
    node = Map.fetch!(nodes, id)
    line = String.duplicate("#", depth) <> " " <> node.title

    children =
      nodes
      |> Enum.filter(fn {_cid, n} -> n.parent_id == id end)
      |> Enum.sort_by(fn {_cid, n} -> n.order end)
      |> Enum.map(fn {cid, _n} -> cid end)

    [line | Enum.flat_map(children, fn cid -> do_render(cid, nodes, depth + 1) end)]
  end

  @doc """
  markmap markdown → 节点树。确定性 id（DFS 顺序 n1..nN）。
  首个标题必须是单 `#`（根）；空/畸形 → `{:error, {:parse_failed, line}}`。
  """
  @spec parse(String.t()) :: {:ok, tree()} | {:error, {:parse_failed, integer()}}
  def parse(md) when is_binary(md) do
    headings =
      md
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, lineno} ->
        case Regex.run(~r/^(\#+)\s+(.+?)\s*$/, line) do
          [_, hashes, title] -> [{String.length(hashes), title, lineno}]
          _ -> []
        end
      end)

    case headings do
      [] ->
        {:error, {:parse_failed, 1}}

      [{1, _t, _ln} | _] = hs ->
        build_tree(hs)

      [{_depth, _t, lineno} | _] ->
        {:error, {:parse_failed, lineno}}
    end
  end

  # 用栈维护祖先 [{depth, id}]，计数器分配确定性 id，order = 父节点已有子数。
  defp build_tree(headings) do
    init = %{nodes: %{}, root_id: nil, seq: 0, stack: [], child_count: %{}}

    result =
      Enum.reduce_while(headings, init, fn {depth, title, lineno}, acc ->
        # 弹出深度 >= 当前的祖先
        stack = Enum.drop_while(acc.stack, fn {d, _id} -> d >= depth end)

        parent_id =
          case stack do
            [{_pd, pid} | _] -> pid
            [] -> nil
          end

        # 深度跳跃（比如 # 后直接 ###）= 畸形
        expected_depth = if parent_id == nil, do: 1, else: parent_depth(stack) + 1

        if depth != expected_depth do
          {:halt, {:error, {:parse_failed, lineno}}}
        else
          seq = acc.seq + 1
          id = "n" <> Integer.to_string(seq)
          order = Map.get(acc.child_count, parent_id, 0)

          node = %{parent_id: parent_id, title: title, order: order}

          acc = %{
            acc
            | nodes: Map.put(acc.nodes, id, node),
              root_id: acc.root_id || id,
              seq: seq,
              stack: [{depth, id} | stack],
              child_count: Map.put(acc.child_count, parent_id, order + 1)
          }

          {:cont, acc}
        end
      end)

    case result do
      {:error, _} = err ->
        err

      %{nodes: nodes, root_id: root_id, seq: seq} ->
        {:ok, %{nodes: nodes, root_id: root_id, seq: seq}}
    end
  end

  defp parent_depth([{d, _id} | _]), do: d
  defp parent_depth([]), do: 0
end
