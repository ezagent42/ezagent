defmodule EzagentPluginLiveview.ProfileLive do
  @moduledoc """
  Phase 8 polish (Allen 2026-05-20) — `/profile` for the current entity.

  Reached from the IDE Shell avatar dropdown. Shows the current entity's
  URI, caps count, API key count, and quick links to detail pages.

  Phase 8c PR-O (Username & Auth UI Task 2) — inline display-name
  editing for the logged-in entity. Pencil icon swaps the name into an
  input; submit upserts via `Ezagent.Entity.Profile.upsert/1`.
  """
  use Phoenix.LiveView
  # i18n V1 (Allen 2026-05-21) — see admin_dashboard_live for rationale.
  use Gettext, backend: EzagentWeb.Gettext
  alias EzagentDomainUi.IdeShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    entity_uri = socket.assigns.current_entity_uri || URI.parse("entity://user/system/admin")
    entity_uri_str = URI.to_string(entity_uri)

    {:ok,
     socket
     |> assign(:entity_uri, entity_uri)
     |> assign(:entity_uri_str, entity_uri_str)
     |> assign(:display_name, Ezagent.EntityPresenter.display(entity_uri_str))
     |> assign(:editing_display_name?, false)
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(:caps_count, count_caps(entity_uri))
     |> assign(:api_keys_count, count_api_keys(entity_uri))}
  end

  @impl true
  def handle_event("edit_display_name", _params, socket) do
    {:noreply, assign(socket, :editing_display_name?, true)}
  end

  def handle_event("cancel_edit_display_name", _params, socket) do
    {:noreply, assign(socket, :editing_display_name?, false)}
  end

  def handle_event("save_display_name", %{"display_name" => name}, socket) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:noreply, assign(socket, :flash_error, "Display name cannot be empty")}

      true ->
        case Ezagent.Entity.Profile.upsert(%{
               entity_uri: socket.assigns.entity_uri_str,
               display_name: name
             }) do
          {:ok, _profile} ->
            {:noreply,
             socket
             |> assign(:display_name, name)
             |> assign(:editing_display_name?, false)
             |> assign(:flash_info, "Display name updated.")
             |> assign(:flash_error, nil)}

          {:error, changeset} ->
            {:noreply, assign(socket, :flash_error, "update failed: #{inspect(changeset.errors)}")}
        end
    end
  end

  defp count_caps(uri) do
    try do
      uri |> Ezagent.Identity.list_caps_for() |> MapSet.size()
    catch
      _, _ -> 0
    end
  end

  defp count_api_keys(_uri) do
    # Best-effort; ApiKeys API hasn't been finalized for read-only count.
    # TODO Phase 9 — wire through Ezagent.ApiKeys.list_for/1.
    0
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :current_entity_uri_str, fn -> assigns.entity_uri_str end)

    ~H"""
    <IdeShell.ide_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/profile"
      status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
    >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 max-w-3xl">
          <.page_header title={gettext("Profile")}>
            <:subtitle>Your entity URI and access summary.</:subtitle>
          </.page_header>

          <.card class="mt-4">
            <div class="flex items-center gap-4">
              <.avatar uri={@entity_uri_str} size="md" />
              <div class="flex-1">
                <div class="text-xs text-zinc-500">Display name</div>
                <%= if @editing_display_name? do %>
                  <form phx-submit="save_display_name" phx-click-away="cancel_edit_display_name" class="flex gap-1 items-center mt-0.5">
                    <input
                      type="text"
                      name="display_name"
                      value={@display_name}
                      autofocus
                      phx-key="escape"
                      phx-keydown="cancel_edit_display_name"
                      class="flex-1 px-2 py-1 text-sm border border-blue-400 dark:border-blue-600 rounded bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    />
                    <button type="submit" class="p-1 text-emerald-600 hover:text-emerald-700 dark:text-emerald-400" aria-label="Save">
                      <.icon name="check" size="sm" />
                    </button>
                    <button type="button" phx-click="cancel_edit_display_name" class="p-1 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300" aria-label="Cancel">
                      <.icon name="x" size="sm" />
                    </button>
                  </form>
                <% else %>
                  <div class="flex items-center gap-1">
                    <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100">{@display_name}</span>
                    <button
                      type="button"
                      phx-click="edit_display_name"
                      aria-label="Edit display name"
                      class="p-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 rounded"
                    >
                      <.icon name="pencil" size="xs" />
                    </button>
                  </div>
                <% end %>
                <div class="mt-2 text-xs text-zinc-500">Entity URI</div>
                <.uri_chip uri={@entity_uri_str} />
                <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mt-2">{@flash_error}</p>
                <p :if={@flash_info} class="text-emerald-600 dark:text-emerald-400 text-xs mt-2">{@flash_info}</p>
              </div>
            </div>
          </.card>

          <div class="grid grid-cols-2 gap-3 mt-4">
            <a href={"/identities/users/" <> URI.encode_www_form(@entity_uri_str) <> "/caps"} class="block">
              <.card>
                <div class="font-medium text-sm">Capabilities</div>
                <div class="text-2xl font-mono mt-1">{@caps_count}</div>
                <div class="text-xs text-zinc-500 mt-1">→ Manage</div>
              </.card>
            </a>
            <a href={"/identities/users/" <> URI.encode_www_form(@entity_uri_str) <> "/api-keys"} class="block">
              <.card>
                <div class="font-medium text-sm">API Keys</div>
                <div class="text-2xl font-mono mt-1">{@api_keys_count}</div>
                <div class="text-xs text-zinc-500 mt-1">→ Manage</div>
              </.card>
            </a>
          </div>

          <div class="mt-6 text-right">
            <form action="/logout" method="post">
              <.button variant="ghost" type="submit">Sign out</.button>
            </form>
          </div>
        </div>
      </:main_window>

      <%!-- V1 UI PR-2b (SPEC §2.5) — CmdK command palette. The
            header search bar + ⌘K are global ide_shell chrome, so
            every ide_shell LV must render the palette (PR-2 wired it
            into admin_live only). Shared LiveComponent; `nav_routes`
            flows DOWN from `EzagentWeb.LiveAuth` `:cmdk_nav`. --%>
      <:command_palette>
        <.live_component
          module={EzagentPluginLiveview.CommandPaletteComponent}
          id="cmdk"
          nav_routes={@cmdk_nav_routes}
          current_entity_uri={@current_entity_uri}
          current_workspace_uri={@current_workspace_uri}
        />
      </:command_palette>
    </IdeShell.ide_shell>
    """
  end
end
