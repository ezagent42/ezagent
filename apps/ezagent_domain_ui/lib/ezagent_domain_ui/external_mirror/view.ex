defmodule EzagentDomainUi.ExternalMirror.View do
  @moduledoc """
  Session view: ExternalMirror bindings scoped to the current session.

  Per Allen 2026-05-25 — the `/sessions` view-switcher gains an
  **ExternalMirror Bindings** tab as a peer of Chat / Routing /
  Terminal. The tab shows the bindings registered for the current
  session (Lark chats, future Slack/Discord/game-room targets) with a
  link to the routing bindings page for the full bind / unbind /
  audit-drilldown surface. The full ExternalMirror Domain SPEC lives
  at `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`.

  This view is read-only — mutation goes through the routing bindings page. The
  compactness is deliberate: the operator-flow is "click into a session, glance
  at its bindings, navigate to the admin surface if more is needed."

  ## Source-of-truth read

  Reads via `Ezagent.ExternalMirror.list_bindings/2` so dispatch
  CapBAC step 5.5 enforces Cap 1 (session-level `:list_bindings`). A
  viewer without Cap 1 sees the "no bindings or insufficient cap"
  empty state — the tab itself stays clickable (UX preference) but
  the row table is empty. This matches the admin LV's failure mode.

  Tier-2: stateless `Phoenix.Component` reading `@session_bindings` computed by
  the host LiveView. Dispatch happens in the host LiveView per the 3-tier UI
  architecture.

  Registered by `EzagentDomainUi.Application.start/2`.
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-2 shared-component backend.
  use Gettext, backend: EzagentDomainUi.Gettext
  use EzagentDomainUi.Primitives

  @impl true
  def id, do: :external_mirror

  @impl true
  def label, do: gettext("Bindings")

  @impl true
  def icon, do: "link"

  @impl true
  # Every session can have ExternalMirror bindings (subject to adapter
  # availability + caller's caps). Always show the tab; the empty
  # state renders if no bindings or the caller lacks Cap 1.
  def applies_to?(%URI{}), do: true
  def applies_to?(_), do: false

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:session_bindings, fn -> [] end)
      |> assign_new(:session_uri, fn -> nil end)

    ~H"""
    <div class="flex-1 overflow-auto p-4 bg-zinc-50 dark:bg-zinc-950 min-h-0">
      <div class="max-w-4xl mx-auto">
        <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100 mb-2">
          {gettext("ExternalMirror Bindings")}
        </h2>
        <p class="text-sm text-zinc-600 dark:text-zinc-400 mb-6">
          {gettext("Bindings for")}
          <code class="font-mono text-xs text-zinc-700 dark:text-zinc-300">
            {session_uri_string(@session_uri)}
          </code>
          {gettext(". Full bind / unbind + audit drilldown lives on")}
          <.link
            navigate="/admin/routing?tab=bindings"
            class="text-blue-600 dark:text-blue-400 hover:underline"
          >
            {gettext("routing bindings")}
          </.link>
          {gettext(".")}
        </p>

        <%!-- Bindings list (read-only in this view) --%>
        <div id="session-bindings" class="space-y-2 mb-6">
          <%= for b <- @session_bindings do %>
            <div
              id={"session-binding-#{binding_id(b)}"}
              class="border border-zinc-200 dark:border-zinc-800 rounded p-3 bg-white dark:bg-zinc-900"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <div class="text-xs font-mono text-zinc-700 dark:text-zinc-300">
                    <span class="text-zinc-500">{gettext("adapter:")}</span>
                    <strong>{Map.get(b, :adapter_id, "?")}</strong>
                  </div>
                  <div class="text-xs font-mono text-zinc-700 dark:text-zinc-300 mt-1 break-all">
                    <span class="text-zinc-500">{gettext("target:")}</span>
                    {Map.get(b, :target_id, "?")}
                  </div>
                  <div :if={Map.get(b, :bound_by)} class="text-[11px] font-mono text-zinc-500 mt-1">
                    {gettext("bound by")} {b.bound_by}
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <div
            :if={@session_bindings == []}
            id="session-bindings-empty"
            class="text-center py-8 text-sm text-zinc-500 dark:text-zinc-400 border border-dashed border-zinc-300 dark:border-zinc-700 rounded"
          >
            {gettext("No bindings — bind a Lark chat / Slack channel / external target via")}
            <.link
              :if={@session_uri}
              navigate={
                "/admin/sessions/" <>
                  URI.encode_www_form(session_uri_string(@session_uri)) <>
                  "/external_mirror"
              }
              class="text-blue-600 dark:text-blue-400 hover:underline"
            >
              {gettext("the admin LV")}
            </.link>
            {gettext(".")}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp session_uri_string(nil), do: "(no session)"
  defp session_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp session_uri_string(s) when is_binary(s), do: s
  defp session_uri_string(_), do: "(unknown)"

  defp binding_id(%{adapter_id: a, target_id: t}), do: "#{a}-#{t}"
  defp binding_id(_), do: "unknown"
end
