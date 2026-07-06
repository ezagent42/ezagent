defmodule EzagentPluginDealScout.Fetch do
  @moduledoc """
  自建入站源 client（**别误用 socialware `:pull` 出站投影** —— 那是"外部来读
  ezagent session"，跟"ezagent 去抓外网"语义相反）。

  照 kanban miro `:httpc` idiom：必带 `{:body_format, :binary}`，否则 body 返
  charlist、中文乱码（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro.ex:141`）。

  每条线索打 `source_type`（spec §3）：
    * `:public` —— 自己爬公开网页找的线索（无 source/token 场景）；
    * `:directed` —— 用 token 抓登录源找的线索（有 source/token 场景，Task 5 接线）。
  """
  require Logger

  @type item :: %{
          title: String.t(),
          url: String.t(),
          summary: String.t(),
          source: String.t(),
          ts: DateTime.t(),
          source_type: :public | :directed
        }

  # 2026-07-07 真出网 e2e 发现并修正：原 @default_public_source 指
  # topstories.json（返回**整数 id 数组**，不是条目对象），真跑必
  # FunctionClauseError 崩 Poller / crawl_now（单测 stub 的 body 都是对象数组，
  # 掩盖了真源形状）。改指 HN Algolia front_page 检索（公开、无 token、返回
  # `%{"hits" => [%{...}]}` 条目对象），`parse_items/2` 同步支持该 envelope。
  @default_public_source ~c"https://hn.algolia.com/api/v1/search?tags=front_page"

  @doc "抓固定公开源，返回 source_type: :public 的条目列表。"
  @spec crawl() :: {:ok, [item]} | {:error, term()}
  def crawl, do: fetch(@default_public_source, [], :public)

  @doc "参数化抓取（query / 定向源），headers 注入 token（Task 5）。"
  @spec fetch(charlist() | String.t(), keyword(), :public | :directed) ::
          {:ok, [item]} | {:error, term()}
  def fetch(url, headers \\ [], source_type \\ :public) do
    request =
      {to_charlist(url), Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}

    case http_request_fun().(:get, request, [], body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} ->
        {:ok, parse_items(body, source_type)}

      {:ok, {{_v, code, _r}, _h, _body}} ->
        {:error, {:http_status, code}}

      {:error, reason} ->
        Logger.warning("DealScout.Fetch: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  抓一个需登录的定向源：先从 config 凭证读 token 注入 `Authorization` header
  （`:directed` 标注），无 token **fail-closed** —— 该源被显式跳过 + telemetry，
  不 silent 抓空（spec §3.2 硬要求 3）。
  """
  @spec fetch_directed(String.t(), String.t()) :: {:ok, [item]} | {:error, :no_token}
  def fetch_directed(url, source) when is_binary(url) and is_binary(source) do
    case EzagentPluginDealScout.Config.read_token(source) do
      {:ok, token} ->
        fetch(url, [{"Authorization", "Bearer #{token}"}], :directed)

      :error ->
        :telemetry.execute([:dealscout, :fetch, :skipped_no_token], %{count: 1}, %{source: source})

        {:error, :no_token}
    end
  end

  @doc """
  **source / token 有无自动分流的决策点**（补 Stage A 缺的运行时决策，spec §3.1）。

  给定 config 里配置的定向源列表 `sources`（每项 `%{url, source}`）：

    * **没配任何源** → 只爬公开网页（`crawl/0`，全部 `:public`）；
    * **配了源** → 公开网页 **+** 定向抓（每源经 `fetch_directed/2`：有 token 走
      `:directed`；无 token fail-closed 跳过 + telemetry —— 见 §3.1 A/B 两档表）。

  两类线索都保留 `source_type` 标注，合并成一个列表返回。抓公开源失败不阻断定向
  结果（反之亦然）—— 单源失败降级为该源零条目，不 silent drop 整批。
  """
  @spec crawl_auto([%{url: String.t(), source: String.t()}]) :: {:ok, [item]}
  def crawl_auto(sources \\ []) when is_list(sources) do
    public =
      case crawl() do
        {:ok, items} -> items
        {:error, _reason} -> []
      end

    directed =
      Enum.flat_map(sources, fn %{url: url, source: source} ->
        case fetch_directed(url, source) do
          {:ok, items} -> items
          # `:no_token`（已 telemetry）/ HTTP 失败 → 该源降级为零条目，fail-closed。
          {:error, _reason} -> []
        end
      end)

    {:ok, public ++ directed}
  end

  @doc """
  把 body 解析成信息条目，每条打 source_type。

  支持两种真源形状（2026-07-07 真出网 e2e 修正）：
    * 裸对象数组 `[%{...}]`（定向源约定形状）——**非 map 条目丢弃**（真公开源
      可能混入 id 整数等，真跑不能 crash 整批）；
    * HN Algolia 检索 envelope `%{"hits" => [%{...}]}`（默认公开源 + `:search`
      腿的真实返回形状）。
  其余形状（如 topstories 的纯 id 数组解不出对象）降级为 `[]`。
  """
  @spec parse_items(binary(), :public | :directed) :: [item]
  def parse_items(body, source_type) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"hits" => hits}} when is_list(hits) -> items_from_list(hits, source_type)
      {:ok, list} when is_list(list) -> items_from_list(list, source_type)
      _ -> []
    end
  end

  defp items_from_list(list, source_type) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.map(&to_item(&1, source_type))
  end

  defp to_item(m, source_type) when is_map(m) do
    %{
      title: Map.get(m, "title", ""),
      url: item_url(m),
      summary: item_summary(m),
      source: Map.get(m, "source", "public"),
      ts: DateTime.utc_now(),
      source_type: source_type
    }
  end

  # Algolia hit 的 url 可为 null（Ask HN 等站内帖）→ 回落 HN 讨论页。
  defp item_url(m) do
    case Map.get(m, "url") do
      url when is_binary(url) and url != "" -> url
      _ -> fallback_discussion_url(m)
    end
  end

  defp fallback_discussion_url(%{"objectID" => id}) when is_binary(id),
    do: "https://news.ycombinator.com/item?id=#{id}"

  defp fallback_discussion_url(_), do: ""

  # 条目无显式 summary 时（真源普遍没有），用 points/author 拼一条可读摘要，
  # 页面展示不至于空白。
  defp item_summary(m) do
    case Map.get(m, "summary") do
      s when is_binary(s) and s != "" ->
        s

      _ ->
        points = Map.get(m, "points")
        author = Map.get(m, "author")

        [if(points, do: "#{points} points"), if(author, do: "by #{author}")]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
    end
  end

  # Test seam: the low-level HTTP transport (`:httpc.request/4` arity). Tests
  # inject a canned reply so directed/auto-routing paths run without real
  # network. Defaults to real `:httpc` in dev/prod.
  defp http_request_fun,
    do: Application.get_env(:ezagent_plugin_dealscout, :http_request_fun, &:httpc.request/4)
end
