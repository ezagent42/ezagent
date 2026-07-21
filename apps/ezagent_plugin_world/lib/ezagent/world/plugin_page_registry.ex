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
    * `data_builder` — 插件自有的 `state_for/2` 读模型模块
    * `renderer_families` — 注入 `SlotRegistry` 的 `[{type, title}]`
    * `action_prefixes` + `actions` — dispatch 准入：前缀是粗筛，`actions`
      是细白名单，**前缀命中后仍逐动作校验**（fail-closed，对齐 P22 精神）
    * `actions_module` — `handle_dispatch/3` 动作处理模块

  **fail-closed**：未注册的 key / route / action 一律返回 `nil`，无兜底放行。
  编译期常量起步；插件自声明协议（`UiSurfaceProvider` 扩展）留给 follow-up。
  """

  @type page :: %{
          optional(:session_view) => %{id: String.t(), state_builder: module()},
          key: String.t(),
          route: {String.t(), :index},
          detail_route: {String.t(), :detail},
          nav: %{label: String.t(), path: String.t()},
          data_builder: module(),
          renderer_families: [{String.t(), String.t()}],
          actions: [String.t()],
          actions_module: module(),
          provider: module()
        }

  @doc "全部注册页面（声明顺序）。"
  @spec pages() :: [page()]
  def pages, do: load().pages

  @doc "Diagnostics for declarations rejected by the fail-closed registry."
  @spec diagnostics() :: [term()]
  def diagnostics, do: load().diagnostics

  @doc false
  @spec resolve([{module(), term()}]) :: %{pages: [page()], diagnostics: [term()]}
  def resolve(provider_declarations) when is_list(provider_declarations) do
    {valid, invalid_diagnostics} =
      provider_declarations
      |> Enum.flat_map(fn {provider, declarations} ->
        if is_list(declarations) do
          declarations
          |> Enum.with_index()
          |> Enum.map(fn {page, index} -> {provider, index, page} end)
        else
          [{provider, 0, :invalid_callback_result}]
        end
      end)
      |> Enum.reduce({[], []}, fn {provider, index, page}, {valid, diagnostics} ->
        case Ezagent.World.UiSurfaceProvider.validate_page(page) do
          :ok -> {[%{provider: provider, index: index, page: page} | valid], diagnostics}
          {:error, errors} -> {valid, [{:invalid_page, provider, index, errors} | diagnostics]}
        end
      end)

    valid = Enum.reverse(valid)
    duplicates = duplicate_diagnostics(valid)

    rejected =
      duplicates
      |> Enum.flat_map(fn {:duplicate, _field, _value, owners} -> owners end)
      |> MapSet.new()

    pages =
      for %{provider: provider, index: index, page: page} <- valid,
          not MapSet.member?(rejected, {provider, index}),
          do: Map.put(page, :provider, provider)

    %{pages: pages, diagnostics: Enum.reverse(invalid_diagnostics) ++ duplicates}
  end

  @doc "按 component key 查页面；未注册 → `nil`（fail-closed）。"
  @spec by_key(String.t() | any()) :: page() | nil
  def by_key(key) when is_binary(key), do: Enum.find(pages(), &(&1.key == key))
  def by_key(_), do: nil

  @doc """
  按浏览器 path 匹配页面 route / detail_route。

  返回 `{page, params}`，`params` 是 `:param` 段捕获的**原始（仍 URL 编码）**
  segment（如 `%{"id" => encoded}`；列表页 → `%{}`）。不匹配 → `nil`。
  """
  @spec by_route(String.t() | any()) :: {page(), %{String.t() => String.t()}} | nil
  def by_route(path) when is_binary(path) do
    Enum.find_value(pages(), fn page ->
      case match_page(page, path) do
        nil -> nil
        params -> {page, params}
      end
    end)
  end

  def by_route(_), do: nil

  @doc "Find the page that declares a session view id; unregistered ids return `nil`."
  @spec by_session_view(String.t() | any()) :: page() | nil
  def by_session_view(view_id) when is_binary(view_id) do
    Enum.find(pages(), fn page -> get_in(page, [:session_view, :id]) == view_id end)
  end

  def by_session_view(_), do: nil

  @doc """
  dispatch 准入：action 命中某页面的 `action_prefixes` **且**在其 `actions`
  细白名单内才返回该页面；否则 `nil`（fail-closed，前缀不是放行面）。
  """
  @spec by_action(String.t() | any()) :: page() | nil
  def by_action(action) when is_binary(action) do
    Enum.find(pages(), fn page -> action in page.actions end)
  end

  def by_action(_), do: nil

  defp load do
    {declarations, callback_diagnostics} =
      Ezagent.PluginRegistry.list_all()
      |> Enum.sort_by(fn plugin -> plugin.plugin_info().slug end)
      |> Enum.filter(&function_exported?(&1, :pages, 0))
      |> Enum.reduce({[], []}, fn plugin, {declarations, diagnostics} ->
        try do
          case plugin.pages() do
            pages when is_list(pages) -> {[{plugin, pages} | declarations], diagnostics}
            _ -> {declarations, [{:invalid_pages_callback, plugin, :not_a_list} | diagnostics]}
          end
        rescue
          error ->
            {declarations,
             [{:invalid_pages_callback, plugin, Exception.message(error)} | diagnostics]}
        end
      end)

    resolved = declarations |> Enum.reverse() |> resolve()
    %{resolved | diagnostics: Enum.reverse(callback_diagnostics) ++ resolved.diagnostics}
  end

  defp duplicate_diagnostics(records) do
    [
      {:key, fn page -> [page.key] end},
      {:route, fn page -> [elem(page.route, 0), elem(page.detail_route, 0)] end},
      {:renderer_family, fn page -> Enum.map(page.renderer_families, &elem(&1, 0)) end},
      {:session_view,
       fn page -> page |> Map.get(:session_view) |> then(&if(&1, do: [&1.id], else: [])) end},
      {:action, fn page -> page.actions end}
    ]
    |> Enum.flat_map(fn {field, values} ->
      records
      |> Enum.flat_map(fn record ->
        Enum.map(values.(record.page), &{&1, {record.provider, record.index}})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn
        {_value, [_owner]} -> []
        {value, owners} -> [{:duplicate, field, value, Enum.uniq(owners)}]
      end)
    end)
    |> Enum.sort_by(&inspect/1)
  end

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
