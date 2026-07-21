defmodule Ezagent.ActionSet.KanbanRender do
  @moduledoc """
  kanban-team board view 的 **view read ActionSet**（cap-only，照
  `Ezagent.ActionSet.HelloRender`）。

  ## 两个职责

    * **看的权限门（cap-only）**：声明全仓唯一的 `:kanban_render` read-action。
      `dispatchable?/0 → false`（无 dispatch interface）——它存在只为让
      `{Session, :kanban_render}` 这个 cap subject 被 DECLARE + 注册到 Session
      Kind 上（`EzagentPluginKanban.Application.behaviors/0`，conformance
      assertion 2/9 验的正是这条），供 `Ezagent.UI.SessionView.authorize_view/3`
      检查（`EzagentPluginKanban.BoardView` 的 `view_behavior/0` 指回本模块）。
      action 名带 `kanban_` 业务前缀：dispatch/cap 路由表按 `{kind, action}` 唯一
      （`CapabilityRegistry.check_conflict!` RAISE），共享 `:render` 会在第二个
      view 注册时相撞——业务前缀住产品插件层，非平台层（Allen decision 1 = a）。

    * **产 board 的 json-render tree（只读投影）**：`render_tree/2` 纯函数把
      board actor 的 `:kanban` slice tree + recipe stages 投成 JSON-safe 的
      string-keyed map（hello `@json-render` spec 的 string-key 约定）；
      `external_tree/1` 是 per-session 读入口 —— board 是 workspace 级 actor
      （非 session 成员，S2 建模修正），按 session 的 workspace 经
      `Agent.RecipeResolver.list_by_recipe("kanban-manager", ws)` 枚举（快照来源，
      覆盖 dormant；`EzagentPluginKanban.WorldData.list_instances` 同款），取首个
      board 读它的 `:kanban` slice。**零写**：无 `{:set, ...}`、无 dispatch 写
      action —— 这是投影，不是操作面（操作面是 pm 持 kanban action caps 对 board
      URI dispatch）。

  注册两处（照 hello）：cap subject 走 `Application.behaviors/0`
  （`{Ezagent.Entity.Session, :kanban_render, __MODULE__}`）；SessionView 走
  `Application.start/2` 里 `SessionViewRegistry.register(BoardView)`。渲染由
  world 通用消费 registry 自动接（world-views #1192/#1199），零 world 改动。
  """

  use Ezagent.Lifecycle

  @impl Ezagent.ActionSet
  def actions, do: [:kanban_render]

  @impl Ezagent.ActionSet
  def cap_subjects,
    do: [{:kanban_render, "Read (render) the kanban-team board view for this session."}]

  @impl Ezagent.ActionSet
  def dispatchable?, do: false

  @impl Ezagent.ActionSet
  def interface, do: %{}

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{kanban_render: Ezagent.Capability.cap(:session, __MODULE__, :kanban_render)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  # ------------------------------------------------------------------
  # 只读 board 投影（view 的数据面；全程 fail-safe，坏 board 绝不炸渲染）
  # ------------------------------------------------------------------

  # board = kanban-manager recipe 的 workspace 级 agent（kanban_data.ex 同款常量）。
  @board_role "kanban-manager"

  # stage 外的非 root 节点归入的兜底列（前端渲成「未排期」）。
  @unstaged "unstaged"

  @doc """
  per-session 的 board json-render tree：按 `session_uri` 的 workspace 枚举
  kanban-manager boards（快照来源，覆盖 dormant），取首个（URI 字典序，确定性）
  读 `:kanban` slice 投影。无 board / 读不到 → `nil`（SessionView
  `external_render/1` 契约的 "nothing to render yet"）。
  """
  @spec external_tree(URI.t() | term()) :: map() | nil
  def external_tree(%URI{} = session_uri) do
    case boards_for(session_uri) do
      [] ->
        nil

      [board_uri | _] = boards ->
        session_uri
        |> board_slice_tree(board_uri)
        |> render_tree(stages_from_recipe())
        |> Map.put("board", board_meta(board_uri))
        |> Map.put("boards", Enum.map(boards, &board_meta/1))
    end
  end

  def external_tree(_), do: nil

  @doc """
  本 session workspace 的 kanban-manager board URIs（字典序，确定性首选）。
  `Agent.RecipeResolver.list_by_recipe/2` 是快照来源 —— dormant board 仍枚举得到
  （HIGH-3 同款理由：否则 BEAM 重启后 board view 静默变空）。fail-safe `[]`。

  ## Task 2 —— read-side CBAC 收敛：为何这里不按 caller 权属过滤（需确认边界）

  world 的"发现"列表（`EzagentPluginKanban.WorldData.list_instances/1`）已按 caller
  own/持 cap 收敛（admin 见全 ws）。本入口是 **另一条读面**：SessionView 的
  `external_render/1` json-render 投影，其契约签名只有 `session_uri`
  （`Ezagent.UI.SessionView` `@callback external_render(session_uri :: URI.t())`）
  —— **read-side 无 caller 上下文**，无法在此处按 caller 权属过滤 board。

  这条读面的可见性 **已在上游 cap-gate**：`SessionViewRegistry.external_renderers/2`
  以 caller-aware 的 `SessionView.authorize_view/3` 检查 `{Session, :kanban_render}`
  cap —— 拿不到 render cap 的 caller 根本看不到 board view。故 `boards_for` 只负责
  "本 ws 有哪些 board、按字典序选首个显示"，**不是**可见性闸。

  因此这里 **保守保留**（不盲删可见性、不臆造 caller）：若要把 per-board 权属收敛也
  落到这条读面，需先给 `external_render` 契约穿 caller（跨 UI domain 的契约变更，
  超出 Task 2 边界，标注为 **需确认** 的后续工作）。
  """
  @spec boards_for(URI.t() | term()) :: [URI.t()]
  def boards_for(%URI{} = session_uri) do
    case Ezagent.URI.workspace_of(session_uri) do
      %URI{} = ws ->
        @board_role
        |> Ezagent.Agent.RecipeResolver.list_by_recipe(ws)
        |> Enum.sort_by(&URI.to_string/1)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def boards_for(_), do: []

  @doc """
  纯函数：board 的 `:kanban` slice tree（`%{nodes:, root_id:}`）+ 棒链 stages →
  JSON-safe 的 string-keyed kanban json-render map。每个 stage 一列（保持接力
  顺序），卡片按 `order` 排；stage 为 nil / 不在链上的非 root 节点归 `"unstaged"`
  兜底列（有货才出现）。root 节点是图结构不是卡片。输入不合法退空列（不炸）。
  """
  @spec render_tree(map() | nil, [atom() | String.t()]) :: map()
  def render_tree(tree, stages) do
    stage_names = Enum.map(stages || [], &to_string/1)
    cards = card_nodes(tree)

    columns =
      Enum.map(stage_names, fn stage ->
        %{"stage" => stage, "cards" => cards_in(cards, stage)}
      end)

    unstaged = Enum.reject(cards, fn card -> card["stage"] in stage_names end)

    columns =
      case unstaged do
        [] -> columns
        _ -> columns ++ [%{"stage" => @unstaged, "cards" => sort_cards(unstaged)}]
      end

    %{
      "type" => "kanban_board",
      "stages" => stage_names,
      "columns" => columns
    }
  end

  # --- helpers（全私有；view 只经上面三个公开入口） ----------------------

  # 非 root 节点 → string-keyed card maps（JSON-safe：atom 值 to_string）。
  defp card_nodes(%{} = tree) do
    nodes = Map.get(tree, :nodes) || Map.get(tree, "nodes") || %{}
    root_id = Map.get(tree, :root_id) || Map.get(tree, "root_id")

    nodes
    |> Enum.reject(fn {id, _} -> id == root_id end)
    |> Enum.map(fn {id, node} -> card(id, node) end)
  end

  defp card_nodes(_), do: []

  defp card(id, node) do
    %{
      "id" => id,
      "title" => get(node, :title),
      "parent_id" => get(node, :parent_id),
      "order" => get(node, :order),
      "stage" => to_str(get(node, :stage)),
      "owner" => get(node, :owner),
      "status" => to_str(get(node, :status))
    }
  end

  defp cards_in(cards, stage),
    do: cards |> Enum.filter(&(&1["stage"] == stage)) |> sort_cards()

  defp sort_cards(cards), do: Enum.sort_by(cards, &{&1["order"] || 0, &1["id"]})

  # board 的 `:kanban` slice 里的 tree（真相源）。dormant board 先经核心 owner-gated
  # chokepoint `LocalRuntime.ensure_started/1` 起活（kanban_data.ensure_spawned 同款,
  # HIGH-3 liveness），再 live-only read（§2.2 `Kind.read/3`, `spawn: :never`）；
  # 任何失败退 nil → 空列投影（fail-safe）。
  defp board_slice_tree(_session_uri, %URI{} = board_uri) do
    _ = Ezagent.LocalRuntime.ensure_started(board_uri)

    case Ezagent.Kind.read(board_uri, :kanban, spawn: :never) do
      {:ok, %{} = slice} -> Map.get(slice, :tree) || Map.get(slice, "tree")
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # 棒链 = kanban-manager recipe 的 config.stages（layer-2 数据，read-through over
  # RecipeRegistry；world kanban_data.stages_from_recipe 同款）。无 recipe → []。
  defp stages_from_recipe do
    case Ezagent.Agent.RecipeRegistry.lookup(@board_role) do
      {:ok, %{config: %{} = config}} ->
        case config[:stages] || config["stages"] do
          [_ | _] = stages -> stages
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # encode_uri 独立一行（world kanban_data.ex 同款）：uri_query scan 的
  # `uri_string_key` 探针要求 map-key 语境里不直接 `URI.to_string`。
  defp board_meta(%URI{} = uri) do
    encoded = encode_uri(uri)

    %{
      "uri" => encoded,
      "name" => encoded |> String.split("/") |> List.last()
    }
  end

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)

  defp get(node, key) when is_map(node), do: Map.get(node, key) || Map.get(node, to_string(key))
  defp get(_, _), do: nil

  defp to_str(nil), do: nil
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(s), do: s
end
