defmodule EzagentPluginLoom.Tool do
  @moduledoc """
  Loom page-SDK **工具 RPC**(`platform.tool`,清单 B)。AI 生成的页面经服务端白名单工具
  调用浏览器沙箱够不到的能力(服务端时间、回显等)。内置 `now`/`echo`;
  config 可扩展(`:ezagent_plugin_loom, :tools`)。
  """

  @builtin %{
    "now" => &__MODULE__.now/1,
    "echo" => &__MODULE__.echo/1
  }

  @doc "调命名工具。返回 `{:ok, result}` | `{:error, reason}`。"
  @spec invoke(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def invoke(name, args) when is_binary(name) and is_map(args) do
    tools = Map.merge(@builtin, Application.get_env(:ezagent_plugin_loom, :tools, %{}))

    case Map.get(tools, name) do
      fun when is_function(fun, 1) -> fun.(args)
      _ -> {:error, :unknown_tool}
    end
  end

  def invoke(_, _), do: {:error, :bad_args}

  @doc "page_gen 提示词的工具清单块(告诉 AI 有哪些 platform.tool 可调)。"
  @spec prompt_block() :: String.t()
  def prompt_block do
    builtin = ["- `now({tz?})` — 服务端可信时间(ISO)", "- `echo(args)` — 回显(冒烟测试)"]

    extra =
      Application.get_env(:ezagent_plugin_loom, :tools, %{})
      |> Map.keys()
      |> Enum.map(&"- `#{&1}`")

    "## platform.tool(name, args) 可用命名工具\n" <> Enum.join(builtin ++ extra, "\n")
  end

  @doc "内置:服务端可信时间。"
  def now(args) do
    tz = args["tz"] || "Etc/UTC"
    {:ok, %{iso: DateTime.utc_now() |> DateTime.to_iso8601(), tz: tz}}
  end

  @doc "内置:回显(冒烟测试)。"
  def echo(args), do: {:ok, args}
end
