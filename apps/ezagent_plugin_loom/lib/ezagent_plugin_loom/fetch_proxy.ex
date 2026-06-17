defmodule EzagentPluginLoom.FetchProxy do
  @moduledoc """
  Loom page-SDK **白名单 HTTP 代理**(`platform.fetch`,清单 B)。AI 页面经服务端受控代理调
  外部 API,**只允许 config preset 白名单的 URL 模式 + 方法**:

      config :ezagent_plugin_loom, :fetch_presets,
        public: %{url: ~r{^https://api\\.github\\.com/}, methods: [:get]}

  不在白名单 → 拒绝。key 由服务端 preset 注入(不在前端硬编码)。
  """

  @timeout_ms 30_000

  @doc "经 preset 代理取 URL。返回 `{:ok, %{status, body}}` | `{:error, reason}`。"
  @spec fetch(String.t(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def fetch(preset, url, method \\ :get) when is_binary(preset) and is_binary(url) do
    presets = Application.get_env(:ezagent_plugin_loom, :fetch_presets, %{})

    with %{} = cfg <- Map.get(presets, String.to_atom(preset), :no_preset),
         true <- url_allowed?(cfg, url),
         true <- method_allowed?(cfg, method) do
      do_fetch(url)
    else
      :no_preset -> {:error, :unknown_preset}
      false -> {:error, :not_allowed}
    end
  rescue
    ArgumentError -> {:error, :unknown_preset}
  end

  @doc "page_gen 提示词的 preset 清单块(告诉 AI platform.fetch 有哪些白名单 preset)。"
  @spec prompt_block() :: String.t()
  def prompt_block do
    case Application.get_env(:ezagent_plugin_loom, :fetch_presets, %{}) |> Map.keys() do
      [] -> ""
      ks -> "## platform.fetch(preset, url) 可用 preset\n" <> Enum.map_join(ks, "\n", &"- `#{&1}`")
    end
  end

  defp url_allowed?(%{url: %Regex{} = re}, url), do: Regex.match?(re, url)
  defp url_allowed?(_, _), do: false

  defp method_allowed?(%{methods: methods}, method) when is_list(methods), do: method in methods
  defp method_allowed?(_, method), do: method == :get

  defp do_fetch(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: @timeout_ms],
           body_format: :binary
         ) do
      {:ok, {{_v, status, _r}, _headers, body}} -> {:ok, %{status: status, body: to_string(body)}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end
end
