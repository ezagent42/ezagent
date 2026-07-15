defmodule Ezagent.ActionSet.CrawlerRender do
  @moduledoc """
  crawler 线索页的 **view read ActionSet**（cap-only，照
  `Ezagent.ActionSet.KanbanRender` / `Ezagent.ActionSet.HelloRender` 模具）。

  ## 两个职责

    * **看的权限门（cap-only）**：声明全仓唯一的 `:crawler_render` read-action。
      `dispatchable?/0 → false`（无 dispatch interface）——它存在只为让
      `{Session, :crawler_render}` 这个 cap subject 被 DECLARE + 注册到 Session
      Kind 上（`EzagentPluginCrawler.Application.behaviors/0`，conformance
      的 views 断言验的正是这条），供 `Ezagent.UI.SessionView.authorize_view/3`
      检查（`EzagentPluginCrawler.LeadsView` 的 `view_behavior/0` 指回本模块）。
      action 名带 `crawler_` 前缀：dispatch/cap 路由表按 `{kind, action}` 唯一
      （`CapabilityRegistry.check_conflict!` RAISE），共享 `:render` 会在第二个
      view 注册时相撞（kanban 注释先例）。

    * **产线索页的 json-render tree（只读投影）**：`render_tree/1` 纯函数把
      会话 `Ezagent.ActionSet.Crawler` slice 里留存的结构化线索（`:items` key，
      写入侧是 crawl/search 注入成功后的 `{:set, :items, ...}` effect）投成
      **shadcn catalog**（外部 SPA `catalog_jsonrender.mjs` 的现行词表，
      hello Spec 同源：Stack/Heading/Text/Table）的 string-keyed json-render
      map——同一棵树既是 view 的 external render，也是
      `EzagentPluginCrawler.PagePublisher` 落 Surface 版本树的 committed 页
      （单一投影源，两条读路不会漂移）。`external_tree/1` 是 per-session 读
      入口。**零写**：无 `{:set, ...}`、无 dispatch 写 action——这是投影，
      不是操作面（操作面是 `crawler.crawl_now` / `crawler.search` dispatch）。

  注册两处（照 kanban）：cap subject 走 `Application.behaviors/0`
  （`{Ezagent.Entity.Session, :crawler_render, __MODULE__}`）；SessionView 走
  `Application.start/2` 里 `SessionViewRegistry.register(LeadsView)`。渲染由
  world 通用消费 registry 自动接（world-views #1192/#1199），零 world 改动。
  """

  use Ezagent.Lifecycle

  @impl Ezagent.ActionSet
  def actions, do: [:crawler_render]

  @impl Ezagent.ActionSet
  def cap_subjects,
    do: [{:crawler_render, "Read (render) the retained crawl leads view for this session."}]

  @impl Ezagent.ActionSet
  def dispatchable?, do: false

  @impl Ezagent.ActionSet
  def interface, do: %{}

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{crawler_render: Ezagent.Capability.cap(:session, __MODULE__, :crawler_render)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any

  # ------------------------------------------------------------------
  # 只读线索投影（view 的数据面；全程 fail-safe，坏 slice 绝不炸渲染）
  # ------------------------------------------------------------------

  # 线索表列（catalog `table` 节点的 columns/rows 契约：rows 按列名取值）。
  @columns ["title", "summary", "source", "url"]

  @doc """
  per-session 的线索 json-render tree：读会话自身 `Ezagent.ActionSet.Crawler`
  slice 的 `:items`（真实爬取产物，写入侧是注入成功后的 `{:set, :items, ...}`
  effect），投成共享 catalog 页。无留存线索 / 读不到 → `nil`（SessionView
  `external_render/1` 契约的 "nothing to render yet"）。
  """
  @spec external_tree(URI.t() | term()) :: map() | nil
  def external_tree(%URI{} = session_uri) do
    case items_for(session_uri) do
      [] -> nil
      items -> render_tree(items)
    end
  end

  def external_tree(_), do: nil

  @doc """
  会话 crawler slice 里留存的结构化线索（归一后 string-keyed，最新在前）。
  dormant 会话先经核心 owner-gated chokepoint `LocalRuntime.ensure_started/1`
  起活（KanbanRender.board_slice_tree 同款，HIGH-3 liveness），再 get_slice；
  任何失败退 `[]`（fail-safe——渲染读路，坏 slice 绝不炸渲染）。

  需要区分"确定没有线索"和"读失败"的调用方（如 `PagePublisher` 的发布读，
  读失败要重试而不是当成空页跳过）用 `items_result/1`。
  """
  @spec items_for(URI.t() | term()) :: [map()]
  def items_for(%URI{} = session_uri) do
    case items_result(session_uri) do
      {:ok, items} -> items
      {:error, _} -> []
    end
  end

  def items_for(_), do: []

  @doc """
  `items_for/1` 的可辨别版本：`{:ok, items}` 是**确定性读**（拿到了 slice，
  items 可能为空 = 真没有线索）；`{:error, reason}` 是**读失败**（Kind 忙 /
  get_slice 5s 超时 / 未注册等——2026-07-10 段5 真 e2e 实测：crawl 注入 burst
  后 session Kind 正在逐条消化 `session.send` + snapshot 落盘，get_slice 会
  超时，此时线索其实在，只是读不到）。渲染读路请用 `items_for/1`（fail-safe）。
  """
  @spec items_result(URI.t() | term()) :: {:ok, [map()]} | {:error, term()}
  def items_result(%URI{} = session_uri) do
    _ = Ezagent.LocalRuntime.ensure_started(session_uri)

    # 字面量 slice 键（== Ezagent.ActionSet.Crawler.state_slice()，测试锁死）：
    # sensitive_slice_read 门对非字面量 get_slice 键 fail-closed（:__dynamic__）。
    case Ezagent.Kind.get_slice(session_uri, :crawler) do
      {:ok, %{} = slice} ->
        {:ok, normalize_items(Map.get(slice, :items) || Map.get(slice, "items"))}

      {:ok, _non_map} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:items_read_raised, e}}
  catch
    kind, reason -> {:error, {:items_read_caught, {kind, reason}}}
  end

  def items_result(other), do: {:error, {:not_a_session_uri, other}}

  @doc """
  纯函数：留存线索列表 → **shadcn catalog** 的 string-keyed json-render map
  （JSON round-trip 安全）。同一棵树喂两条读路：view 的 external render
  （world / SPA 通用消费）+ PagePublisher 落 Surface 的 committed 页
  （`/socialware/external` 匿名读的就是它）。输入不合法退空表（不炸）。

  词表修正（2026-07-10 段5 真浏览器 e2e 实测）：外部 SPA 的现行 renderer 是
  `catalog_jsonrender.mjs`（shadcn 36 组件 + `LEGACY_TO_SHADCN` 只补
  container/text/table/code 四个旧型），原先 emit 的 `page`/`section` 是
  **已退役的 hello page-builder 词表**（`catalog_render.mjs` 认，但 viewer
  已切走）——匿名页渲成 "Unsupported node: page"。改 emit hello Spec 同一
  shadcn 词表（`Stack`/`Heading`/`Text`/`Table`），Table 的 rows 用**按
  columns 对齐的 cell 数组**（viewer 的 `coerceRow` 对 map 行取
  `Object.values`，键序不可靠）。
  """
  @spec render_tree(term()) :: map()
  def render_tree(items) do
    items = normalize_items(items)

    rows =
      Enum.map(items, fn item ->
        Enum.map(@columns, &Map.get(item, &1, ""))
      end)

    %{
      "type" => "Stack",
      "props" => %{"gap" => 4},
      "children" => [
        %{"type" => "Heading", "props" => %{"text" => "线索", "level" => 2}, "children" => []},
        %{
          "type" => "Text",
          "props" => %{"text" => "共 #{length(items)} 条留存线索（最新在前，真实爬取产物）。"},
          "children" => []
        },
        %{
          "type" => "Table",
          "props" => %{"columns" => @columns, "rows" => rows},
          "children" => []
        }
      ]
    }
  end

  @doc """
  把任意 slice 读回值归一成 string-keyed 线索条目列表（atom/string key 双读，
  照 `EzagentPluginCrawler.Config.normalize_sources/1` 的宽松读法）：写入侧
  （`Ezagent.ActionSet.Crawler` 的 retain effect）已归一，读到坏条目只可能是
  snapshot round-trip / 外部手写，降级为跳过。
  """
  @spec normalize_items(term()) :: [map()]
  def normalize_items(items) when is_list(items) do
    items
    |> Enum.map(&normalize_item/1)
    |> Enum.reject(&(&1 == :invalid))
  end

  def normalize_items(_), do: []

  defp normalize_item(item) when is_map(item) do
    title = get(item, "title")
    url = get(item, "url")

    if is_binary(title) and title != "" do
      %{
        "title" => title,
        "url" => to_str(url),
        "summary" => to_str(get(item, "summary")),
        "source" => to_str(get(item, "source")),
        "source_type" => to_str(get(item, "source_type")),
        "retained_at" => to_str(get(item, "retained_at"))
      }
    else
      :invalid
    end
  end

  defp normalize_item(_), do: :invalid

  # 固定字段名的 atom/string 双读（不 `String.to_existing_atom`——`:retained_at`
  # 等 atom 可能从未在别处出现，动态转换会 raise）。
  @item_keys %{
    "title" => :title,
    "url" => :url,
    "summary" => :summary,
    "source" => :source,
    "source_type" => :source_type,
    "retained_at" => :retained_at
  }

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Map.fetch!(@item_keys, key))

  defp to_str(nil), do: ""
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(s) when is_binary(s), do: s
  defp to_str(other), do: to_string(other)
end
