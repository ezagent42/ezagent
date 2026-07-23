defmodule Ezagent.World.RefreshSurfaceRegistry do
  @moduledoc """
  Dynamic, fail-closed registry for UI surfaces that can refresh after a
  `SliceChange`.

  A plugin page contributes one surface automatically from its validated page
  declaration. Non-page world surfaces are declared through the same
  `refresh_surfaces/0` plugin callback. World only knows the declaration shape.
  """

  @type surface :: %{
          id: String.t(),
          component: String.t(),
          target: {:route, atom()} | {:assign, atom()},
          state_builder: module(),
          provider: module()
        }

  @spec all() :: [surface()]
  def all, do: page_surfaces() ++ declared_surfaces()

  @spec by_component(String.t() | term()) :: surface() | nil
  def by_component(component) when is_binary(component) do
    Enum.find(all(), &(&1.component == component))
  end

  def by_component(_), do: nil

  @spec target_uri(surface(), Phoenix.LiveView.Socket.t()) :: URI.t() | nil
  def target_uri(%{target: {:route, key}}, socket) do
    case socket.assigns[:current_route] do
      %{^key => %URI{} = uri} -> uri
      _ -> nil
    end
  end

  def target_uri(%{target: {:assign, key}}, socket) do
    case socket.assigns[key] do
      %URI{} = uri -> uri
      _ -> nil
    end
  end

  @spec build_state(surface(), URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def build_state(%{state_builder: builder}, %URI{} = uri, ctx) when is_map(ctx) do
    case builder.refresh_state(uri, ctx) do
      state when is_map(state) -> {:ok, state}
      other -> {:error, {:invalid_refresh_state, other}}
    end
  rescue
    error -> {:error, {:refresh_failed, Exception.message(error)}}
  end

  defp page_surfaces do
    Ezagent.World.PluginPageRegistry.pages()
    |> Enum.map(fn page ->
      %{
        id: page.key,
        component: page.key,
        target: {:route, :entity_uri},
        state_builder: page.data_builder,
        provider: page.provider
      }
    end)
  end

  defp declared_surfaces do
    Ezagent.PluginRegistry.list_all()
    |> Enum.sort_by(fn plugin -> plugin.plugin_info().slug end)
    |> Enum.filter(&function_exported?(&1, :refresh_surfaces, 0))
    |> Enum.flat_map(fn plugin ->
      try do
        case plugin.refresh_surfaces() do
          surfaces when is_list(surfaces) ->
            Enum.flat_map(surfaces, fn surface ->
              if Ezagent.World.UiSurfaceProvider.valid_refresh_surface?(surface) do
                [Map.put(surface, :provider, plugin)]
              else
                []
              end
            end)

          _ ->
            []
        end
      rescue
        _ -> []
      end
    end)
  end
end
