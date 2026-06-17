defmodule EzagentPluginLoom.View.LoomDashboardView do
  @moduledoc """
  SessionView 插件:loom session 的 "Dashboard" 标签 —— 主视图就地嵌入 operator 看板 SPA
  (`/loom/dashboard/:ws/:sid`)的 iframe(运营 KPI:token / 调用 / 素材 / 知识)。

  跟 `EzagentPluginLoom.View.LoomSessionView` 同适用范围(仅 `session://<ws>/loom/<name>`)。

  迁移自 loom-stitch `Ezagent.PluginLoom.View.LoomDashboardView`。loom-stitch 是富 HEEx 直渲;
  本迁移版**复用已迁好的 DashboardSPA**(`/loom/dashboard`),以 iframe 嵌入,避免重端口富统计
  + 其专属埋点 schema。数据后端是 `EzagentPluginLoom.Dashboard.summary/1`。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  @impl true
  def id, do: :loom_dashboard

  @impl true
  def label, do: "Dashboard"

  # "dashboard" → heroicons rectangle-group(EzagentDomainUi.Primitives.heroicon_for/1)。
  @impl true
  def icon, do: "dashboard"

  @impl true
  def applies_to?(%URI{scheme: "session", host: ws, path: "/loom/" <> name})
      when is_binary(ws) and is_binary(name) and name != "",
      do: not EzagentPluginLoom.ConsumerSession.consumer?(ws, name)

  def applies_to?(_), do: false

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :dash_url, dashboard_url(assigns[:session_uri]))

    ~H"""
    <div class="flex-1 min-h-0 bg-zinc-50 dark:bg-zinc-950 flex">
      <iframe :if={@dash_url} src={@dash_url} class="w-full h-full border-0" title="Loom Dashboard" />
      <div :if={is_nil(@dash_url)} class="p-4 text-sm text-zinc-500">非 loom session — 无看板。</div>
    </div>
    """
  end

  defp dashboard_url(%URI{scheme: "session", host: ws, path: "/loom/" <> name} = session_uri)
       when is_binary(ws) and is_binary(name) and name != "" do
    token = Ezagent.Socialware.CustomerAuth.issue_token(session_uri, Ezagent.URI.workspace(ws))
    "/loom/dashboard/#{ws}/#{name}?token=#{token}"
  end

  defp dashboard_url(_), do: nil
end
