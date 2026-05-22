defmodule EzagentPluginLiveview.WorkspacesLive do
  @moduledoc """
  /workspaces — list every persisted Workspace + form to create.

  Reads `Ezagent.Workspace.list_persisted/0` (which hits SQLite via
  `Ezagent.Workspace.Store`) — the persisted set, not the live-Kind set.
  Phase 4d separates "what's declared to exist" (Store) from "what's
  currently spawned" (KindRegistry); a healthy system has them equal,
  but during transient errors the Store row exists even when the live
  Kind crashed.

  ## PR-M (Allen 2026-05-20) — admin drawer surface

  Workspace management (templates / members / routing config) is a
  configuration surface, not a workflow surface. Renders inside the
  admin perspective (left sidebar, no Activity Bar, no Status Bar) per
  the "no two header types" UX rule. Reachable from:

  - avatar dropdown → "Admin" → sidebar → "Workspaces"
  - workspace top-left dropdown (on any workspace surface) → "Manage
    workspaces..." link → /workspaces (opens the same drawer)

  ## Nested-shell PR-3 (SPEC §1, §6 row 3)

  Now renders `AppShell.app_shell` (`perspective: :admin`) wrapping
  `AdminShell.admin_shell` — the page gains the universal chrome
  (avatar / notifications / search / ⌘K).
  """

  use Phoenix.LiveView
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:workspaces, list_workspaces())
     |> assign(:flash_error, nil)
     |> assign(:new_form, to_form(%{"name" => ""}, as: "new_workspace"))}
  end

  defp list_workspaces do
    Ezagent.Workspace.list_persisted()
    |> Enum.map(fn ws ->
      live_pid =
        case Ezagent.KindRegistry.lookup(ws.uri) do
          {:ok, pid} -> pid
          :error -> nil
        end

      Map.put(ws, :live_pid, live_pid)
    end)
  end

  @impl true
  def handle_event("create_workspace", %{"new_workspace" => %{"name" => name}}, socket)
      when is_binary(name) and name != "" do
    case Ezagent.Workspace.create(String.trim(name), %{}) do
      {:ok, _pid} ->
        {:noreply,
         socket
         |> assign(:workspaces, list_workspaces())
         |> assign(:new_form, to_form(%{"name" => ""}, as: "new_workspace"))
         |> assign(:flash_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, "create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create_workspace", _params, socket) do
    {:noreply, assign(socket, :flash_error, "Workspace name is required.")}
  end

  @impl true
  def render(assigns) do
    # Nested-shell PR-3 — render inside AppShell.app_shell (perspective
    # :admin) over AdminShell.admin_shell. No Activity Bar, no Status
    # Bar — the "no two header types" rule. The page now gains the
    # universal chrome (avatar / notifications / search / ⌘K).
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspaces={@workspaces}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <AdminShell.admin_shell current_path="/workspaces" active_section={:workspaces}>
          <:main>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title="Workspaces">
            <:subtitle>
              Persisted cluster configurations — members + session templates + routing rules.
            </:subtitle>
          </.page_header>

          <.card id="create-workspace" class="mb-6">
            <:header>+ New Workspace</:header>
            <.form for={@new_form} phx-submit="create_workspace" class="flex gap-2 items-center">
              <input
                type="text"
                name="new_workspace[name]"
                id="new_workspace_name"
                placeholder="architect-review"
                class="flex-1 px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-zinc-500"
              />
              <.button type="submit" variant="primary" size="sm">Create</.button>
            </.form>
            <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mt-2">{@flash_error}</p>
          </.card>

          <section id="workspaces-list">
            <p :if={@workspaces == []} id="empty" class="text-zinc-500 italic text-sm">
              No workspaces yet. Use the form above to create the first one.
            </p>

            <.card :if={@workspaces != []} class="p-0">
              <table id="workspaces-table" class="w-full text-sm">
                <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
                  <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
                    <th class="px-4 py-2">Name</th>
                    <th class="py-2">URI</th>
                    <th class="py-2">Members</th>
                    <th class="py-2">Templates</th>
                    <th class="py-2">Rules</th>
                    <th class="py-2">Live</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={ws <- @workspaces} class="border-b border-zinc-100 dark:border-zinc-900 last:border-0">
                    <td class="px-4 py-2 font-medium">{ws.name}</td>
                    <td class="py-2 font-mono text-xs text-zinc-500">{URI.to_string(ws.uri)}</td>
                    <td class="py-2 tabular-nums">{length(ws.members)}</td>
                    <td class="py-2 tabular-nums">{map_size(ws.session_templates)}</td>
                    <td class="py-2 tabular-nums">{length(ws.routing_rules)}</td>
                    <td class="py-2">
                      <.badge :if={ws.live_pid} variant="success">live</.badge>
                      <.badge :if={!ws.live_pid} variant="danger">down</.badge>
                    </td>
                    <td class="py-2 pr-4 text-right">
                      <a
                        href={"/workspaces/#{ws.name}"}
                        class="text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-xs"
                      >detail →</a>
                    </td>
                  </tr>
                </tbody>
              </table>
            </.card>
          </section>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
