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

  @default_public_source ~c"https://hacker-news.firebaseio.com/v0/topstories.json"

  @doc "抓固定公开源，返回 source_type: :public 的条目列表。"
  @spec crawl() :: {:ok, [item]} | {:error, term()}
  def crawl, do: fetch(@default_public_source, [], :public)

  @doc "参数化抓取（query / 定向源），headers 注入 token（Task 5）。"
  @spec fetch(charlist() | String.t(), keyword(), :public | :directed) ::
          {:ok, [item]} | {:error, term()}
  def fetch(url, headers \\ [], source_type \\ :public) do
    request =
      {to_charlist(url), Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} ->
        {:ok, parse_items(body, source_type)}

      {:ok, {{_v, code, _r}, _h, _body}} ->
        {:error, {:http_status, code}}

      {:error, reason} ->
        Logger.warning("DealScout.Fetch: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "把 body 解析成信息条目，每条打 source_type。"
  @spec parse_items(binary(), :public | :directed) :: [item]
  def parse_items(body, source_type) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_item(&1, source_type))
      _ -> []
    end
  end

  defp to_item(m, source_type) when is_map(m) do
    %{
      title: Map.get(m, "title", ""),
      url: Map.get(m, "url", ""),
      summary: Map.get(m, "summary", ""),
      source: Map.get(m, "source", "public"),
      ts: DateTime.utc_now(),
      source_type: source_type
    }
  end
end
