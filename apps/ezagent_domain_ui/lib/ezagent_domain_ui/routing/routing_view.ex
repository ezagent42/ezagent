defmodule EzagentDomainUi.Routing.RoutingView do
  @moduledoc """
  Session view: routing rules scoped to the current session.

  Per Allen V1 acceptance #2 (Feishu 2026-05-21) — `与 chat 并列的不应该是
  Terminal，而是 routing 规则`: this SessionView is a peer of Chat and
  `EzagentDomainUi.Pty.TerminalView` (Terminal). Tab order in the
  view-switcher remains Chat | Routing | Terminal.

  ## Session-scoped semantics

  Per SPEC v2 §5.4 — scope hierarchy is `global ⊂ workspace ⊂ session`.
  A routing rule is "session-scoped to S" when its matcher contains an
  `{:in_session, S}` leaf (directly or inside an `and/or/not`
  combinator). Global + workspace rules also fire for this session;
  they live on `/routing` (full editor).

  This view shows ONLY the session-scoped slice for the current session
  + a compact add-rule form. It does not duplicate `/routing` — that
  page remains the canonical surface for cross-scope rule management.

  ## Mutation path (SPEC v2 §5.7)

  - Add → dispatch to `<session_uri>?action=routing.add_rule` against
    the Session Kind's `Ezagent.ActionSet.Routing` (registered in
    `EzagentDomainInstanceMessage.Application`).
  - Toggle enable/disable → dispatch to the same target with
    `routing.disable_rule` / `routing.enable_rule`.

  Tier-2: the view itself is a stateless `Phoenix.Component` reading
  `@session_routing_rules` (computed by the host LiveView). Dispatch happens in
  the host LiveView per the 3-tier UI architecture.

  Registered by `EzagentDomainUi.Application.start/2`.
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-2 shared-component backend. NOT a
  # dependency on `ezagent_web` (see `EzagentDomainUi.Gettext` moduledoc).
  use Gettext, backend: EzagentDomainUi.Gettext
  use EzagentDomainUi.Primitives

  @impl true
  def id, do: :routing

  @impl true
  def label, do: gettext("Routing")

  @impl true
  def icon, do: "route"

  @impl true
  # Every session can have session-scoped routing rules — the tab is
  # always offered. (Empty state in render/1 covers the no-rules case.)
  def applies_to?(%URI{}), do: true
  def applies_to?(_), do: false

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:session_routing_rules, fn -> [] end)
      |> assign_new(:session_uri, fn -> nil end)
      # V1 UI PR-1 (SPEC §1.2 / §1.5) — uri_picker option lists,
      # computed by the host LV via `Ezagent.UI.UriOptions.*`. Default
      # to [] so a no-options dead-render still works.
      |> assign_new(:entity_options, fn -> [] end)
      |> assign_new(:receiver_options, fn -> [] end)

    ~H"""
    <div class="flex-1 overflow-auto p-4 bg-zinc-50 dark:bg-zinc-950 min-h-0">
      <div class="max-w-4xl mx-auto">
        <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100 mb-2">
          {gettext("Session Routing Rules")}
        </h2>
        <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-6">
          {gettext("Rules scoped to")}
          <code class="font-mono text-xs text-zinc-700 dark:text-zinc-300">
            {session_uri_string(@session_uri)}
          </code>
          {gettext(
            "via an in_session matcher. Global + workspace rules also fire for this session — see"
          )}
          <a href="/admin/routing" class="text-blue-600 dark:text-blue-400 hover:underline">
            /routing
          </a>
          {gettext("for all scopes.")}
        </p>

        <%!-- Session-scoped rule list --%>
        <div id="session-routing-rules" class="space-y-2 mb-6">
          <%= for rule <- @session_routing_rules do %>
            <div
              id={"session-routing-rule-#{rule.id}"}
              class={[
                "border border-zinc-200 dark:border-zinc-800 rounded p-3 bg-white dark:bg-zinc-900",
                not rule.enabled && "opacity-50"
              ]}
            >
              <div class="flex items-start justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <div class="text-xs font-mono text-zinc-500 dark:text-zinc-400 truncate">
                    {rule.matcher_repr}
                  </div>
                  <div class="text-sm text-zinc-900 dark:text-zinc-100 mt-1">
                    → <span class="font-mono text-xs">{rule.receivers_repr}</span>
                  </div>
                  <div :if={rule.source == "system_default"} class="mt-1">
                    <span class="inline-block px-1.5 py-0.5 text-[10px] rounded bg-blue-50 dark:bg-blue-950 text-blue-700 dark:text-blue-300">
                      system_default
                    </span>
                  </div>
                </div>
                <button
                  type="button"
                  phx-click="routing_rule_toggle"
                  phx-value-id={rule.id}
                  phx-value-enabled={to_string(rule.enabled)}
                  phx-value-table={rule.table_name}
                  class="px-2 py-1 text-xs border border-zinc-300 dark:border-zinc-700 rounded text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  {if rule.enabled, do: gettext("Disable"), else: gettext("Enable")}
                </button>
              </div>
            </div>
          <% end %>

          <div
            :if={@session_routing_rules == []}
            id="session-routing-rules-empty"
            class="text-center py-8 text-sm text-zinc-500 dark:text-zinc-400 border border-dashed border-zinc-300 dark:border-zinc-700 rounded"
          >
            {gettext("No session-scoped rules. Add one below, or see")}
            <a href="/admin/routing" class="text-blue-600 dark:text-blue-400 hover:underline">
              /routing
            </a>
            {gettext("for workspace/global rules.")}
          </div>
        </div>

        <%!-- Add rule form (compact; full form lives on /routing) --%>
        <details class="border border-zinc-200 dark:border-zinc-800 rounded p-3 bg-white dark:bg-zinc-900">
          <summary class="cursor-pointer text-sm font-medium text-zinc-700 dark:text-zinc-300">
            {gettext("+ Add session-scoped rule")}
          </summary>
          <form
            id="session-routing-add-form"
            phx-submit="routing_rule_add_session"
            class="mt-3 space-y-3"
          >
            <div>
              <label class="block text-xs text-zinc-600 dark:text-zinc-400 mb-1">
                {gettext("Matcher type")}
              </label>
              <select
                name="rule[matcher_type]"
                class="w-full px-3 py-2 rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-sm text-zinc-900 dark:text-zinc-100"
              >
                <option value="mention">mention</option>
                <option value="from">from</option>
                <option value="from_role">from_role</option>
                <option value="text_contains">text_contains</option>
                <option value="always">{gettext("always (any message in this session)")}</option>
              </select>
            </div>
            <div>
              <label class="block text-xs text-zinc-600 dark:text-zinc-400 mb-1">
                {gettext("Matcher arg")}
                <span class="text-zinc-400 dark:text-zinc-600">
                  {gettext("(ignored for \"always\"; substring/regex via manual entry)")}
                </span>
              </label>
              <%!--
                V1 UI PR-1 (SPEC §1.2) — :single uri_picker over
                in-workspace entities. allow_freetext ON so
                text_contains matchers (substring args) can be entered
                via the manual-entry disclosure.
              --%>
              <.uri_picker
                name="rule[matcher_arg]"
                mode={:single}
                kinds={[:entity]}
                options={@entity_options}
                allow_freetext={true}
                placeholder={gettext("pick an entity, or enter a substring below")}
              />
            </div>
            <div>
              <%!--
                V1 UI PR-1 (SPEC §1.2) — :multi uri_picker over
                in-workspace entities + sessions. Submits
                rule[receivers][] as a list.
              --%>
              <.uri_picker
                name="rule[receivers]"
                mode={:multi}
                kinds={[:entity, :session]}
                options={@receiver_options}
                allow_freetext={true}
                label={gettext("Receivers")}
                placeholder={gettext("add entities, sessions, or role:builder")}
              />
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-emerald-600 hover:bg-emerald-700 text-white text-sm font-medium rounded"
            >
              {gettext("Add rule")}
            </button>
          </form>
        </details>
      </div>
    </div>
    """
  end

  defp session_uri_string(nil), do: "(no session)"
  defp session_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp session_uri_string(s) when is_binary(s), do: s
  defp session_uri_string(_), do: "(unknown)"
end
