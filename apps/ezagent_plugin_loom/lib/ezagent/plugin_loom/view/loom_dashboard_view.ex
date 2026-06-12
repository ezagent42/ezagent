defmodule Ezagent.PluginLoom.View.LoomDashboardView do
  @moduledoc """
  SessionView 插件:loom session 的 **Dashboard** 标签(2026-06-12)。

  跟 `LoomSessionView`(Loom 编辑器 iframe)同适用范围 —— 仅对**创作型** loom session
  (`session://loom/<ws>/<name>`,非发布消费会话)显示。汇总跟这个 loom 有关、能统计到的东西:

  - **Token 消耗**:v0 / 编排器 / worker 经 Claude Code 的累计 input/output token + 调用次数
    (`Ezagent.PluginLoom.Stats`,从 claude result 事件的 usage 累加)。
  - **分享链接**:本 session 发布出的 published 物(share-link)。
  - **素材库**:本 session 素材文件数。
  - **团队**:session 成员(orchestrator / workers / v0 / stitch …)数。

  尚未埋点的(诚实标注):发布页**点击/打开数**、Stitch(DeepSeek)plane 的 token。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.PluginLoom.{Materials, Stats, ConsumerSession, SavedClasses}

  @impl true
  def id, do: :loom_dashboard

  @impl true
  def label, do: "Dashboard"

  @impl true
  def icon, do: "route"

  @impl true
  def applies_to?(%URI{scheme: "session", host: "loom", path: path}) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [ws, name | _] -> name != "" and not ConsumerSession.consumer?(ws, name)
      _ -> false
    end
  end

  def applies_to?(_), do: false

  @impl true
  def render(assigns) do
    {ws, sid} = ws_sid(assigns[:session_uri])
    assigns = assign(assigns, data: gather(ws, sid, assigns[:session_uri]))

    ~H"""
    <div class="flex-1 min-h-0 overflow-y-auto bg-zinc-50 dark:bg-zinc-950 p-5">
      <div :if={!@data} class="text-sm text-zinc-500">非 loom session — 无统计。</div>

      <div :if={@data} class="max-w-3xl mx-auto space-y-5">
        <%!-- Token --%>
        <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
          <h3 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 mb-3">Token 消耗(页面生成 plane · Claude Code)</h3>
          <div class="grid grid-cols-3 gap-3 mb-3">
            <.stat label="Input" value={@data.tok["input"]} />
            <.stat label="Output" value={@data.tok["output"]} />
            <.stat label="调用次数" value={@data.tok["calls"]} />
          </div>
          <div :if={@data.by_role != []} class="text-xs text-zinc-500">
            <div class="font-medium mb-1">按角色:</div>
            <div :for={{role, r} <- @data.by_role} class="flex justify-between py-0.5 border-t border-zinc-100 dark:border-zinc-800">
              <span>{role}</span>
              <span class="font-mono">in {fmt(r["input"])} · out {fmt(r["output"])} · {r["calls"]} 次</span>
            </div>
          </div>
          <p class="text-[11px] text-zinc-400 mt-2">注:Stitch(预览侧助手,DeepSeek)的 token 暂未计入。</p>
        </section>

        <div class="grid grid-cols-3 gap-4">
          <.card label="团队成员" value={@data.members} hint="orchestrator / workers / v0 / stitch …" />
          <.card label="素材文件" value={@data.materials} hint="素材库里的文件数" />
          <.card label="分享链接" value={length(@data.published)} hint="本 session 发布出的链接" />
        </div>

        <%!-- 分享链接列表 --%>
        <section :if={@data.published != []} class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
          <h3 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 mb-2">分享链接 / 发布历史</h3>
          <div :for={p <- @data.published} class="flex items-center gap-2 text-xs py-1 border-t border-zinc-100 dark:border-zinc-800">
            <span class="text-zinc-400">{p["published_at"]}</span>
            <a href={"/loom/p/#{p["token"]}"} target="_blank" class="text-blue-600 dark:text-blue-400 hover:underline truncate">/loom/p/{p["token"]}</a>
            <span class="text-zinc-500 truncate">{p["description"]}</span>
            <button type="button" data-copy={"/loom/p/#{p["token"]}"} data-label="复制" class="ml-auto text-zinc-400 hover:text-zinc-700">复制</button>
          </div>
        </section>

        <p class="text-[11px] text-zinc-400">未埋点(下一步):发布页的点击 / 打开数、衍生(fork/open)会话归因。</p>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-md bg-zinc-50 dark:bg-zinc-800 p-3 text-center">
      <div class="text-lg font-semibold text-zinc-800 dark:text-zinc-100 tabular-nums">{fmt(@value)}</div>
      <div class="text-[11px] text-zinc-500 mt-0.5">{@label}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :hint, :string, default: ""

  defp card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
      <div class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100 tabular-nums">{fmt(@value)}</div>
      <div class="text-xs font-medium text-zinc-600 dark:text-zinc-300 mt-1">{@label}</div>
      <div class="text-[11px] text-zinc-400 mt-0.5">{@hint}</div>
    </div>
    """
  end

  # --- data ---

  defp gather(nil, _sid, _uri), do: nil
  defp gather(_ws, nil, _uri), do: nil

  defp gather(ws, sid, %URI{} = uri) do
    tok = Stats.get(URI.to_string(uri))

    %{
      tok: tok,
      by_role: (tok["by_role"] || %{}) |> Map.to_list() |> Enum.sort(),
      members: member_count(uri),
      materials: length(safe(fn -> Materials.list(ws, sid) end, [])),
      published: published_for(ws, sid)
    }
  end

  defp gather(_, _, _), do: nil

  defp member_count(uri) do
    case safe(fn -> Ezagent.Kind.get_slice(uri, :chat) end, :error) do
      {:ok, %{members: m}} when is_map(m) -> map_size(m)
      _ -> 0
    end
  end

  defp published_for(ws, sid) do
    safe(fn -> SavedClasses.list_published() end, [])
    |> Enum.filter(&(&1["ws"] == ws and &1["published_from"] == sid))
  end

  defp ws_sid(%URI{scheme: "session", host: "loom", path: path}) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [ws, sid | _] -> {ws, sid}
      _ -> {nil, nil}
    end
  end

  defp ws_sid(_), do: {nil, nil}

  defp fmt(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(_), do: "0"

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
