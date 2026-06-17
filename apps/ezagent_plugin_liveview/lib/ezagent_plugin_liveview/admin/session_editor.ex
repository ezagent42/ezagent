defmodule EzagentPluginLiveview.Admin.SessionEditor do
  @moduledoc """
  Phase 8b — Main Window's Session editor.

  Stateless Phoenix.Component composing:

    1. `session_header/1` — session selector + create + view-switcher + setting dropdown
    2. `:main_view` slot — the active SessionView's `render/1` output
    3. `message_composer/1` — input with @ autocomplete + file upload + send

  Replaces Phase 4a's `EzagentPluginLiveview.Admin.ChatWindow` which
  hard-coded a single "session header + message stream + compose"
  layout. The view-switcher is now plugin-driven (Phase 8b §1.2).

  Parent (admin_live) owns all assigns + event handlers. This module
  is a pure renderer.
  """

  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-3 plugin component; runtime backend
  # reference to the host app's EzagentWeb.Gettext (no compile-time dep).
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Primitives
  alias Phoenix.LiveView.JS

  attr(:current_session_uri, URI, required: true)
  attr(:sessions, :list, required: true)
  attr(:applicable_views, :list, required: true)
  attr(:current_view, :atom, required: true)
  attr(:new_session_form, :map, required: true)
  # SPEC #366 (Allen 2026-05-26) — template-class dropdown options.
  # `[String.t()]` of class keys from the current workspace's
  # `session_templates` map; empty list triggers the "no templates"
  # empty-state inside `create_session_button/1`.
  attr(:template_class_options, :list, default: [])
  attr(:compose_form, :map, required: true)
  attr(:member_options, :list, required: true)
  attr(:session_info, :map, required: true)
  attr(:feishu_chat_ids, :list, default: [])
  attr(:debug_open, :boolean, default: false)
  attr(:uploads, :map, default: nil)
  attr(:flash_error, :string, default: nil)
  slot(:main_view, required: true)

  def session_editor(assigns) do
    ~H"""
    <div id="session-editor" class="flex-1 flex flex-col min-h-0">
      <.session_header
        current_session_uri={@current_session_uri}
        sessions={@sessions}
        applicable_views={@applicable_views}
        current_view={@current_view}
        new_session_form={@new_session_form}
        template_class_options={@template_class_options}
        session_info={@session_info}
        feishu_chat_ids={@feishu_chat_ids}
        debug_open={@debug_open}
      />

      <div class="flex-1 flex flex-col min-h-0">
        {render_slot(@main_view)}
      </div>

      <.message_composer
        compose_form={@compose_form}
        member_options={@member_options}
        uploads={@uploads}
        flash_error={@flash_error}
      />
    </div>
    """
  end

  # --- session_header -------------------------------------------------------

  attr(:current_session_uri, URI, required: true)
  attr(:sessions, :list, required: true)
  attr(:applicable_views, :list, required: true)
  attr(:current_view, :atom, required: true)
  attr(:new_session_form, :map, required: true)
  attr(:template_class_options, :list, default: [])
  attr(:session_info, :map, required: true)
  attr(:feishu_chat_ids, :list, default: [])
  attr(:debug_open, :boolean, default: false)

  defp session_header(assigns) do
    ~H"""
    <header class="flex items-center gap-2 px-3 py-2 border-b border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shrink-0">
      <button
        type="button"
        phx-click="refresh_session"
        title={gettext("Refresh session list + reload this session (tabs / members / state)")}
        aria-label={gettext("Refresh session")}
        class="shrink-0 p-1 rounded text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800"
      >
        <.icon name="refresh" size="sm" />
      </button>
      <.session_selector current_session_uri={@current_session_uri} sessions={@sessions} />
      <.loom_link current_session_uri={@current_session_uri} />
      <.loom_save_template_button current_session_uri={@current_session_uri} />
      <.create_session_button
        new_session_form={@new_session_form}
        template_class_options={@template_class_options}
      />

      <div class="flex-1" />

      <.view_switcher applicable_views={@applicable_views} current_view={@current_view} />
      <.setting_dropdown
        current_session_uri={@current_session_uri}
        session_info={@session_info}
        feishu_chat_ids={@feishu_chat_ids}
        debug_open={@debug_open}
      />
    </header>
    """
  end

  # --- loom_link ------------------------------------------------------------
  # loom 前端集成: 给 loom session 在 header 加一个"打开 Loom"入口,新标签打开该
  # session 专属的 ai-ui-builder 页(/loom/:ws/:name,由 EzagentPluginLoom.WebPlug
  # 提供)。仅对 session://loom/... 显示;非 loom session 返回 nil → 不渲染。

  attr(:current_session_uri, URI, required: true)

  defp loom_link(assigns) do
    assigns = assign(assigns, :loom_url, loom_session_url(assigns.current_session_uri))

    ~H"""
    <a
      :if={@loom_url}
      href={@loom_url}
      target="_blank"
      rel="noopener"
      class="inline-flex items-center gap-1 text-xs px-2 py-1 rounded border border-violet-300 dark:border-violet-700 text-violet-700 dark:text-violet-300 hover:bg-violet-50 dark:hover:bg-violet-950"
      title={gettext("Open this session's Loom page-builder in a new tab")}
    >
      {gettext("Open Loom")} ↗
    </a>
    """
  end

  # --- loom_save_template_button --------------------------------------------
  # 「存为模板」按钮在 loom iframe 外,点它经 JS hook 向 loom iframe postMessage,由
  # ChatPanel 开它现有的 SaveAsTemplateModal(存模板逻辑仍在 loom 前端 + SDK,admin
  # 只负责触发)。仅 loom session 显示。

  attr(:current_session_uri, URI, required: true)

  defp loom_save_template_button(assigns) do
    assigns = assign(assigns, :is_loom, loom_session_url(assigns.current_session_uri) != nil)

    ~H"""
    <button
      :if={@is_loom}
      type="button"
      id="loom-save-template-btn"
      phx-hook="LoomSaveTemplate"
      class="inline-flex items-center gap-1 text-xs px-2 py-1 rounded border border-emerald-300 dark:border-emerald-700 text-emerald-700 dark:text-emerald-300 hover:bg-emerald-50 dark:hover:bg-emerald-950"
      title={gettext("Save the current Loom page as a reusable template")}
    >
      {gettext("Save as Template")}
    </button>
    """
  end

  # workspace-first session URI `session://<ws>/loom/<name>` → "/loom/<ws>/<name>";
  # nil for non-loom sessions (class segment != "loom").
  defp loom_session_url(%URI{scheme: "session", host: ws, path: path})
       when is_binary(ws) and ws != "" and is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["loom", name | _] -> "/loom/#{ws}/#{name}"
      _ -> nil
    end
  end

  defp loom_session_url(_), do: nil

  # --- session_selector -----------------------------------------------------

  attr(:current_session_uri, URI, required: true)
  attr(:sessions, :list, required: true)

  defp session_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-[10px] uppercase tracking-wide text-zinc-500">{gettext("Session")}</span>
      <form phx-change="switch_session" class="contents">
        <select
          name="session_uri"
          id="session-selector"
          class="text-xs font-mono px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900"
        >
          <option
            :for={uri <- @sessions}
            value={URI.to_string(uri)}
            selected={URI.to_string(uri) == URI.to_string(@current_session_uri)}
          >
            {URI.to_string(uri)}
          </option>
        </select>
      </form>
    </div>
    """
  end

  # --- create_session_button ------------------------------------------------

  attr(:new_session_form, :map, required: true)
  # SPEC #366 (Allen 2026-05-26) — `[String.t()]` from
  # `Workspace.Store.get_by_name(ws).session_templates |> Map.keys()`.
  # Empty list → render the empty-state pointing to /admin/templates;
  # non-empty → render a `<select>` with each key as an explicit option
  # plus a placeholder `""` (refused by the LV handler).
  attr(:template_class_options, :list, default: [])

  defp create_session_button(assigns) do
    ~H"""
    <details class="relative">
      <summary class="cursor-pointer text-xs text-blue-600 dark:text-blue-400 hover:text-blue-700 dark:hover:text-blue-300 select-none">
        {gettext("+ New")}
      </summary>
      <div class="absolute left-0 top-full mt-1 w-72 bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-md shadow-lg z-30 p-2">
        <%!-- SPEC #366 — empty-state when the workspace has zero
              `session_templates`. We deliberately do NOT silently
              fall back to a `"default"` class; the operator must
              register at least one template first. --%>
        <div :if={@template_class_options == []} class="text-xs text-zinc-600 dark:text-zinc-400">
          <p class="mb-2">
            {gettext("No templates registered in this workspace.")}
          </p>
          <p class="text-zinc-500">
            {gettext("Add one via the")}
            <.link
              navigate="/admin/templates"
              class="text-blue-600 dark:text-blue-400 hover:underline"
            >
              {gettext("template admin")}
            </.link>
            {gettext("first, then come back here to create a session.")}
          </p>
        </div>

        <.form :if={@template_class_options != []} for={@new_session_form} phx-submit="create_session">
          <label for="new_session_short_name" class="block text-[10px] text-zinc-500 mb-1">
            {gettext("New session name")}
          </label>
          <input
            type="text"
            name="new_session[short_name]"
            id="new_session_short_name"
            placeholder="architect-review"
            class="w-full text-xs px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded"
          />

          <%!-- Codex PR #369 r1 MED — the option values are the
                workspace's `session_templates` keys (template instance
                names like "architect-review"), NOT registered template-
                class names (`Ezagent.Kind.Template.template_name/0`
                values like "session.generic"). Each key becomes the
                URI's template segment; downstream code treats that segment as informational,
                downstream code treats that segment as informational,
                not as a `TemplateRegistry.lookup/1` key (verified —
                see `rg TemplateRegistry.lookup apps/*/lib`). Label
                reflects what the operator actually sees in
                `/admin/templates`. --%>
          <label for="new_session_template_class" class="block text-[10px] text-zinc-500 mb-1 mt-2">
            {gettext("Template")}
          </label>
          <select
            name="new_session[template_class]"
            id="new_session_template_class"
            required
            class="w-full text-xs px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900"
          >
            <%!-- Placeholder forces an explicit pick; LV handler refuses
                  empty-string submissions. --%>
            <option value="" disabled selected>{gettext("— pick a template —")}</option>
            <option :for={class <- @template_class_options} value={class}>{class}</option>
          </select>

          <button
            type="submit"
            class="mt-2 w-full px-2 py-1 bg-blue-600 text-white text-xs rounded hover:bg-blue-700 dark:hover:bg-blue-500"
          >
            {gettext("Create")}
          </button>
        </.form>
      </div>
    </details>
    """
  end

  # --- view_switcher --------------------------------------------------------

  attr(:applicable_views, :list, required: true)
  attr(:current_view, :atom, required: true)

  defp view_switcher(assigns) do
    ~H"""
    <div
      id="view-switcher"
      class="flex items-center gap-px border border-zinc-300 dark:border-zinc-700 rounded overflow-hidden"
    >
      <button
        :for={view <- @applicable_views}
        type="button"
        phx-click="switch_view"
        phx-value-view={view.id}
        class={[
          "flex items-center gap-1 px-2 py-1 text-xs",
          (view.id == @current_view &&
             "bg-zinc-900 dark:bg-zinc-100 text-white dark:text-zinc-900") ||
            "bg-white dark:bg-zinc-900 text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
        ]}
        title={view.label}
      >
        <.icon name={view.icon} size="xs" />
        <span>{view.label}</span>
      </button>
    </div>
    """
  end

  # --- setting_dropdown -----------------------------------------------------

  attr(:current_session_uri, URI, required: true)
  attr(:session_info, :map, required: true)
  attr(:feishu_chat_ids, :list, default: [])
  attr(:debug_open, :boolean, default: false)

  defp setting_dropdown(assigns) do
    # Task #52 (2026-05-27, Allen 02:09) — fix session routing nav
    # misroute. The "Routing rules for this session" link USED to
    # send operators to `/admin/routing?session=<encoded>` (the
    # GLOBAL routing LV with a query arg the global LV never read);
    # what they actually want is the session-scoped routing rule
    # editor — already implemented as the in-session `:routing`
    # SessionView (`EzagentDomainUi.Routing.RoutingView`) and
    # accessible via the view switcher.
    #
    # Switching to a `phx-click="switch_view"` with `view=routing`
    # flips the current view in place rather than navigating away
    # (parity with the view-switcher buttons above). The global
    # `/admin/routing` LV remains the canonical cross-session
    # editor — reachable from the admin shell.
    assigns = assign(assigns, :routing_view_id, "routing")

    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click={
          JS.toggle(
            to: "#session-setting-menu",
            in: {"ease-out duration-150", "opacity-0 -translate-y-1", "opacity-100 translate-y-0"},
            out: {"ease-in duration-100", "opacity-100 translate-y-0", "opacity-0 -translate-y-1"}
          )
        }
        title={gettext("Session settings")}
        aria-label={gettext("Session settings")}
        class="p-1 text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800 rounded transition-colors"
      >
        <.icon name="settings" size="sm" />
      </button>

      <%!-- Phase 8c follow-up (Allen 2026-05-20) — outside-click dismiss --%>
      <div
        id="session-setting-menu"
        phx-click-away={
          JS.hide(
            transition:
              {"ease-in duration-100", "opacity-100 translate-y-0", "opacity-0 -translate-y-1"}
          )
        }
        class="hidden absolute right-0 top-full mt-1 w-80 bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-md shadow-lg z-40 text-xs transition transform"
      >
        <div class="px-3 py-2 border-b border-zinc-200 dark:border-zinc-800">
          <div class="text-[10px] uppercase tracking-wide text-zinc-500">{gettext("Session")}</div>
          <div class="font-mono text-zinc-800 dark:text-zinc-200 break-all mt-0.5">
            {URI.to_string(@current_session_uri)}
          </div>
        </div>

        <div class="px-3 py-2 border-b border-zinc-200 dark:border-zinc-800">
          <label class="flex items-center justify-between cursor-pointer">
            <div class="flex items-center gap-2">
              <.icon name="bug" size="xs" />
              <span class="text-zinc-700 dark:text-zinc-300">{gettext("Debug events panel")}</span>
            </div>
            <button
              type="button"
              phx-click="toggle_debug_panel"
              class={[
                "relative inline-flex h-4 w-7 items-center rounded-full transition-colors",
                (@debug_open && "bg-emerald-600") || "bg-zinc-300"
              ]}
            >
              <span class={[
                "inline-block h-3 w-3 transform rounded-full bg-white dark:bg-zinc-900 transition-transform",
                (@debug_open && "translate-x-3.5") || "translate-x-0.5"
              ]} />
            </button>
          </label>
        </div>

        <div class="px-3 py-2 border-b border-zinc-200 dark:border-zinc-800">
          <div class="flex items-center gap-2 mb-1">
            <.icon name="message-square" size="xs" />
            <span class="text-[10px] uppercase tracking-wide text-zinc-500">
              {gettext("Feishu binding")}
            </span>
          </div>
          <div :if={@feishu_chat_ids == []} class="text-zinc-500 italic">
            {gettext("no chat bound — bind via mix ezagent.feishu.chat.bind")}
          </div>
          <ul :if={@feishu_chat_ids != []} class="space-y-1">
            <li :for={chat_id <- @feishu_chat_ids} class="flex items-center justify-between gap-2">
              <code class="text-[10px] truncate text-zinc-700 dark:text-zinc-300">{chat_id}</code>
              <button
                type="button"
                phx-click="unbind_feishu_chat"
                phx-value-chat_id={chat_id}
                data-confirm={
                  gettext("Unbind Feishu chat %{chat_id} from this session?", chat_id: chat_id)
                }
                class="text-[10px] text-rose-600 dark:text-rose-400 hover:text-rose-700"
              >
                {gettext("Unbind")}
              </button>
            </li>
          </ul>
        </div>

        <div class="px-3 py-2 border-b border-zinc-200 dark:border-zinc-800">
          <%!--
            Task #52 (2026-05-27) — switches to the session-scoped
            routing SessionView in place (not navigation). Uses the
            same `switch_view` event the view_switcher above raises.
            Also closes the dropdown so the rule list is visible.
          --%>
          <button
            type="button"
            phx-click={
              JS.dispatch("phx:close-setting-menu", to: "#session-setting-menu")
              |> JS.hide(to: "#session-setting-menu")
              |> JS.push("switch_view", value: %{"view" => @routing_view_id})
            }
            class="w-full text-left flex items-center gap-2 text-blue-600 dark:text-blue-400 hover:text-blue-700 dark:hover:text-blue-300"
          >
            <.icon name="route" size="xs" />
            <span>{gettext("Routing rules for this session")}</span>
          </button>
        </div>

        <div class="px-3 py-2">
          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-1">{gettext("Info")}</div>
          <dl class="space-y-0.5 text-zinc-700 dark:text-zinc-300">
            <div class="flex justify-between">
              <dt>{gettext("members")}</dt>
              <dd>{@session_info[:member_count] || 0}</dd>
            </div>
            <div class="flex justify-between">
              <dt>{gettext("workspace")}</dt>
              <dd class="font-mono text-[10px] truncate max-w-[60%]">
                {@session_info[:workspace_uri] || "—"}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt>{gettext("created")}</dt>
              <dd class="text-[10px]">{format_dt(@session_info[:created_at])}</dd>
            </div>
          </dl>
        </div>

        <%!--
          G-3 + G-5 stop-gap (audit 2026-05-23) — Generator info panel.
          Shown only for Generator-spawned sessions (those whose `:chat`
          slice has a non-empty template_working_copy). Ad-hoc sessions
          do not render this block — `@session_info[:generator]` is nil.
        --%>
        <div
          :if={@session_info[:generator]}
          id="session-generator-info"
          class="px-3 py-2 border-t border-zinc-200 dark:border-zinc-800"
        >
          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-1">
            {gettext("Generator")}
          </div>
          <dl class="space-y-0.5 text-zinc-700 dark:text-zinc-300">
            <div class="flex justify-between">
              <dt>{gettext("orchestrator")}</dt>
              <dd class="font-mono text-[10px] truncate max-w-[60%]">
                {generator_orchestrator(@session_info[:generator])}
              </dd>
            </div>
            <div class="flex justify-between">
              <dt>{gettext("slots")}</dt>
              <dd>
                {gettext("%{filled}/%{total} filled",
                  filled: @session_info[:generator][:filled],
                  total:
                    @session_info[:generator][:filled] +
                      @session_info[:generator][:pending]
                )}
                <span
                  :if={@session_info[:generator][:pending] > 0}
                  class="text-amber-700 dark:text-amber-300 ml-1"
                >
                  ({gettext("%{n} pending", n: @session_info[:generator][:pending])})
                </span>
              </dd>
            </div>
          </dl>
          <ul
            :if={@session_info[:generator][:agent_slots] != []}
            class="mt-1 space-y-0.5"
          >
            <li
              :for={{name, _src, worker, _gen} <- @session_info[:generator][:agent_slots]}
              class="text-[10px] font-mono flex items-center gap-1"
            >
              <span class={[
                "inline-block w-1.5 h-1.5 rounded-full",
                (worker && "bg-emerald-500") || "bg-amber-500"
              ]} />
              <span class="truncate">{name}</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp generator_orchestrator(%{orchestrator_template_uri: %URI{} = uri}),
    do: Ezagent.URI.stable_key(uri)

  defp generator_orchestrator(%{orchestrator_template_uri: uri}) when is_binary(uri), do: uri
  defp generator_orchestrator(_), do: "—"

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(_), do: "—"

  # --- message_composer -----------------------------------------------------

  attr(:compose_form, :map, required: true)
  attr(:member_options, :list, required: true)
  attr(:uploads, :map, default: nil)
  attr(:flash_error, :string, default: nil)

  defp message_composer(assigns) do
    members_json = Jason.encode!(assigns.member_options)
    assigns = assign(assigns, :members_json, members_json)

    ~H"""
    <.form
      for={@compose_form}
      phx-submit="chat_compose"
      phx-change="validate_compose"
      class="border-t border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-3 space-y-2 shrink-0"
    >
      <div
        id="mention-popover"
        class="hidden absolute z-50 bg-white dark:bg-zinc-900 border border-zinc-300 dark:border-zinc-700 rounded-md shadow-lg max-h-48 overflow-y-auto"
      >
      </div>

      <div class="flex gap-2 items-center">
        <%!-- Phase 8c follow-up (Allen 2026-05-20): the input was missing
              `value=` binding so after phx-submit + assign back to
              empty form, the browser kept its own DOM value (stale
              text after send). Binding to @compose_form[:text].value
              + phx-update="ignore" interplay would conflict with
              MentionAutocomplete hook — so we explicitly bind value
              and trust phx-change="validate_compose" to keep server
              and client in sync (no-op handler is fine; the binding
              alone is enough for clears to propagate). --%>
        <input
          type="text"
          name="chat[text]"
          id="chat-compose-input"
          value={Phoenix.HTML.Form.input_value(@compose_form, :text) || ""}
          phx-hook="MentionAutocomplete"
          data-members={@members_json}
          data-popover="#mention-popover"
          autocomplete="off"
          placeholder={gettext("Type a message... use @ to mention a member")}
          class="flex-1 px-3 py-2 border border-zinc-300 dark:border-zinc-700 rounded-md text-sm focus:outline-none focus:border-blue-400 dark:focus:border-blue-600"
        />

        <div :if={@uploads}>
          <label
            for={@uploads.attachments.ref}
            class="inline-flex items-center px-3 py-2 border border-zinc-300 dark:border-zinc-700 rounded-md text-sm cursor-pointer hover:bg-zinc-50 dark:hover:bg-zinc-900"
            title={gettext("Attach files (≤10MB each, up to 5)")}
          >
            📎
          </label>
          <.live_file_input upload={@uploads.attachments} class="hidden" />
        </div>

        <button
          type="submit"
          id="chat-send-btn"
          class="px-4 py-2 bg-emerald-600 text-white rounded-md text-sm font-medium hover:bg-emerald-700 dark:hover:bg-emerald-500"
        >
          {gettext("Send")}
        </button>
      </div>

      <div :if={@uploads && @uploads.attachments.entries != []} class="flex flex-wrap gap-1">
        <div
          :for={entry <- @uploads.attachments.entries}
          class="inline-flex items-center gap-1 px-2 py-0.5 bg-blue-50 dark:bg-blue-950 border border-blue-200 dark:border-blue-800 rounded text-[11px]"
        >
          <span>📎 {entry.client_name}</span>
          <span class="text-zinc-500">{progress_label(entry)}</span>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            aria-label={gettext("cancel %{file}", file: entry.client_name)}
            class="text-rose-600 dark:text-rose-400 hover:text-rose-700"
          >
            ×
          </button>
        </div>
        <div
          :for={err <- my_upload_errors(@uploads.attachments)}
          class="basis-full text-rose-600 dark:text-rose-400 text-[11px]"
        >
          {format_upload_error(err)}
        </div>
      </div>

      <p :if={@flash_error} class="text-xs text-rose-600 dark:text-rose-400">{@flash_error}</p>
    </.form>
    """
  end

  defp progress_label(%{progress: 100}), do: "✓"
  defp progress_label(%{progress: p}) when is_integer(p) and p > 0, do: "#{p}%"
  defp progress_label(_), do: ""

  defp my_upload_errors(%{errors: errors}) when is_list(errors), do: errors
  defp my_upload_errors(_), do: []

  defp format_upload_error({_ref, :too_large}), do: gettext("file too large (max 10MB)")
  defp format_upload_error({_ref, :too_many_files}), do: gettext("too many files (max 5)")

  defp format_upload_error({_ref, reason}),
    do: gettext("upload error: %{reason}", reason: inspect(reason))
end
