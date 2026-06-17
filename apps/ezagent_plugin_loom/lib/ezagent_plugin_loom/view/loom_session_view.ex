defmodule EzagentPluginLoom.View.LoomSessionView do
  @moduledoc """
  SessionView 插件:给 loom session 在 admin view-switcher(Chat / 路由 / Bindings 旁)
  加一个 "Loom" 标签,主视图就地切换为 customer SPA(`/loom/app/:ws/:sid`)的 iframe。

  仅对 `session://<ws>/loom/<name>` 显示(`applies_to?/1` → false 则完全不出现)。
  iframe src 带一个现签的 socialware `CustomerAuth` token —— operator 已在 admin 内授权,
  这是 operator 预览 customer 体验(SPA 的数据端点 /feed、/messages 需要该 token)。

  迁移自 loom-stitch `Ezagent.PluginLoom.View.LoomSessionView`,适配:
  - URI 结构变化:`session://loom/<ws>/<name>` → `session://<ws>/loom/<name>`
  - 路由变化:`/loom/<ws>/<name>` → `/loom/app/<ws>/<name>?token=…`(socialware 鉴权)

  注册在 `EzagentPluginLoom.Application.start/2`(loom 自包含,**零改 admin**)。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  @impl true
  def id, do: :loom

  @impl true
  def label, do: "Loom"

  # "puzzle" → heroicons puzzle-piece(EzagentDomainUi.Primitives.heroicon_for/1)。
  @impl true
  def icon, do: "puzzle"

  # 仅创作型 loom session 显示(`session://<ws>/loom/<name>`)。
  @impl true
  def applies_to?(%URI{scheme: "session", path: "/loom/" <> name})
      when is_binary(name) and name != "",
      do: true

  def applies_to?(_), do: false

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :loom_url, loom_app_url(assigns[:session_uri]))

    ~H"""
    <div class="flex-1 min-h-0 bg-white dark:bg-zinc-950 flex">
      <iframe :if={@loom_url} src={@loom_url} class="w-full h-full border-0" title="Loom" />
      <div :if={is_nil(@loom_url)} class="p-4 text-sm text-zinc-500">
        非 loom session — 此标签不应出现(applies_to?/1 与 render/1 不一致)。
      </div>
    </div>
    """
  end

  # `session://<ws>/loom/<name>` → `/loom/app/<ws>/<name>?token=<现签 CustomerAuth token>`。
  defp loom_app_url(%URI{scheme: "session", host: ws, path: "/loom/" <> name} = session_uri)
       when is_binary(ws) and is_binary(name) and name != "" do
    token = Ezagent.Socialware.CustomerAuth.issue_token(session_uri, Ezagent.URI.workspace(ws))
    "/loom/app/#{ws}/#{name}?token=#{token}"
  end

  defp loom_app_url(_), do: nil
end
