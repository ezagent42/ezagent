defmodule EzagentPluginLiveview.Views.ConversationView do
  @moduledoc """
  Phase 8b — default Session view: chat message stream.

  Renders the `@messages_stream` (owned by the wrapping admin_live)
  inside the SessionEditor's main area. Applies to every session
  (every session has a conversation, even if empty).

  Implements `Ezagent.UI.SessionView`. Registered by
  `EzagentPluginLiveview.Application.start/2`.
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-3 plugin component; runtime backend
  # reference to the host app's EzagentWeb.Gettext (no compile-time dep).
  use Gettext, backend: EzagentPluginLiveview.Gettext

  @impl true
  def id, do: :conversation

  @impl true
  def label, do: gettext("Chat")

  @impl true
  def icon, do: "message-square"

  @impl true
  # Every session has a conversation view.
  def applies_to?(_session_uri), do: true

  @impl true
  def render(assigns) do
    # Phase 8c PR-B (Allen 2026-05-20) — empty-state aware. When the
    # session has zero messages, the main area is otherwise a blank
    # white expanse; replace it with a subtle dot-grid + minimal
    # affordance so it reads as "this is where messages will appear",
    # not "is this page broken?". Inferred from `@empty_state?` which
    # admin_live computes from the stream (stays nil during render
    # while stream hasn't been touched).
    assigns =
      assigns
      |> assign_new(:empty_state?, fn ->
        # default: assume non-empty (admin_live overrides when known)
        false
      end)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0 relative">
      <%!-- 一键回到最新:翻看历史(未贴底)时由 ScrollOnUpdate 钩子显示;点了滚到底。 --%>
      <button
        type="button"
        id="jump-latest-btn"
        class="hidden absolute bottom-4 right-4 z-10 px-3 py-1.5 rounded-full shadow-md bg-blue-600 text-white text-xs hover:bg-blue-700"
      >
        ↓ {gettext("Jump to latest")}
      </button>
      <div
        :if={@oldest_cursor}
        class="text-center py-1 bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800 shrink-0"
      >
        <button
          type="button"
          id="load-older-btn"
          phx-click="load_older_messages"
          class="px-3 py-1 bg-white dark:bg-zinc-900 text-blue-600 dark:text-blue-400 border border-zinc-300 dark:border-zinc-700 rounded text-xs hover:bg-zinc-50 dark:hover:bg-zinc-900"
        >
          ↑ {gettext("Load older")}
        </button>
      </div>

      <%!-- Empty state — refined minimalism: subtle dot-grid background,
            no clip art, a small monospace caption that names what this
            surface IS. Disappears the moment a real message lands. --%>
      <div
        :if={@empty_state?}
        class="flex-1 flex items-center justify-center ez-dot-grid"
      >
        <div class="text-center">
          <div class="font-mono text-xs uppercase tracking-widest text-zinc-400 dark:text-zinc-600">
            {gettext("empty session")}
          </div>
          <div class="mt-2 text-sm text-zinc-500">
            {gettext("Type a message below to begin.")}
          </div>
        </div>
      </div>

      <div
        :if={not @empty_state?}
        id="messages"
        phx-update="stream"
        phx-hook="ScrollOnUpdate"
        class="flex-1 overflow-y-auto px-4 py-3 bg-zinc-50 dark:bg-zinc-950 space-y-2"
      >
        <%!-- PR-2 of Read Receipts rollout — `ViewportMarkRead` JS
              hook (IntersectionObserver + 250ms dwell) fires
              `mark_displayed` with `{msg_id: row.id}` when this row
              enters viewport. AdminLive's handle_event calls
              `Ezagent.Chat.ReadMarker.mark(session, user, msg_id,
              :displayed)`. Fire-once per element per mount. --%>
        <div
          :for={{dom_id, row} <- @messages_stream}
          id={dom_id}
          phx-hook="ViewportMarkRead"
          data-msg-id={row.id}
          class={[
            "max-w-2xl rounded-lg px-3 py-2 border",
            row.sender_kind == :user &&
              "bg-blue-50 dark:bg-blue-950 border-blue-200 dark:border-blue-800 ml-auto",
            row.sender_kind == :agent &&
              "bg-emerald-50 dark:bg-emerald-950 border-emerald-200 dark:border-emerald-800 mr-auto",
            row.sender_kind == :other &&
              "bg-zinc-100 dark:bg-zinc-900 border-zinc-200 dark:border-zinc-800 mx-auto"
          ]}
        >
          <%!-- Username & Auth UI Task 1 (PR-O) — display name primary,
                URI secondary (mono). Falls back to URI when no profile. --%>
          <div class="flex items-baseline gap-2 text-[11px] text-zinc-500">
            <span class="font-medium text-zinc-700 dark:text-zinc-300">
              {sender_display_for(row)}
            </span>
            <span>·</span>
            <span>{format_time(row.at)}</span>
            <%!-- 复制消息内容(委托监听见 app.js 的 [data-copy] handler)。 --%>
            <button
              :if={row.text != ""}
              type="button"
              data-copy={row.text}
              data-label={gettext("Copy")}
              title={gettext("Copy message")}
              class="ml-auto text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
            >{gettext("Copy")}</button>
          </div>
          <div class="font-mono text-[10px] text-zinc-400 dark:text-zinc-600 break-all">
            {row.sender}
          </div>
          <%!-- Phase 5 PR 5 invariant: the AdminLiveTest "Load older"
                regression uses the `<text></div>` boundary to disambiguate
                `histmsg-1` from `histmsg-10` etc. HEEx must emit
                `{row.text}` immediately adjacent to `</div>` — any
                whitespace between them (introduced by a multi-line
                rewrite of this element) breaks the pagination invariant
                test. Keep the row.text + `</div>` on the same line. --%>
          <div
            :if={row.text != ""}
            class="mt-1 text-sm whitespace-pre-wrap break-words"
            style={collapse_style(row.text)}
          >{row.text}</div>
          <%!-- 过长消息折叠:初始 clamp(见 collapse_style),点切换(app.js [data-collapse-toggle])。 --%>
          <button
            :if={long_text?(row.text)}
            type="button"
            data-collapse-toggle
            class="mt-0.5 text-[11px] text-blue-600 dark:text-blue-400 hover:underline"
          >{gettext("Show all")} ▼</button>
          <div :if={attachments_of(row) != []} class="mt-2 flex gap-1 flex-wrap">
            <a
              :for={{name, href} <- attachments_of(row)}
              href={href}
              target="_blank"
              class="inline-flex items-center gap-1 px-2 py-1 bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded text-xs text-blue-600 dark:text-blue-400 hover:bg-zinc-50 dark:hover:bg-zinc-900"
            >
              📎 {name}
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp format_time(_), do: ""

  # 过长消息折叠:超阈值的初始 clamp 到 16rem(JS 切换展开/收起)。
  @collapse_threshold 600
  defp long_text?(t) when is_binary(t), do: String.length(t) > @collapse_threshold
  defp long_text?(_), do: false
  defp collapse_style(t), do: if(long_text?(t), do: "max-height:16rem;overflow:hidden", else: nil)

  defp attachments_of(%{attachments: list}) when is_list(list), do: list
  defp attachments_of(_), do: []

  # Username & Auth UI Task 1 — pre-PR rows lack sender_display; fall
  # back to sender URI string so legacy data still renders.
  defp sender_display_for(%{sender_display: name}) when is_binary(name) and name != "", do: name
  defp sender_display_for(%{sender: s}), do: s
end
