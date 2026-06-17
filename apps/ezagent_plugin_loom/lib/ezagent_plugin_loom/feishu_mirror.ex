defmodule EzagentPluginLoom.FeishuMirror do
  @moduledoc """
  Loom 飞书镜像 **预留桩**(项 1,operator 平面只看不回)。

  ⚠️ **这是预留接口 + 桩实现,未接通真实飞书** —— 完整实现需用户补齐(见 `待接入` 段)。
  接口稳定:`configured?/0` 探测凭证、`bind/2` 记录 session→飞书群绑定、`mirror/2` 镜像一条
  operator 平面消息。未配置凭证时全部 graceful no-op(不影响主链路)。

  ## 待接入(需用户补 / 需 main 配合)

  1. **飞书凭证**:`FEISHU_BOT_TOKEN` + 目标群 `chat_id`(env 或绑定参数)。
  2. **真实投递**:`mirror/2` 的飞书 API 调用 —— 应走 main `ezagent_domain_external_mirror`
     的 `ExternalMirror.bind/4` + `ezagent_plugin_feishu` adapter,而非自建 HTTP。
  3. **facade caller 身份**:`ExternalMirror.bind` 会对 caller resolve 飞书 open_id;loom 的
     system/anon caller 无飞书身份(旧 loom 正是绕过 facade 直写 BindingRow 的 hack)——
     需 main 给一个「系统级 operator 平面镜像」的 caller 豁免,或 loom 用 operator 身份绑定。
  4. **visibility filter**:customer-visible 镜像需 main 补 `ExternalMirror` 的 visibility filter
     (spec §4.3 自列待做);当前只镜像 operator 平面。
  """
  use GenServer

  @table :loom_feishu_bindings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "飞书凭证是否就绪(env FEISHU_BOT_TOKEN)。未配置 → 镜像全 no-op。"
  @spec configured?() :: boolean()
  def configured?, do: System.get_env("FEISHU_BOT_TOKEN") not in [nil, ""]

  @doc "绑定 session → 飞书群(桩:记录绑定意图)。返回 :ok | {:error, :not_configured}。"
  @spec bind(URI.t(), String.t()) :: :ok | {:error, :not_configured}
  def bind(%URI{} = session_uri, chat_id) when is_binary(chat_id) do
    if configured?() do
      ensure_table()
      :ets.insert(@table, {URI.to_string(session_uri), chat_id})
      :ok
    else
      {:error, :not_configured}
    end
  end

  @doc "本 session 绑定的飞书群(无 → nil)。"
  def bound_chat(%URI{} = session_uri) do
    ensure_table()

    case :ets.lookup(@table, URI.to_string(session_uri)) do
      [{_k, chat_id}] -> chat_id
      [] -> nil
    end
  end

  @doc """
  镜像一条 operator 平面消息到飞书(桩)。未配置 / 未绑定 → no-op。
  ⚠️ 真实投递待接入(见 moduledoc 待接入 §2)。
  """
  @spec mirror(URI.t(), map()) :: :ok | {:noop, atom()}
  def mirror(%URI{} = session_uri, _message) do
    cond do
      not configured?() -> {:noop, :not_configured}
      is_nil(bound_chat(session_uri)) -> {:noop, :not_bound}
      # TODO(待接入 §2):走 ExternalMirror + ezagent_plugin_feishu adapter 真实投递。
      true -> {:noop, :delivery_not_wired}
    end
  end

  @impl true
  def init(:ok) do
    create_table()
    {:ok, %{}}
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined, do: create_table()
    :ok
  rescue
    ArgumentError -> :ok
  end
end
