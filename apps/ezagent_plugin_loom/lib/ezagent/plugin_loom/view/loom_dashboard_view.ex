defmodule Ezagent.PluginLoom.View.LoomDashboardView do
  @moduledoc """
  SessionView 插件:loom session 的 **Dashboard** 标签(2026-06-12,v2 富化)。

  跟 `LoomSessionView`(Loom 编辑器 iframe)同适用范围 —— 仅对**创作型** loom session
  (`session://loom/<ws>/<name>`,非发布消费会话)显示。一个面向运营的控制台,把这个 loom
  能统计到的东西铺开:

  - **KPI**:总 token / 总成本(USD)/ 调用次数 / 团队规模。
  - **Token 明细**:fresh / cache 读 / cache 写 / output 的堆叠占比 + cache 命中率 + 均值。
  - **按角色**:builder / 编排器 / worker… 的 token / 成本 / 次数,带占比条。
  - **调用时间线**:最近 60 次调用的 token sparkline。
  - **团队**:session 成员花名册(按角色着色)。
  - **素材库**:文件数 + 按类型(图片/文本/其他)分布 + 体积。
  - **知识库**:字节数。
  - **分享链接**:本 session 发布出的 published 物。

  数据源:`Ezagent.PluginLoom.Stats`(claude_code usage 埋点)、`Materials`、`Knowledge`、
  `SavedClasses`、chat slice。尚未埋点的(诚实标注):发布页**点击/打开数**、衍生(fork/open)
  会话归因、Salesperson(DeepSeek)plane 的 token。
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.PluginLoom.{Materials, Stats, Knowledge, ConsumerSession, SavedClasses}

  @impl true
  def id, do: :loom_dashboard

  @impl true
  def label, do: "Dashboard"

  @impl true
  def icon, do: "dashboard"

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
    assigns = assign(assigns, d: gather(ws, sid, assigns[:session_uri]), ws: ws, sid: sid)

    ~H"""
    <div class="flex-1 min-h-0 overflow-y-auto bg-zinc-50 dark:bg-zinc-950">
      <div :if={!@d} class="p-6 text-sm text-zinc-500">非 loom session — 无统计。</div>

      <div :if={@d} class="max-w-5xl mx-auto px-5 py-6 space-y-6">
        <%!-- ── Header ── --%>
        <header class="flex items-end justify-between flex-wrap gap-3">
          <div>
            <div class="flex items-center gap-2">
              <h1 class="text-xl font-bold text-zinc-900 dark:text-zinc-50">Dashboard</h1>
              <span class="px-2 py-0.5 rounded-full text-[11px] font-medium bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300">
                {@ws} / {@sid}
              </span>
            </div>
            <p class="text-xs text-zinc-500 mt-1">
              <span :if={@d.tok["first_at"]}>
                活跃 {short_time(@d.tok["first_at"])} → {short_time(@d.tok["last_at"])} · 累计 API 用时 {dur(
                  @d.tok["duration_ms"]
                )}
              </span>
              <span :if={!@d.tok["first_at"]}>暂无 Claude Code 调用记录 —— 生成一个页面后回来看。</span>
            </p>
          </div>
          <div class="flex items-center gap-2 text-[11px] text-zinc-400">
            <span class="inline-flex items-center gap-1">
              <span class="w-1.5 h-1.5 rounded-full bg-emerald-500"></span> 实时(刷新页面更新)
            </span>
          </div>
        </header>

        <%!-- ── KPI row ── --%>
        <section class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <.kpi
            label="总 Token"
            value={fmt(total_tokens(@d.tok))}
            sub={"in #{fmt(@d.tok["input"])} · out #{fmt(@d.tok["output"])}"}
            tone="indigo"
          />
          <.kpi
            label="估算成本"
            value={money(@d.tok["cost_usd"])}
            sub="Claude Code total_cost_usd 累加"
            tone="emerald"
          />
          <.kpi
            label="调用次数"
            value={fmt(@d.tok["calls"])}
            sub={"均 #{avg(@d.tok["input"], @d.tok["calls"])} in / #{avg(@d.tok["output"], @d.tok["calls"])} out"}
            tone="sky"
          />
          <.kpi
            label="团队规模"
            value={Integer.to_string(length(@d.members))}
            sub={"#{@d.materials.count} 素材 · #{length(@d.published)} 分享"}
            tone="violet"
          />
        </section>

        <%!-- ── Token breakdown ── --%>
        <section class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100">
              Token 明细 · 页面生成 plane(Claude Code)
            </h2>
            <span class="text-[11px] text-zinc-400">
              cache 命中率 {pct(@d.tok["cache_read"], @d.tok["input"])}%
            </span>
          </div>

          <%!-- stacked bar --%>
          <% inp = @d.tok["input"] %>
          <% out = @d.tok["output"] %>
          <% grand = max(inp + out, 1) %>
          <div class="flex h-4 rounded-lg overflow-hidden mb-3 ring-1 ring-inset ring-zinc-200 dark:ring-zinc-800">
            <div
              :if={@d.tok["fresh_input"] > 0}
              style={"width:#{pct(@d.tok["fresh_input"], grand)}%"}
              class="bg-sky-500"
              title={"fresh input #{@d.tok["fresh_input"]}"}
            >
            </div>
            <div
              :if={@d.tok["cache_read"] > 0}
              style={"width:#{pct(@d.tok["cache_read"], grand)}%"}
              class="bg-cyan-400"
              title={"cache read #{@d.tok["cache_read"]}"}
            >
            </div>
            <div
              :if={@d.tok["cache_creation"] > 0}
              style={"width:#{pct(@d.tok["cache_creation"], grand)}%"}
              class="bg-indigo-400"
              title={"cache creation #{@d.tok["cache_creation"]}"}
            >
            </div>
            <div
              :if={out > 0}
              style={"width:#{pct(out, grand)}%"}
              class="bg-emerald-500"
              title={"output #{out}"}
            >
            </div>
            <div :if={inp + out == 0} class="w-full bg-zinc-100 dark:bg-zinc-800"></div>
          </div>

          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <.legend dot="bg-sky-500" label="Fresh input" value={fmt(@d.tok["fresh_input"])} />
            <.legend dot="bg-cyan-400" label="Cache 读" value={fmt(@d.tok["cache_read"])} />
            <.legend dot="bg-indigo-400" label="Cache 写" value={fmt(@d.tok["cache_creation"])} />
            <.legend dot="bg-emerald-500" label="Output" value={fmt(@d.tok["output"])} />
          </div>
        </section>

        <%!-- ── By role ── --%>
        <section
          :if={@d.by_role != []}
          class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5"
        >
          <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 mb-4">按角色拆分</h2>
          <div class="space-y-3">
            <div :for={{role, r} <- @d.by_role}>
              <div class="flex items-center justify-between text-xs mb-1">
                <span class="inline-flex items-center gap-1.5 font-medium text-zinc-700 dark:text-zinc-200">
                  <span class={"w-2 h-2 rounded-full #{role_dot(role)}"}></span>
                  {role_label(role)}
                </span>
                <span class="font-mono text-zinc-500">
                  {fmt(role_total(r))} tok · {money(r["cost_usd"])} · {r["calls"] || 0} 次
                </span>
              </div>
              <div class="h-2 rounded-full bg-zinc-100 dark:bg-zinc-800 overflow-hidden">
                <div
                  class={"h-full #{role_dot(role)}"}
                  style={"width:#{pct(role_total(r), @d.role_max)}%"}
                >
                </div>
              </div>
            </div>
          </div>
        </section>

        <%!-- ── Call timeline ── --%>
        <section
          :if={@d.history != []}
          class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5"
        >
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100">调用时间线</h2>
            <span class="text-[11px] text-zinc-400">最近 {length(@d.history)} 次 · 柱高 = 该次总 token</span>
          </div>
          <div class="flex items-end gap-[3px] h-20">
            <div
              :for={h <- @d.history}
              class={"flex-1 min-w-[3px] rounded-t #{role_dot(h["role"])} opacity-80 hover:opacity-100"}
              style={"height:#{max(pct(h["in"] + h["out"], @d.hist_max), 3)}%"}
              title={"#{role_label(h["role"])} · in #{h["in"]} / out #{h["out"]} · #{short_time(h["at"])}"}
            >
            </div>
          </div>
        </section>

        <%!-- ── Team + Materials side by side ── --%>
        <div class="grid md:grid-cols-2 gap-6">
          <section class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5">
            <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 mb-3">
              团队成员 · {length(@d.members)}
            </h2>
            <div class="space-y-1.5">
              <div :for={m <- @d.members} class="flex items-center justify-between gap-2 text-xs py-1">
                <span class="inline-flex items-center gap-2 min-w-0">
                  <span class={"w-2 h-2 rounded-full shrink-0 #{role_dot(m.role)}"}></span>
                  <span class="font-medium text-zinc-700 dark:text-zinc-200 truncate">{m.name}</span>
                </span>
                <span class={"shrink-0 px-1.5 py-0.5 rounded text-[10px] #{role_chip(m.role)}"}>
                  {role_label(m.role)}
                </span>
              </div>
              <div :if={@d.members == []} class="text-xs text-zinc-400">未发现成员(团队可能尚未 spawn)。</div>
            </div>
          </section>

          <section class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100">
                素材库 · {@d.materials.count}
              </h2>
              <span class="text-[11px] text-zinc-400">共 {bytes(@d.materials.size)}</span>
            </div>
            <div class="space-y-2 mb-3">
              <div :for={{type, t} <- @d.materials.by_type} class="flex items-center gap-2 text-xs">
                <span class={"w-2 h-2 rounded-full #{mat_dot(type)}"}></span>
                <span class="text-zinc-600 dark:text-zinc-300 w-12">{mat_label(type)}</span>
                <div class="flex-1 h-2 rounded-full bg-zinc-100 dark:bg-zinc-800 overflow-hidden">
                  <div
                    class={"h-full #{mat_dot(type)}"}
                    style={"width:#{pct(t.count, max(@d.materials.count, 1))}%"}
                  >
                  </div>
                </div>
                <span class="font-mono text-zinc-500 w-20 text-right">
                  {t.count} · {bytes(t.size)}
                </span>
              </div>
              <div :if={@d.materials.count == 0} class="text-xs text-zinc-400">暂无素材。</div>
            </div>
            <div class="pt-3 border-t border-zinc-100 dark:border-zinc-800 text-xs text-zinc-500">
              知识库:<span class="font-mono">{bytes(@d.knowledge_bytes)}</span>
              <span class="text-zinc-400">({@d.knowledge_bytes} 字符)</span>
            </div>
          </section>
        </div>

        <%!-- ── Share links ── --%>
        <section class="rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-5">
          <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 mb-3">
            分享链接 / 发布历史 · {length(@d.published)}
          </h2>
          <div :if={@d.published == []} class="text-xs text-zinc-400">本 session 还没发布过页面。</div>
          <div
            :for={p <- @d.published}
            class="flex items-center gap-2 text-xs py-2 border-t border-zinc-100 dark:border-zinc-800 first:border-t-0"
          >
            <span class="text-zinc-400 shrink-0 w-28">{short_time(p["published_at"])}</span>
            <a
              href={"/loom/p/#{p["token"]}"}
              target="_blank"
              class="text-blue-600 dark:text-blue-400 hover:underline font-mono shrink-0"
            >
              /loom/p/{short_token(p["token"])}
            </a>
            <span class="text-zinc-500 truncate flex-1">{p["description"] || p["class_name"]}</span>
            <button
              type="button"
              data-copy={"/loom/p/#{p["token"]}"}
              data-label="复制"
              class="shrink-0 px-2 py-0.5 rounded border border-zinc-200 dark:border-zinc-700 text-zinc-500 hover:text-zinc-800 hover:border-zinc-300 dark:hover:text-zinc-200"
            >
              复制
            </button>
          </div>
        </section>

        <%!-- ── Honest gaps ── --%>
        <section class="rounded-xl border border-dashed border-zinc-300 dark:border-zinc-700 p-4">
          <h3 class="text-xs font-semibold text-zinc-500 mb-1.5">尚未埋点(下一步)</h3>
          <ul class="text-[11px] text-zinc-400 space-y-0.5 list-disc list-inside">
            <li>发布页的**点击 / 打开数**(需要在 <code>/loom/p/:token</code> serve 处计数)。</li>
            <li>**衍生会话**(fork / open 出去的消费会话)归因到来源 session。</li>
            <li>**Salesperson / AiSpot**(预览侧 DeepSeek)的 token 与成本(独立 plane,未接入 Stats)。</li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  # ── components ──

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:sub, :string, default: "")
  attr(:tone, :string, default: "zinc")

  defp kpi(assigns) do
    ~H"""
    <div class={"rounded-xl border p-4 #{kpi_tone(@tone)}"}>
      <div class="text-2xl font-bold tabular-nums leading-none">{@value}</div>
      <div class="text-xs font-medium mt-2 opacity-90">{@label}</div>
      <div :if={@sub != ""} class="text-[11px] mt-0.5 opacity-60 truncate">{@sub}</div>
    </div>
    """
  end

  attr(:dot, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp legend(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class={"w-2.5 h-2.5 rounded-sm #{@dot}"}></span>
      <div>
        <div class="text-sm font-semibold text-zinc-800 dark:text-zinc-100 tabular-nums leading-none">
          {@value}
        </div>
        <div class="text-[11px] text-zinc-500">{@label}</div>
      </div>
    </div>
    """
  end

  # ── data gathering ──

  defp gather(nil, _sid, _uri), do: nil
  defp gather(_ws, nil, _uri), do: nil

  defp gather(ws, sid, %URI{} = uri) do
    tok = Stats.get(URI.to_string(uri))
    by_role = tok["by_role"] |> Map.to_list() |> Enum.sort_by(fn {_r, m} -> -role_total(m) end)

    role_max =
      by_role |> Enum.map(fn {_r, m} -> role_total(m) end) |> Enum.max(fn -> 1 end) |> max(1)

    history = tok["history"] || []

    hist_max =
      history
      |> Enum.map(&((&1["in"] || 0) + (&1["out"] || 0)))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    %{
      tok: tok,
      by_role: by_role,
      role_max: role_max,
      history: history,
      hist_max: hist_max,
      members: members(uri),
      materials: materials(ws, sid),
      knowledge_bytes: knowledge_bytes(ws, sid),
      published: published_for(ws, sid)
    }
  end

  defp gather(_, _, _), do: nil

  defp members(uri) do
    case safe(fn -> Ezagent.Kind.get_slice(uri, :chat) end, :error) do
      {:ok, %{members: m}} when is_map(m) ->
        m
        |> Map.keys()
        |> Enum.map(&mem_to_s/1)
        |> Enum.uniq()
        |> Enum.map(fn s -> %{name: short_name(s), role: classify(s)} end)
        |> Enum.sort_by(&role_order(&1.role))

      _ ->
        []
    end
  end

  defp materials(ws, sid) do
    items = safe(fn -> Materials.list(ws, sid) end, [])

    # Materials.list/2 returns STRING-keyed maps (%{"path","name","type","size"}),
    # so access with string keys — `&1.type` raised KeyError and crashed the LV
    # (→ reconnect → re-mount on the default session) whenever a session had any
    # materials.
    by_type =
      items
      |> Enum.group_by(&(&1["type"] || "other"))
      |> Enum.map(fn {type, list} ->
        {type, %{count: length(list), size: list |> Enum.map(&(&1["size"] || 0)) |> Enum.sum()}}
      end)
      |> Enum.sort_by(fn {_t, v} -> -v.count end)

    %{
      count: length(items),
      size: items |> Enum.map(&(&1["size"] || 0)) |> Enum.sum(),
      by_type: by_type
    }
  end

  defp knowledge_bytes(ws, sid) do
    safe(fn -> Knowledge.get(ws, sid) end, "") |> to_string() |> byte_size()
  end

  defp published_for(ws, sid) do
    safe(fn -> SavedClasses.list_published() end, [])
    |> Enum.filter(&(&1["ws"] == ws and &1["published_from"] == sid))
  end

  # ── classify / labels ──

  defp classify(s) when is_binary(s) do
    cond do
      String.contains?(s, "/loombuilder_") -> "builder"
      String.contains?(s, "/loomorch_") -> "orchestrator"
      String.contains?(s, "/loomsalespersonsub_") -> "salesperson-worker"
      String.contains?(s, "/loomsalesperson_") -> "salesperson"
      String.contains?(s, "/loommeta_") -> "meta"
      String.contains?(s, "/loomworker_") -> "worker"
      String.contains?(s, "/user/") or String.starts_with?(s, "entity://user") -> "user"
      true -> "other"
    end
  end

  defp role_label("builder"), do: "页面生成 (builder)"
  defp role_label("orchestrator"), do: "编排器"
  defp role_label("worker"), do: "主题 Worker"
  defp role_label("salesperson"), do: "Salesperson 预览助手"
  defp role_label("salesperson-worker"), do: "Salesperson 子助手"
  defp role_label("meta"), do: "元代理"
  defp role_label("user"), do: "用户"
  defp role_label(_), do: "其它"

  defp role_order("user"), do: 0
  defp role_order("orchestrator"), do: 1
  defp role_order("builder"), do: 2
  defp role_order("worker"), do: 3
  defp role_order("meta"), do: 4
  defp role_order("salesperson"), do: 5
  defp role_order("salesperson-worker"), do: 6
  defp role_order(_), do: 9

  # literal class strings (Tailwind 不能动态拼颜色)
  defp role_dot("builder"), do: "bg-sky-500"
  defp role_dot("orchestrator"), do: "bg-violet-500"
  defp role_dot("worker"), do: "bg-emerald-500"
  defp role_dot("salesperson"), do: "bg-amber-500"
  defp role_dot("salesperson-worker"), do: "bg-orange-400"
  defp role_dot("meta"), do: "bg-rose-500"
  defp role_dot("user"), do: "bg-zinc-400"
  defp role_dot(_), do: "bg-zinc-300"

  defp role_chip("builder"), do: "bg-sky-50 text-sky-700 dark:bg-sky-950 dark:text-sky-300"

  defp role_chip("orchestrator"),
    do: "bg-violet-50 text-violet-700 dark:bg-violet-950 dark:text-violet-300"

  defp role_chip("worker"),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"

  defp role_chip("salesperson"), do: "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"

  defp role_chip("salesperson-worker"),
    do: "bg-orange-50 text-orange-700 dark:bg-orange-950 dark:text-orange-300"

  defp role_chip("meta"), do: "bg-rose-50 text-rose-700 dark:bg-rose-950 dark:text-rose-300"
  defp role_chip("user"), do: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
  defp role_chip(_), do: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"

  defp kpi_tone("indigo"),
    do:
      "border-indigo-200 bg-indigo-50 text-indigo-900 dark:border-indigo-900 dark:bg-indigo-950/40 dark:text-indigo-100"

  defp kpi_tone("emerald"),
    do:
      "border-emerald-200 bg-emerald-50 text-emerald-900 dark:border-emerald-900 dark:bg-emerald-950/40 dark:text-emerald-100"

  defp kpi_tone("sky"),
    do:
      "border-sky-200 bg-sky-50 text-sky-900 dark:border-sky-900 dark:bg-sky-950/40 dark:text-sky-100"

  defp kpi_tone("violet"),
    do:
      "border-violet-200 bg-violet-50 text-violet-900 dark:border-violet-900 dark:bg-violet-950/40 dark:text-violet-100"

  defp kpi_tone(_),
    do:
      "border-zinc-200 bg-white text-zinc-900 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-100"

  defp mat_dot("image"), do: "bg-pink-500"
  defp mat_dot("text"), do: "bg-blue-500"
  defp mat_dot(_), do: "bg-zinc-400"

  defp mat_label("image"), do: "图片"
  defp mat_label("text"), do: "文本"
  defp mat_label(_), do: "其它"

  # ── number / string formatting ──

  defp total_tokens(tok), do: (tok["input"] || 0) + (tok["output"] || 0)
  defp role_total(m), do: (m["input"] || 0) + (m["output"] || 0)

  defp avg(_n, c) when c in [0, nil], do: "0"
  defp avg(n, c), do: fmt(round((n || 0) / c))

  defp fmt(n) when is_number(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 2)}M"
  defp fmt(n) when is_number(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp fmt(n) when is_number(n), do: n |> trunc() |> Integer.to_string()
  defp fmt(_), do: "0"

  defp money(v) when is_number(v) and v > 0,
    do: "$" <> :erlang.float_to_binary(v * 1.0, decimals: cost_dec(v))

  defp money(_), do: "$0"
  defp cost_dec(v) when v >= 1, do: 2
  defp cost_dec(v) when v >= 0.01, do: 3
  defp cost_dec(_), do: 4

  defp dur(ms) when is_number(ms) and ms >= 60_000, do: "#{Float.round(ms / 60_000, 1)} 分"
  defp dur(ms) when is_number(ms) and ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)} 秒"
  defp dur(ms) when is_number(ms) and ms > 0, do: "#{trunc(ms)} ms"
  defp dur(_), do: "—"

  defp bytes(n) when is_number(n) and n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp bytes(n) when is_number(n) and n >= 1_024, do: "#{Float.round(n / 1_024, 1)} KB"
  defp bytes(n) when is_number(n), do: "#{trunc(n)} B"
  defp bytes(_), do: "0 B"

  defp pct(_p, w) when w in [0, nil], do: 0
  defp pct(p, w) when is_number(p) and is_number(w) and w > 0, do: round(p / w * 100)
  defp pct(_, _), do: 0

  defp short_time(nil), do: "—"

  defp short_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        "#{pad(dt.month)}-#{pad(dt.day)} #{pad(dt.hour)}:#{pad(dt.minute)}"

      _ ->
        iso
    end
  end

  defp short_time(_), do: "—"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)

  defp short_token(t) when is_binary(t) and byte_size(t) > 12, do: String.slice(t, 0, 8) <> "…"
  defp short_token(t), do: to_string(t)

  defp short_name(s) when is_binary(s) do
    s |> String.split("/") |> List.last() |> to_string()
  end

  defp short_name(s), do: to_string(s)

  defp mem_to_s(%URI{} = u), do: URI.to_string(u)
  defp mem_to_s(s) when is_binary(s), do: s
  defp mem_to_s(other), do: inspect(other)

  defp ws_sid(%URI{scheme: "session", host: "loom", path: path}) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [ws, sid | _] -> {ws, sid}
      _ -> {nil, nil}
    end
  end

  defp ws_sid(_), do: {nil, nil}

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
