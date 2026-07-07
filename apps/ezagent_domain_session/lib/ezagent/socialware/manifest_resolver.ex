defmodule Ezagent.Socialware.ManifestResolver do
  @moduledoc """
  Resolves a config-authored socialware manifest into the runtime Definition shape.

  Authors name plugin-provided contributions (`uses`, view ids/render actions).
  Install/materialization consumes `%Ezagent.Socialware.Definition{}` with module
  references, so this is the explicit fail-closed boundary between the two.
  """

  alias Ezagent.Socialware.{Definition, ManifestViews}

  @doc "Resolve manifest name refs into a validated Definition."
  @spec resolve(map()) :: {:ok, Definition.t()} | {:error, term()}
  def resolve(attrs) when is_map(attrs) do
    with {:ok, uses} <- uses(attrs),
         :ok <- ensure_plugins_installed(uses),
         {:ok, views} <- resolve_views(attrs) do
      attrs
      |> put_value(:uses, uses)
      |> put_value(:views, views)
      |> Definition.new()
    end
  end

  def resolve(other), do: {:error, {:invalid_socialware_manifest, other}}

  defp uses(attrs) do
    case get(attrs, :uses, []) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          {:ok, list}
        else
          {:error, {:invalid_socialware_manifest_field, :uses, list}}
        end

      other ->
        {:error, {:invalid_socialware_manifest_field, :uses, other}}
    end
  end

  defp ensure_plugins_installed(uses) do
    missing = Enum.reject(uses, &plugin_installed?/1)
    if missing == [], do: :ok, else: {:error, {:missing_socialware_plugins, missing}}
  end

  defp plugin_installed?(slug) do
    not is_nil(Ezagent.PluginRegistry.info(slug)) or
      match?({:ok, _}, Ezagent.PluginPackage.InstalledRegistry.lookup(slug))
  end

  defp resolve_views(attrs) do
    case get(attrs, :views, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
          case resolve_view(ref) do
            {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, modules} -> {:ok, Enum.reverse(modules)}
          error -> error
        end

      other ->
        {:error, {:invalid_socialware_manifest_field, :views, other}}
    end
  end

  defp resolve_view(mod) when is_atom(mod), do: {:ok, mod}

  defp resolve_view(ref) when is_binary(ref) do
    with {:ok, registry} <- ManifestViews.session_view_registry() do
      apply(registry, :init, [])
    end

    view_modules()
    |> Enum.find_value(fn view_module ->
      behavior = backing_behavior(view_module)

      cond do
        is_nil(behavior) ->
          nil

        Atom.to_string(view_module.id()) == ref ->
          {:ok, behavior}

        Enum.any?(behavior.actions(), &(Atom.to_string(&1) == ref)) ->
          {:ok, behavior}

        true ->
          nil
      end
    end)
    |> case do
      {:ok, mod} -> {:ok, mod}
      nil -> {:error, {:unknown_socialware_view_ref, ref}}
    end
  end

  defp resolve_view(other), do: {:error, {:unknown_socialware_view_ref, other}}

  defp view_modules do
    with {:ok, registry} <- ManifestViews.session_view_registry(),
         table <- apply(registry, :table, []),
         true <- :ets.whereis(table) != :undefined do
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, module} -> module end)
    else
      _ -> []
    end
  end

  defp backing_behavior(view_module) do
    with {:ok, session_view} <- session_view_contract() do
      apply(session_view, :backing_behavior, [view_module])
    else
      _ ->
        if Code.ensure_loaded?(view_module) and function_exported?(view_module, :view_behavior, 0) do
          view_module.view_behavior()
        end
    end
  rescue
    _ -> nil
  end

  defp session_view_contract do
    module = Module.concat([Ezagent, UI, SessionView])

    if Code.ensure_loaded?(module) and function_exported?(module, :backing_behavior, 1) do
      {:ok, module}
    else
      :error
    end
  end

  defp put_value(map, key, value) do
    map
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end

  defp get(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
