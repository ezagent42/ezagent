defmodule EzagentPluginWorld.WorldLive do
  @moduledoc """
  LiveView SSR/comms shell for the React-owned `world` app.
  """

  use Phoenix.LiveView

  alias EzagentPluginWorld.Layouts

  @impl true
  def mount(_params, _session, socket) do
    caller = Map.get(socket.assigns, :current_entity_uri)
    workspace = Map.get(socket.assigns, :current_workspace_uri)

    caller_payload = %{
      "entity_uri" => encode_uri(caller),
      "workspace_uri" => encode_uri(workspace)
    }

    {:ok,
     socket
     |> assign(:layout_json, Jason.encode!(default_layout()))
     |> assign(:caller_json, Jason.encode!(caller_payload))
     |> assign(:world_module_url, world_module_url())
     |> assign(:world_css_url, world_css_url())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="world-shell" class="min-h-screen">
        <div
          id="world-root"
          phx-hook="WorldRenderer"
          phx-update="ignore"
          data-layout={@layout_json}
          data-caller={@caller_json}
          data-world-module-url={@world_module_url}
          data-world-css-url={@world_css_url}
          class="min-h-screen"
        >
          <div class="flex min-h-screen items-center justify-center bg-[#f8fafc] px-6">
            <div class="h-10 w-10 rounded-full border border-[#d1d5db] border-t-[#111827] motion-safe:animate-spin">
            </div>
          </div>
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp world_module_url do
    Application.get_env(:ezagent_plugin_world, :world_module_url, "/assets/world/main.js")
  end

  defp world_css_url do
    Application.get_env(:ezagent_plugin_world, :world_css_url, "/assets/world/world.css")
  end

  defp default_layout do
    system_workspace = Ezagent.URI.workspace(:system) |> URI.to_string()

    %{
      "version" => 1,
      "scope" => system_workspace,
      "components" => [
        %{
          "id" => "world-hello",
          "type" => "world_hello",
          "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 6},
          "props" => %{"title" => "World"}
        }
      ]
    }
  end

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
