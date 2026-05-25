defmodule EzagentPluginLiveview.Admin.MemberPanel do
  @moduledoc """
  Right pane: the session's unified member list + an Invite modal.

  Stateless — parent (`AdminLive`) reads members from the Session Kind
  via `:sys.get_state` and refreshes on
  `member_joined`/`member_left`/`member_offline`.

  ## V1 UI SPEC §2C — member panel redesign

  The pre-V1 sidebar had a confusing split: a MEMBERS list AND a
  separate FLOATING AGENTS `<select>`. Per SPEC §2C.3 those merge into
  **one unified list** — floating agents are simply members added
  ad-hoc, so they render identically. Each row carries the procedural
  `<.avatar>`, the display name, the URI (`font-mono` small), an online
  `<.status_dot>`, and the per-row cc-agent PTY button.

  The FLOATING AGENTS `<select>` is gone; in its place an **Invite**
  button opens a `<.modal>` with two affordances (SPEC §2C.3):

    1. *Add existing* — a `<.uri_picker mode={:single} kinds={[:entity]}>`
       (PR-1's component) over entities not already in the session.
       Submitting `invite_member` dispatches `chat.join`.
    2. *Create new agent* — a link to the existing
       `/identities/agents/new` page (AgentNewLive). The create form is
       NOT rebuilt in the modal.

  The `invite_member` handler in `AdminLive` is a NEW dedicated
  `:call`-mode handler (SPEC §2C.4) — it does NOT reuse the deleted
  `add_floating_agent` `:cast` path, which silently dropped
  `:unauthorized` / `:cross_workspace_denied` failures (Decision #134,
  the no-silent-drop invariant).

  Phase 8b — for every cc-managed agent member
  (`entity://agent/team-alpha/cc_*`) the row renders a small PTY (🖥️)
  button. Click dispatches `switch_to_pty_for_agent` which sets the
  SessionEditor view-mode to `:pty` and binds xterm.js to that agent.
  """

  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-3 plugin component; runtime backend
  # reference to the host app's EzagentWeb.Gettext (no compile-time dep).
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Primitives
  use EzagentDomainUi.Components

  attr :members, :list, required: true

  # Username & Auth UI Task 1 (PR-O) — `%{uri_str => display_name}`
  # batch-resolved by admin_live via `Ezagent.EntityPresenter.display_many/1`.
  # Empty map = fall back to URI path segment for each member.
  attr :display_map, :map, default: %{}

  # V1 UI SPEC §2C.3 — Invite modal state. `invite_open` toggles the
  # `<.modal>`; `invite_options` is the `uri_picker`'s entity option
  # list (entities NOT already in the session, scoped to the session's
  # workspace — computed by `AdminLive.assign_session_context/2`).
  attr :invite_open, :boolean, default: false
  attr :invite_options, :list, default: []

  def member_panel(assigns) do
    ~H"""
    <aside id="session-members" class="p-3 text-zinc-800 dark:text-zinc-200">
      <div class="flex items-center justify-between mb-2">
        <h3 class="text-[10px] uppercase tracking-wide text-zinc-500">{gettext("Members")}</h3>
        <.button
          type="button"
          variant="outline"
          size="sm"
          phx-click="open_invite_modal"
          id="invite-member-button"
        >
          <.icon name="plus" size="xs" class="mr-1" /> {gettext("Invite")}
        </.button>
      </div>

      <%!-- V1 UI SPEC §2C.3 — one unified member list. `members`
            already includes ex-"floating" agents (they ARE members);
            nothing distinguishes them in the markup. AdminLive
            guarantees the session exists before this renders, so an
            empty list just means no member has joined yet. --%>
      <p :if={@members == []} id="session-members-empty" class="text-xs text-zinc-500">
        {gettext("No members yet. Use Invite to add an agent.")}
      </p>
      <ul :if={@members != []} id="session-members-table" class="space-y-1.5">
        <li
          :for={member <- @members}
          class="flex items-start gap-2 border-b border-zinc-100 dark:border-zinc-900 pb-1.5"
        >
          <.avatar uri={member.uri} size="sm" class="mt-0.5" />
          <div class="flex-1 min-w-0">
            <%!-- Display name primary, URI mono subtitle. --%>
            <div class="text-xs font-medium text-zinc-800 dark:text-zinc-200 truncate">
              {display_for(member.uri, @display_map)}
            </div>
            <div class="font-mono text-[10px] text-zinc-400 dark:text-zinc-600 break-all">
              {member.uri}
            </div>
            <div class={member_status_class(member.online)}>
              <.status_dot color={if member.online, do: "green", else: "gray"} />
              {if member.online, do: gettext("online"), else: gettext("offline")}
              <span :if={member.last_seen} class="text-zinc-400 dark:text-zinc-600 font-normal">
                · {DateTime.to_iso8601(member.last_seen)}
              </span>
            </div>
          </div>
          <button
            :if={cc_agent_uri?(member.uri)}
            type="button"
            phx-click="switch_to_pty_for_agent"
            phx-value-agent={member.uri}
            title={gettext("Open PTY for %{name}", name: display_for(member.uri, @display_map))}
            aria-label={gettext("Open PTY for %{name}", name: display_for(member.uri, @display_map))}
            class="p-1 text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800 rounded shrink-0"
          >
            <.icon name="terminal" size="xs" />
          </button>
        </li>
      </ul>

      <%!-- V1 UI SPEC §2C.3 — Invite modal. Reuses the Tier-2 `<.modal>`
            atom + PR-1's `<.uri_picker>`. "Add existing" submits
            `invite_member`; "Create new agent" routes to the existing
            AgentNewLive instead of rebuilding the form here. --%>
      <.modal id="invite-member-modal" open={@invite_open} on_close="close_invite_modal">
        <:header>{gettext("Invite a member")}</:header>
        <:body>
          <div class="space-y-4">
            <div>
              <h4 class="text-xs font-semibold text-zinc-700 dark:text-zinc-300 mb-1">
                {gettext("Add existing")}
              </h4>
              <p class="text-[11px] text-zinc-500 dark:text-zinc-400 mb-2">
                {gettext("Pick an entity to add to this session as a member.")}
              </p>
              <.form
                for={%{}}
                as={:invite}
                phx-submit="invite_member"
                id="invite-member-form"
                class="flex items-start gap-2"
              >
                <div class="flex-1">
                  <.uri_picker
                    name="member_uri"
                    mode={:single}
                    kinds={[:entity]}
                    options={@invite_options}
                    placeholder={gettext("Search entities…")}
                  />
                </div>
                <.button type="submit" variant="primary" size="sm">{gettext("Invite")}</.button>
              </.form>
            </div>

            <div class="border-t border-zinc-200 dark:border-zinc-800 pt-3">
              <h4 class="text-xs font-semibold text-zinc-700 dark:text-zinc-300 mb-1">
                {gettext("Create new agent")}
              </h4>
              <p class="text-[11px] text-zinc-500 dark:text-zinc-400 mb-2">
                {gettext("Need a new agent first? Create one, then invite it.")}
              </p>
              <.link
                navigate="/identities/agents/new"
                id="invite-create-agent-link"
                class="inline-flex items-center text-xs font-medium text-blue-600 dark:text-blue-400 hover:text-blue-700 dark:hover:text-blue-300"
              >
                <.icon name="plus" size="xs" class="mr-1" /> {gettext("New agent")}
              </.link>
            </div>
          </div>
        </:body>
        <:footer>
          <.button type="button" variant="ghost" size="sm" phx-click="close_invite_modal">
            {gettext("Close")}
          </.button>
        </:footer>
      </.modal>
    </aside>
    """
  end

  # Username & Auth UI Task 1 — falls back to URI path segment when
  # the batch map is missing (defensive for pre-PR call sites).
  defp display_for(uri_str, %{} = display_map) do
    case Map.get(display_map, uri_str) do
      name when is_binary(name) and name != "" -> name
      _ -> Ezagent.EntityPresenter.display(uri_str)
    end
  end

  # Phase 8b — cc-managed agents have the `cc_` flavor-prefix in their
  # name segment (PR #149 flavor-prefix scheme). Workspace-agnostic check:
  # match `entity://agent/<any-workspace>/cc_<name>`.
  #
  # Lesson 2026-05-25: the prior hard-coded `entity://agent/default/cc_`
  # prefix made cc agents in non-default workspaces (e.g. `system`)
  # silently invisible to the per-row PTY button (🖥️). Surfaced by the
  # workspace-rename impl subagent (PR #335). Cherry-picked here as a
  # standalone fix.
  defp cc_agent_uri?("entity://agent/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_workspace, "cc_" <> _] -> true
      _ -> false
    end
  end

  defp cc_agent_uri?(_), do: false

  defp member_status_class(true),
    do: "text-[10px] text-emerald-600 dark:text-emerald-400 font-semibold flex items-center gap-1"

  defp member_status_class(false),
    do: "text-[10px] text-zinc-400 dark:text-zinc-600 flex items-center gap-1"
end
