defmodule Ezagent.World.CommandPaletteActions do
  @moduledoc """
  Socket-side command palette dispatch handlers for world.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_patch: 2]

  alias Ezagent.World.CommandPaletteData

  @doc "Route a command palette action to its handler."
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "cmdk.open", _args), do: put_cmdk(socket, "", true, "ok")
  def handle_dispatch(socket, "cmdk.close", _args), do: put_cmdk(socket, "", false, "ok")

  def handle_dispatch(socket, "cmdk.query", %{"query" => query}) when is_binary(query) do
    put_cmdk(socket, query, true, "ok")
  end

  def handle_dispatch(socket, "cmdk.select", %{"key" => key}) when is_binary(key) do
    case CommandPaletteData.find(socket.assigns, key) do
      %{target: target} when is_binary(target) and target != "" ->
        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_patch(to: target)}

      _ ->
        {:noreply, assign(socket, :last_dispatch_status, "error:unknown_command")}
    end
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  defp put_cmdk(socket, query, open?, status) do
    cmdk = CommandPaletteData.state(socket.assigns, query, open?)
    state = Map.put(socket.assigns.world_state, "cmdk", cmdk)

    {:noreply,
     socket
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, status)
     |> push_event("world:state", %{"cmdk" => cmdk})}
  end
end
