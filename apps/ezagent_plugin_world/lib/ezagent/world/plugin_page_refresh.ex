defmodule Ezagent.World.PluginPageRefresh do
  @moduledoc """
  Validates and invokes the plugin-owned partial-state callback used by World
  real-time refresh events.

  A registered page must provide a `data_builder.refresh_state/2` function.
  The function receives the changed entity URI and the caller-scoped read
  context, and must return the JSON-safe partial state to merge into the React
  World state.
  """

  @type result :: {:ok, map()} | :not_registered | {:error, atom()}

  @doc "Builds refresh state from the changed entity carried by SliceChange."
  @spec build_state_for_slice_change(map() | nil, map(), map()) :: result()
  def build_state_for_slice_change(page, %{uri: %URI{} = entity_uri}, ctx),
    do: build_state(page, entity_uri, ctx)

  def build_state_for_slice_change(_page, _event, _ctx), do: {:error, :invalid_slice_change}

  @doc "Builds refresh state through a registered page's validated data builder."
  @spec build_state(map() | nil, URI.t(), map()) :: result()
  def build_state(nil, _entity_uri, _ctx), do: :not_registered

  def build_state(%{data_builder: data_builder}, %URI{} = entity_uri, ctx)
      when is_atom(data_builder) and is_map(ctx) do
    with {:module, ^data_builder} <- Code.ensure_loaded(data_builder),
         true <- function_exported?(data_builder, :refresh_state, 2),
         state when is_map(state) <- data_builder.refresh_state(entity_uri, ctx) do
      {:ok, state}
    else
      false -> {:error, :missing_refresh_state}
      {:module, _other} -> {:error, :invalid_data_builder}
      _ -> {:error, :invalid_refresh_state}
    end
  end

  def build_state(_page, _entity_uri, _ctx), do: {:error, :invalid_refresh_declaration}
end
