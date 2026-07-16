defmodule Ezagent.World.PluginPageRegistry do
  @moduledoc """
  world 内部的**插件页面注册表**——一个插件操作面 = 一条注册数据
  （route + nav + data-builder + action 白名单 + React 组件 key）。

  历史上 kanban 页面在 world 里是写死的一等特例（routes / navigation /
  slot_registry / world_live / main.tsx / slots.manifest 共 6 处硬编码，
  见 2026-07-09 设计 spec）。本模块把"接一个插件页面"收敛为一条数据：

    * `key` — component key（route map 的 `component`、slot renderer family、
      React 组件注册表 map 的 key，三处同名）
    * `route` / `detail_route` — 列表页 + 详情页 pattern（`:param` 段捕获
      单个非空 path segment，语义同原 `[^/]+` 正则）
    * `nav` — 侧栏/patch 白名单派生用的 label + path
    * `data_builder` — `state_for/2` 读模型模块（如 `EzagentPluginKanban.WorldData`）
    * `renderer_families` — 注入 `SlotRegistry` 的 `[{type, title}]`
    * `action_prefixes` + `actions` — dispatch 准入：前缀是粗筛，`actions`
      是细白名单，**前缀命中后仍逐动作校验**（fail-closed，对齐 P22 精神）
    * `actions_module` — `handle_dispatch/3` 动作处理模块

  **fail-closed**：未注册的 key / route / action 一律返回 `nil`，无兜底放行。
  编译期常量起步；插件自声明协议（`UiSurfaceProvider` 扩展）留给 follow-up。
  """

  # kanban 动作细白名单——从 WorldLive `@kanban_actions` 逐字迁入（2026-07-09），
  # 与 `EzagentPluginKanban.WorldActions.handle_dispatch/3` 的字面子句逐一等价
  # （等价锁在 plugin_page_registry_test.exs）。
  # ⑲（显式决策 2026-07-16）：`kanban.delete_board` 加入 dispatch 准入白名单（板主人删板）。
  @kanban_actions ~w(kanban.add_node kanban.rename_node kanban.move_node kanban.remove_node kanban.set_stage kanban.claim_node kanban.unclaim_node kanban.set_status kanban.attach_artifact kanban.detach_artifact kanban.set_metric kanban.create kanban.sync_miro kanban.save_miro_creds kanban.select_board kanban.drop_subtree kanban.set_board_config kanban.attach_upload kanban.register_pr kanban.attach_code_file kanban.share_board kanban.delete_board)

  @pages [
    # kanban 操作面（kanban-as-role K4）——注册表第一个条目，原 world 写死特例。
    %{
      key: "kanban",
      route: {"/plugins/kanban", :index},
      detail_route: {"/plugins/kanban/:id", :detail},
      nav: %{label: "看板", path: "/plugins/kanban"},
      data_builder: EzagentPluginKanban.WorldData,
      renderer_families: [{"kanban", "看板"}],
      action_prefixes: ["kanban."],
      actions: @kanban_actions,
      actions_module: EzagentPluginKanban.WorldActions
    }
  ]

  @type page :: %{
          key: String.t(),
          route: {String.t(), :index},
          detail_route: {String.t(), :detail},
          nav: %{label: String.t(), path: String.t()},
          data_builder: module(),
          renderer_families: [{String.t(), String.t()}],
          action_prefixes: [String.t()],
          actions: [String.t()],
          actions_module: module()
        }

  @doc "全部注册页面（声明顺序）。"
  @spec pages() :: [page()]
  def pages, do: @pages

  @doc "按 component key 查页面；未注册 → `nil`（fail-closed）。"
  @spec by_key(String.t() | any()) :: page() | nil
  def by_key(key) when is_binary(key), do: Enum.find(@pages, &(&1.key == key))
  def by_key(_), do: nil

  @doc """
  按浏览器 path 匹配页面 route / detail_route。

  返回 `{page, params}`，`params` 是 `:param` 段捕获的**原始（仍 URL 编码）**
  segment（如 `%{"id" => encoded}`；列表页 → `%{}`）。不匹配 → `nil`。
  """
  @spec by_route(String.t() | any()) :: {page(), %{String.t() => String.t()}} | nil
  def by_route(path) when is_binary(path) do
    Enum.find_value(@pages, fn page ->
      case match_page(page, path) do
        nil -> nil
        params -> {page, params}
      end
    end)
  end

  def by_route(_), do: nil

  @doc """
  dispatch 准入：action 命中某页面的 `action_prefixes` **且**在其 `actions`
  细白名单内才返回该页面；否则 `nil`（fail-closed，前缀不是放行面）。
  """
  @spec by_action(String.t() | any()) :: page() | nil
  def by_action(action) when is_binary(action) do
    Enum.find(@pages, fn page ->
      Enum.any?(page.action_prefixes, &String.starts_with?(action, &1)) and
        action in page.actions
    end)
  end

  def by_action(_), do: nil

  defp match_page(page, path) do
    {index_pattern, :index} = page.route
    {detail_pattern, :detail} = page.detail_route

    match_pattern(index_pattern, path) || match_pattern(detail_pattern, path)
  end

  # `:param` 段捕获单个非空 segment；空 segment / 尾斜线 / 段数不符都不匹配
  # （与原 `\A/plugins/kanban/([^/]+)\z` 正则同形）。pattern 编译为锚定正则
  # 而非路径切段——URI/路径切段必须收敛在 Ezagent.URI/UriQuery
  # （uri_query.scan 的 tenant_derivation 规则），注册表只做正则匹配。
  defp match_pattern(pattern, path) do
    source =
      pattern
      |> Regex.escape()
      |> then(&Regex.replace(~r/:(\w+)/, &1, "(?<\\1>[^/]+)"))

    Regex.named_captures(Regex.compile!("\\A" <> source <> "\\z"), path)
  end
end
