defmodule Ezagent.PluginLoom.View.LoomSessionView do
  @moduledoc """
  SessionView 插件:在 session view-switcher(Chat / 路由 / Bindings 旁)
  加一个 "Loom" 标签,主视图就地切换为 `/loom/:ws/:name` 的 iframe。

  与同一 header 上的 `Open Loom ↗`(`session_editor.ex` `loom_link/1`)
  分工:那个开新标签,不影响本页;这个就地嵌入,不开新窗口。两者并存,
  按操作意图分开。

  ## 适用范围

  仅对 `session://loom/<ws>/<name>` 的 session 显示。其它 session 完全
  看不到这个标签(`applies_to?/1` → false)。

  ## 嵌套 iframe 工作原理

  - admin LV(顶层)
    └─ iframe → `/loom/:ws/:name`(loom Next.js SPA)
        └─ iframe → Sandpack 沙箱

  Sandpack 的 sdk 用 `window.parent.postMessage`,在嵌套 iframe 里
  `window.parent` 是 loom SPA 自己,bridge 正常接 → 沙箱 ↔ 宿主桥
  仍然 work。同源(都是 ESR 自己服务的),无 CORS。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  @impl true
  def id, do: :loom

  @impl true
  def label, do: "Loom"

  @impl true
  # "puzzle" 经 `EzagentDomainUi.Primitives.heroicon_for/1` 映射到 heroicons
  # `puzzle-piece`(2026-05-26 已注册,见 primitives.ex:521)。
  def icon, do: "puzzle"

  @impl true
  # 只有**创作会话**(直接 session.loom / 手存模板如 zuatu)显示 loom 视图;**发布消费
  # 会话**(`/p/:token/open` 从 published 物 mint 的 `pub_<hex>`,经 `ConsumerSession.mark`
  # 持久标记)不显示。按来源持久标志判,不靠名字、不靠有没有 v0(2026-06-10)。
  def applies_to?(%URI{scheme: "session", host: "loom", path: path}) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [ws, name | _] ->
        name != "" and not Ezagent.PluginLoom.ConsumerSession.consumer?(ws, name)

      _ ->
        false
    end
  end

  def applies_to?(_), do: false

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:session_uri, fn -> nil end)
      |> assign(:loom_url, loom_url(assigns[:session_uri]))

    ~H"""
    <div class="flex-1 min-h-0 bg-white dark:bg-zinc-950 flex">
      <iframe
        :if={@loom_url}
        src={@loom_url}
        class="w-full h-full border-0"
        title="Loom"
      />
      <div :if={is_nil(@loom_url)} class="p-4 text-sm text-zinc-500">
        非 loom session — 此标签不应出现,可能是 applies_to?/1 判断与 render/1 不一致。
      </div>
    </div>
    """
  end

  # `session://loom/<ws>/<name>` → `/loom/<ws>/<name>` (与 session_editor.ex
  # 的 `loom_link/1` 同样的 URL 推导;只是这里嵌 iframe,那里开新标签)。
  defp loom_url(%URI{scheme: "session", host: "loom", path: path}) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [ws, name | _] -> "/loom/#{ws}/#{name}"
      _ -> nil
    end
  end

  defp loom_url(_), do: nil
end
