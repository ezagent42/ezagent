defmodule Ezagent.PluginLoom.Lineage do
  @moduledoc """
  Loom **衍生谱系**(2026-06-16)。

  > 命名:叫 "lineage / 谱系",**不要**跟 ezagent 的 Kind snapshot 或 loom share
  > snapshot 混。这里只记 *谁从谁衍生*,不存任何状态。

  ## 为什么存在

  每次发布会生成一个**全套**(带 loom 那一套)的 Template Class `session.pub_<hex>`,
  方便以后从它再衍生别的;但 registry 是**扁平**的——一堆 `pub_*` 类 + 一堆冻结的
  消费 session,看不出*谁从谁来*。本模块给每个衍生物记**一个 typed parent 指针**,
  谱系树就是这些指针的传递闭包(树本身**算出来**,不冗余存)。

  ## 三种关系(Loom 流程里仅有的三种)

  | rel | from → to | 含义 |
  |---|---|---|
  | `published_from` | 模板 `session.pub_xxx` → 创作 session | 此模板由这个 session 在某时刻发布 |
  | `derived_from`   | 冻结消费 session → 模板 | 此冻结实例由这个模板 mint |
  | `forked_from`    | 可编辑 fork session → 消费 session | 此 fork 从那个消费 session 的分享快照衍生 |

  fork 自己可编辑、可再发布,故三种指针**组合成多层树**:

      创作 session (zuatu)
       └ pub_a1b2   (模板 · published_from zuatu · v1)
           └ session://…/pub_xxx    (冻结 · derived_from pub_a1b2)
               └ session://…/pub_yyy (fork · forked_from pub_xxx)
                   └ pub_c3d4         (模板 · published_from pub_yyy · v1)

  ## 持久化(旁路 JSON)

  `~/.ezagent/<profile>/loom_lineage.json`,key = 节点 ref:

      %{ "<node_ref>" => %{
           "kind"   => "template" | "consumer" | "fork",
           "ws"     => ws,
           "parent" => %{"rel" => ..., "ref" => ...},
           "at"     => iso8601,
           # template-only:
           "token"  => ..., "description" => ..., "gen" => 1
         } }

  节点 ref:模板用 class_name(`session.pub_xxx`),消费/fork 用 session URI
  (`session://loom/<ws>/<sid>`)。
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_lineage.json")
  end

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp save_all(map) when is_map(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp session_uri(ws, sid), do: "session://loom/#{ws}/#{sid}"

  @doc """
  记一次**发布**:模板 `class_name` 由 `from_sid`(创作 session)发布。

  `gen`(第几版)= 同一创作 session 已有模板数 + 1,用于在树里标 v1/v2/…
  """
  @spec record_publish(String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok
  def record_publish(ws, from_sid, class_name, token, description)
      when is_binary(ws) and is_binary(from_sid) and is_binary(class_name) do
    map = load_all()
    parent_ref = session_uri(ws, from_sid)

    gen =
      map
      |> Enum.count(fn {_k, v} ->
        v["kind"] == "template" && get_in(v, ["parent", "ref"]) == parent_ref
      end)
      |> Kernel.+(1)

    node = %{
      "kind" => "template",
      "ws" => ws,
      "parent" => %{"rel" => "published_from", "ref" => parent_ref},
      "token" => token,
      "description" => description,
      "gen" => gen,
      "at" => now()
    }

    map |> Map.put(class_name, node) |> save_all()
  rescue
    _ -> :ok
  end

  @doc "记一次**打开发布物**:消费 session `sid` 由模板 `class_name` mint(冻结实例)。"
  @spec record_consume(String.t(), String.t(), String.t()) :: :ok
  def record_consume(ws, sid, class_name)
      when is_binary(ws) and is_binary(sid) and is_binary(class_name) do
    node = %{
      "kind" => "consumer",
      "ws" => ws,
      "parent" => %{"rel" => "derived_from", "ref" => class_name},
      "at" => now()
    }

    load_all() |> Map.put(session_uri(ws, sid), node) |> save_all()
  rescue
    _ -> :ok
  end

  @doc """
  记一次**fork**:fork session `sid` 从消费 session `origin_sid` 的分享快照衍生。

  `origin_sid` 是分享快照里冻结的 `origin_sid`(被分享的那个消费/preview session);
  若它本身在谱系里有记录,fork 就自然挂到它下面(模板 → 消费 → fork)。
  """
  @spec record_fork(String.t(), String.t(), String.t() | nil) :: :ok
  def record_fork(ws, sid, origin_sid) when is_binary(ws) and is_binary(sid) do
    parent_ref =
      case origin_sid do
        s when is_binary(s) and s != "" -> session_uri(ws, s)
        _ -> nil
      end

    node = %{
      "kind" => "fork",
      "ws" => ws,
      "parent" => %{"rel" => "forked_from", "ref" => parent_ref},
      "at" => now()
    }

    load_all() |> Map.put(session_uri(ws, sid), node) |> save_all()
  rescue
    _ -> :ok
  end

  @doc "删一个节点(模板被删 / 会话被删时调用,保持谱系干净)。"
  @spec forget(String.t()) :: :ok
  def forget(ref) when is_binary(ref) do
    map = load_all()

    if Map.has_key?(map, ref) do
      map |> Map.delete(ref) |> save_all()
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  本 ws 的谱系**树**:根 = 创作 session(被引用作 parent、但自身不是节点),
  每个根下递归挂子节点。返回

      [%{
        "ref" => ..., "kind" => "root"|"template"|"consumer"|"fork",
        "rel" => parent 关系(根为 nil), "ws" => ws,
        "token"/"description"/"gen"/"at" => ...(各 kind 有的字段),
        "children" => [...同结构...]
      }]
  """
  @spec tree(String.t()) :: [map()]
  def tree(ws) when is_binary(ws) do
    nodes =
      load_all()
      |> Enum.filter(fn {_k, v} -> v["ws"] == ws end)
      |> Map.new()

    keys = MapSet.new(Map.keys(nodes))

    # parent_ref → [child_ref...]
    children =
      Enum.reduce(nodes, %{}, fn {ref, v}, acc ->
        p = get_in(v, ["parent", "ref"])

        if is_binary(p) do
          Map.update(acc, p, [ref], &[ref | &1])
        else
          # 孤儿(无 parent ref)直接当根挂在合成 "(unknown)" 下不友好 → 当独立根。
          Map.update(acc, :__orphans__, [ref], &[ref | &1])
        end
      end)

    # 根 ref = 出现在某 parent 里、但自身不是节点(= 创作 session)。
    root_refs =
      nodes
      |> Enum.map(fn {_k, v} -> get_in(v, ["parent", "ref"]) end)
      |> Enum.filter(&(is_binary(&1) && !MapSet.member?(keys, &1)))
      |> Enum.uniq()

    roots =
      Enum.map(root_refs, fn rref ->
        %{
          "ref" => rref,
          "kind" => "root",
          "rel" => nil,
          "ws" => ws,
          "children" => build_children(rref, nodes, children)
        }
      end)

    orphan_roots =
      Map.get(children, :__orphans__, [])
      |> Enum.map(&build_node(&1, Map.get(nodes, &1), nodes, children))

    (roots ++ orphan_roots)
    |> Enum.sort_by(& &1["ref"])
  end

  defp build_children(parent_ref, nodes, children) do
    children
    |> Map.get(parent_ref, [])
    |> Enum.map(&build_node(&1, Map.get(nodes, &1), nodes, children))
    |> Enum.sort_by(&{&1["at"] || "", &1["ref"]})
  end

  defp build_node(ref, v, nodes, children) when is_map(v) do
    v
    |> Map.take(["kind", "ws", "token", "description", "gen", "at"])
    |> Map.put("ref", ref)
    |> Map.put("rel", get_in(v, ["parent", "ref"]) && get_in(v, ["parent", "rel"]))
    |> Map.put("children", build_children(ref, nodes, children))
  end

  defp build_node(ref, _v, _nodes, _children) do
    %{"ref" => ref, "kind" => "unknown", "rel" => nil, "children" => []}
  end
end
