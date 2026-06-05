defmodule EzagentPluginLiveview.AdminCapsLive do
  @moduledoc """
  `/admin/caps` — cap subject + default grant discovery surface.

  Renders every entry from `Ezagent.CapabilityRegistry.list_grantable/0`
  + `default_grants_for/2` for each Kind with a registered default-grant
  fn. The first surface for "what caps can be granted in this running
  system, and what does a fresh entity get out of the box" — closes
  Allen's "我想知道现在有哪些 caps 可以注册和被 grant" gap.

  Per SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md`
  §8.1.

  ## Admin gate

  Mirrors `EzagentPluginLiveview.SettingsLive`'s mount-time
  `@is_admin?` redirect — the existing `/admin/*` `live_session` only
  authenticates the entity; admin-scope is enforced per-LV. A broader
  shared admin gate via `live_session` is filed as separate future
  cleanup (see SPEC §8.1).

  ## Tier + layering

  Tier 3 (plugin LV). Reads `Ezagent.CapabilityRegistry` (Tier 1
  primitive) directly; uses `:application.get_application/1` to
  surface which OTP app each Behavior was registered from (not
  `__info__(:application)` — that field does not exist on Elixir
  modules; rev-4 codex round-3 MEDIUM fix).
  """

  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.CapabilityRegistry

  @impl true
  def mount(_params, _session, socket) do
    if Map.get(socket.assigns, :is_admin?) do
      {:ok,
       socket
       |> assign(:subjects, list_subjects())
       |> assign(:default_grants, list_default_grants_table(socket))
       |> assign(:filter, "")
       |> assign(:expanded, MapSet.new())}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Admin Caps is restricted to admin entities."))
       |> push_navigate(to: "/sessions")}
    end
  end

  @impl true
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, :filter, q)}
  end

  def handle_event("toggle_expand", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    new_expanded =
      if MapSet.member?(expanded, key) do
        MapSet.delete(expanded, key)
      else
        MapSet.put(expanded, key)
      end

    {:noreply, assign(socket, :expanded, new_expanded)}
  end

  # ----- View helpers --------------------------------------------------------

  defp list_subjects do
    CapabilityRegistry.list_grantable()
    |> Enum.map(&decorate/1)
  end

  defp decorate(%{kind: kind, behavior: behavior, action: action} = subject) do
    Map.merge(subject, %{
      key: "#{inspect(kind)}|#{inspect(behavior)}|#{action}",
      kind_display: inspect(kind),
      behavior_display: inspect(behavior),
      otp_application: otp_application(behavior)
    })
  end

  defp otp_application(behavior) do
    # Codex round-3 MEDIUM fix — Elixir modules don't have
    # `__info__(:application)`. Use OTP's :application API.
    case :application.get_application(behavior) do
      {:ok, app} -> Atom.to_string(app)
      :undefined -> "(unknown)"
    end
  end

  defp list_default_grants_table(socket) do
    workspace_uri = current_workspace_uri(socket)

    # Iterate every Kind registered for default grants. The registry
    # exposes `kinds_with_default_grants/0` so the LV doesn't reach
    # into internal ETS state.
    CapabilityRegistry.kinds_with_default_grants()
    |> Enum.map(fn kind ->
      caps = CapabilityRegistry.default_grants_for(kind, workspace_uri)
      %{kind: kind, kind_display: inspect(kind), caps: caps}
    end)
    |> Enum.sort_by(& &1.kind_display)
  end

  defp current_workspace_uri(socket) do
    # SPEC #324: no silent global fallback. LV must always be mounted
    # with `:current_workspace_uri` (set by `EzagentWeb.LiveAuth`
    # on_mount(:require_entity) per Phase 9 PR-5). A missing assign
    # here is a mount-discipline bug — fail-fast so the operator sees
    # the structural error instead of silently landing in `system`.
    case Map.get(socket.assigns, :current_workspace_uri) do
      %URI{} = uri ->
        uri

      _ ->
        raise ArgumentError,
              "EzagentPluginLiveview.AdminCapsLive: socket.assigns[:current_workspace_uri] " <>
                "is required (set by EzagentWeb.LiveAuth.on_mount(:require_entity) " <>
                "per Phase 9 PR-5). Got nil — this LV mounted outside the " <>
                ":require_entity live_session."
    end
  end

  defp filter_subjects(subjects, "") do
    subjects
  end

  defp filter_subjects(subjects, q) do
    q = String.downcase(q)

    Enum.filter(subjects, fn s ->
      String.contains?(String.downcase(s.kind_display), q) or
        String.contains?(String.downcase(s.behavior_display), q) or
        String.contains?(String.downcase(Atom.to_string(s.action)), q) or
        String.contains?(String.downcase(s.description), q)
    end)
  end

  defp dispatchable_badge(true), do: "dispatchable"
  defp dispatchable_badge(false), do: "cap-only"

  defp cap_to_pretty(%Ezagent.Capability{} = cap) do
    Ezagent.Capability.to_map(cap)
    |> Jason.encode!(pretty: true)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible_subjects, filter_subjects(assigns.subjects, assigns.filter))

    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        Ezagent.URI.stable_key(
          Map.get(assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()
        )
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={Map.get(assigns, :current_workspace_uri)}
      workspaces={Map.get(assigns, :workspaces, [])}
      workspace_name={Map.get(assigns, :workspace_name)}
      is_admin?={Map.get(assigns, :is_admin?, false)}
      is_system_member?={Map.get(assigns, :is_system_member?, false)}
      cmdk_nav_routes={Map.get(assigns, :cmdk_nav_routes, [])}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/caps" active_section={:caps}>
          <:main>
            <div class="px-6 py-6 max-w-7xl mx-auto">
              <header class="mb-6">
                <h1 class="text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-100">
                  {gettext("Capability subjects")}
                </h1>
                <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
                  {gettext(
                    "Every cap subject registered via Ezagent.CapabilityRegistry. Includes dispatchable (BehaviorRegistry-wired) and cap-only (Presence-style) subjects."
                  )}
                </p>
              </header>

              <%!-- Default grants section --%>
              <section class="mb-8">
                <h2 class="text-sm font-medium uppercase tracking-wide text-zinc-700 dark:text-zinc-300 mb-3">
                  {gettext("Default grants")}
                </h2>
                <p class="text-xs text-zinc-500 mb-3">
                  {gettext("Caps a fresh entity of each Kind receives at spawn, scoped to:")}
                  <code class="font-mono">{URI.to_string(@current_workspace_uri)}</code>
                </p>

                <div :if={@default_grants == []} class="text-xs italic text-zinc-500">
                  {gettext("No default-grant policies registered.")}
                </div>

                <div
                  :for={dg <- @default_grants}
                  class="mb-4 border border-zinc-200 dark:border-zinc-800 rounded-md p-4"
                >
                  <h3 class="text-sm font-medium font-mono text-zinc-800 dark:text-zinc-200 mb-2">
                    {dg.kind_display}
                    <span class="ml-2 inline-block px-1.5 py-0.5 text-[10px] font-mono bg-zinc-100 dark:bg-zinc-800 rounded">
                      {length(dg.caps)} cap{if length(dg.caps) != 1, do: "s"}
                    </span>
                  </h3>
                  <pre
                    :if={dg.caps != []}
                    class="text-[11px] font-mono bg-zinc-50 dark:bg-zinc-900 p-2 rounded overflow-x-auto"
                  ><%= for cap <- dg.caps do %><%= cap_to_pretty(cap) %>

    <% end %></pre>
                  <div :if={dg.caps == []} class="text-xs italic text-zinc-500">
                    {gettext("(grant fn returns empty list for this workspace)")}
                  </div>
                </div>
              </section>

              <%!-- Subjects table --%>
              <section>
                <div class="flex items-center justify-between mb-3">
                  <h2 class="text-sm font-medium uppercase tracking-wide text-zinc-700 dark:text-zinc-300">
                    {gettext("Grantable subjects")}
                    <span class="ml-2 inline-block px-1.5 py-0.5 text-[10px] font-mono bg-zinc-100 dark:bg-zinc-800 rounded">
                      {length(@visible_subjects)} / {length(@subjects)}
                    </span>
                  </h2>
                  <form phx-change="filter">
                    <input
                      type="text"
                      name="q"
                      value={@filter}
                      placeholder={gettext("Filter…")}
                      class="text-xs font-mono px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900"
                    />
                  </form>
                </div>

                <table class="w-full text-sm border-collapse">
                  <thead>
                    <tr class="border-b border-zinc-300 dark:border-zinc-700 text-left text-xs uppercase tracking-wider text-zinc-500">
                      <th class="py-2 px-2 font-medium">Kind</th>
                      <th class="py-2 px-2 font-medium">Behavior</th>
                      <th class="py-2 px-2 font-medium">Action</th>
                      <th class="py-2 px-2 font-medium">Description</th>
                      <th class="py-2 px-2 font-medium">Mode</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for s <- @visible_subjects do %>
                      <tr
                        class="border-b border-zinc-100 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-900 cursor-pointer"
                        phx-click="toggle_expand"
                        phx-value-key={s.key}
                      >
                        <td class="py-2 px-2 font-mono text-xs">{s.kind_display}</td>
                        <td class="py-2 px-2 font-mono text-xs">{s.behavior_display}</td>
                        <td class="py-2 px-2 font-mono text-xs">:{s.action}</td>
                        <td class="py-2 px-2 text-xs text-zinc-600 dark:text-zinc-400">
                          {s.description}
                        </td>
                        <td class="py-2 px-2">
                          <span class={[
                            "inline-block px-1.5 py-0.5 text-[10px] font-mono rounded",
                            s.dispatchable? &&
                              "bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200",
                            !s.dispatchable? &&
                              "bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200"
                          ]}>
                            {dispatchable_badge(s.dispatchable?)}
                          </span>
                        </td>
                      </tr>
                      <tr :if={MapSet.member?(@expanded, s.key)}>
                        <td
                          colspan="5"
                          class="bg-zinc-50 dark:bg-zinc-900 px-4 py-3 text-xs font-mono"
                        >
                          <div class="text-zinc-500 mb-1">
                            {gettext("Registered from OTP app:")}
                            <span class="text-zinc-700 dark:text-zinc-300">{s.otp_application}</span>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>

                <div
                  :if={@visible_subjects == []}
                  class="text-sm italic text-zinc-500 text-center py-8"
                >
                  {gettext("No subjects match the filter.")}
                </div>
              </section>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
