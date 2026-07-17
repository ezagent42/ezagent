defmodule Ezagent.Message.ActionableError do
  @moduledoc """
  Configured, transport-neutral recovery guidance carried inside a message body.

  Agent behaviors select a stable error kind and may add a repair URL or
  diagnostic detail. User-facing transports render the resulting map directly;
  they never parse prose to infer failure semantics.
  """

  @type kind ::
          :missing_credentials
          | :unauthorized
          | :quota_exceeded
          | :network_timeout
          | :unknown

  @catalog %{
    missing_credentials: %{
      "code" => "agent.credentials_missing",
      "severity" => "error",
      "layer" => 1,
      "title" => "Agent 缺少访问凭据",
      "what_happened" => "这个 Agent 尚未配置调用模型所需的 API Key。",
      "impact" => "本次消息未能交给模型处理，Agent 无法生成回复。",
      "next_step" => "配置 API Key 后，重新发送本条消息。",
      "action" => %{"label" => "配置 API Key"},
      "permission" => "agent.api_keys.put"
    },
    unauthorized: %{
      "code" => "agent.request_unauthorized",
      "severity" => "error",
      "layer" => 2,
      "title" => "模型服务拒绝了请求",
      "what_happened" => "当前凭据没有权限访问所配置的模型或接口。",
      "impact" => "本次消息未被模型服务处理。",
      "next_step" => "请 workspace 管理员检查 Agent 的凭据与模型权限。",
      "permission" => "agent.api_keys.put"
    },
    quota_exceeded: %{
      "code" => "agent.provider_quota_exceeded",
      "severity" => "warning",
      "layer" => 2,
      "title" => "模型服务额度不足",
      "what_happened" => "模型服务返回了额度或速率限制。",
      "impact" => "Agent 暂时无法继续生成回复。",
      "next_step" => "请 workspace 管理员检查服务额度；恢复后重新发送本条消息。",
      "permission" => "agent.api_keys.put"
    },
    network_timeout: %{
      "code" => "agent.network_timeout",
      "severity" => "warning",
      "layer" => 1,
      "title" => "连接模型服务超时",
      "what_happened" => "Agent 在等待模型服务响应时超过了时限。",
      "impact" => "本次消息没有得到完整回复。",
      "next_step" => "稍后重新发送本条消息；若持续失败，请联系 workspace 管理员。"
    },
    unknown: %{
      "code" => "agent.unclassified_failure",
      "severity" => "error",
      "layer" => 3,
      "title" => "Agent 遇到未识别的错误",
      "what_happened" => "系统暂时无法将这次失败归入已知类型。",
      "impact" => "本次消息未能完成处理。",
      "next_step" => "请联系 workspace 管理员，并提供下方错误代码与诊断信息。"
    }
  }

  @doc "Build the stable wire map for a configured error kind."
  @spec new(kind(), keyword()) :: map()
  def new(kind, opts \\ []) when is_atom(kind) and is_list(opts) do
    kind
    |> definition()
    |> maybe_put_action_href(Keyword.get(opts, :action_href))
    |> maybe_put("detail", Keyword.get(opts, :detail))
    |> maybe_put("ticket", Keyword.get(opts, :ticket))
  end

  @doc "Return the configured definition for a supported error kind."
  @spec definition(kind()) :: map()
  def definition(kind) when is_atom(kind), do: Map.fetch!(@catalog, kind)

  @doc "List the stable kinds available to error producers."
  @spec kinds() :: [kind()]
  def kinds, do: Map.keys(@catalog)

  defp maybe_put_action_href(error, href) when is_binary(href) and href != "" do
    action =
      error
      |> Map.get("action", %{"label" => "打开处理页面"})
      |> Map.put("href", href)

    Map.put(error, "action", action)
  end

  defp maybe_put_action_href(error, _href), do: error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
