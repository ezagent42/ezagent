defmodule EzagentPluginLiveview.PluginsLive do
  @moduledoc """
  Phase 8 polish (Allen 2026-05-20) — `/plugins` cards view.

  Replaces the previous Activity Bar shortcut to `/admin/feishu/bindings`.
  Lists every loaded `ezagent_plugin_*` OTP app as a card with name,
  description, status badge, and primary action links.

  Data source: `Application.loaded_applications()` filtered by name
  prefix — no separate PluginRegistry is needed for v1.
  """
  use Phoenix.LiveView
  alias EzagentDomainUi.IdeShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :plugins, list_plugins())}
  end

  defp list_plugins do
    Application.loaded_applications()
    |> Enum.filter(fn {name, _desc, _vsn} ->
      String.starts_with?(Atom.to_string(name), "ezagent_plugin_")
    end)
    |> Enum.map(fn {name, desc, vsn} ->
      slug = Atom.to_string(name) |> String.replace_prefix("ezagent_plugin_", "")
      %{
        slug: slug,
        name: pretty_name(slug),
        description: pretty_desc(slug, desc),
        version: to_string(vsn),
        link: primary_link(slug)
      }
    end)
    |> Enum.sort_by(& &1.slug)
  end

  defp pretty_name("cc"), do: "Claude Code"
  defp pretty_name("curl_agent"), do: "Curl Agent"
  defp pretty_name("echo"), do: "Echo"
  defp pretty_name("feishu"), do: "Feishu (Lark)"
  defp pretty_name("liveview"), do: "Admin Web UI"
  defp pretty_name(other), do: other

  defp pretty_desc("cc", _), do: "Spawn Claude Code agents via PTY or remote channel"
  defp pretty_desc("curl_agent", _), do: "HTTP-API agents (DeepSeek / OpenAI / etc.)"
  defp pretty_desc("echo", _), do: "Test stub — echoes back messages"
  defp pretty_desc("feishu", _), do: "Lark integration (inbound webhook + outbound bot)"
  defp pretty_desc("liveview", _), do: "The web admin UI you're currently using"
  defp pretty_desc(_, desc) when is_list(desc), do: List.to_string(desc)
  defp pretty_desc(_, _), do: ""

  defp primary_link("feishu"), do: {"Bindings", "/plugins/feishu/bindings"}
  defp primary_link("cc"), do: {"Agents", "/identities?filter=agent"}
  defp primary_link("curl_agent"), do: {"Agents", "/identities?filter=agent"}
  defp primary_link("echo"), do: {"Agents", "/identities?filter=agent"}
  defp primary_link("liveview"), do: nil
  defp primary_link(_), do: nil

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <IdeShell.ide_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/plugins"
      status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
    >
      <:resource_panel>
        <div class="p-3">
          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-2">Plugins</div>
          <a
            :for={p <- @plugins}
            href={"#plugin-#{p.slug}"}
            class="block px-2 py-1 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 rounded font-mono text-zinc-700 dark:text-zinc-300"
          >
            {p.name}
          </a>
        </div>
      </:resource_panel>
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6">
          <.page_header title="Plugins">
            <:subtitle>Installed ezagent plugins. Each one extends a core capability.</:subtitle>
          </.page_header>
          <div class="grid grid-cols-2 gap-4 mt-4">
            <a
              :for={p <- @plugins}
              id={"plugin-#{p.slug}"}
              href={(p.link && elem(p.link, 1)) || "#"}
              class="block"
            >
              <.card>
                <div class="flex items-start justify-between">
                  <div>
                    <div class="font-medium text-sm">{p.name}</div>
                    <div class="text-[11px] text-zinc-400 dark:text-zinc-600 font-mono mt-0.5">v{p.version}</div>
                  </div>
                  <.badge variant="success">active</.badge>
                </div>
                <div class="text-xs text-zinc-500 mt-2">{p.description}</div>
                <div :if={p.link} class="mt-3 text-xs text-blue-600 dark:text-blue-400">
                  → {elem(p.link, 0)}
                </div>
              </.card>
            </a>
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
