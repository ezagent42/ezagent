defmodule Ezagent.World.CommandPaletteData do
  @moduledoc """
  Command palette candidates and search state for the world React shell.
  """

  @doc "Build command palette state from socket-like assigns."
  @spec state(map(), String.t(), boolean()) :: map()
  def state(assigns, query \\ "", open? \\ false) when is_map(assigns) and is_binary(query) do
    candidates = candidates(assigns)

    %{
      "open" => open?,
      "query" => query,
      "results" => search(query, candidates)
    }
  end

  @doc "Find a command by key from socket-like assigns."
  @spec find(map(), String.t()) :: map() | nil
  def find(assigns, key) when is_map(assigns) and is_binary(key) do
    Enum.find(candidates(assigns), &(Map.get(&1, :key) == key))
  end

  def find(_assigns, _key), do: nil

  defp candidates(assigns) do
    nav_results(Map.get(assigns, :cmdk_nav_routes, [])) ++
      entity_results(Map.get(assigns, :current_entity_uri), Map.get(assigns, :current_workspace_uri))
  end

  defp nav_results(nav_routes) when is_list(nav_routes) do
    Enum.map(nav_routes, fn route ->
      %{
        key: "nav:" <> to_string(field(route, :path)),
        kind: :nav,
        label: to_string(field(route, :label)),
        target: to_string(field(route, :path)),
        icon: to_string(field(route, :icon) || "dot"),
        group: to_string(field(route, :group) || "Navigate")
      }
    end)
  end

  defp nav_results(_), do: []

  defp entity_results(nil, _workspace_uri), do: []
  defp entity_results(_caller_uri, nil), do: []

  defp entity_results(caller_uri, workspace_uri) do
    uri_options = Module.concat([Ezagent.UI, UriOptions])

    if Code.ensure_loaded?(uri_options) and
         function_exported?(uri_options, :entities_and_sessions, 2) do
      caller_uri
      |> then(&apply(uri_options, :entities_and_sessions, [&1, workspace_uri]))
      |> Enum.map(fn option ->
        uri = to_string(field(option, :uri))
        kind = field(option, :kind)

        %{
          key: "entity:" <> uri,
          kind: :entity,
          label: to_string(field(option, :label) || uri),
          target: entity_target(option, uri),
          icon: entity_icon(kind),
          group: entity_group(kind)
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp entity_target(option, uri) do
    case {field(option, :kind), field(option, :flavor)} do
      {:session, _} -> "/sessions?session=" <> URI.encode_www_form(uri)
      {"session", _} -> "/sessions?session=" <> URI.encode_www_form(uri)
      {:entity, flavor} when is_binary(flavor) -> "/identities/agents/" <> URI.encode_www_form(uri)
      {"entity", flavor} when is_binary(flavor) -> "/identities/agents/" <> URI.encode_www_form(uri)
      _ -> "/identities"
    end
  end

  defp entity_icon(kind) when kind in [:session, "session"], do: "message-square"
  defp entity_icon(kind) when kind in [:entity, "entity"], do: "users"
  defp entity_icon(_), do: "dot"

  defp entity_group(kind) when kind in [:session, "session"], do: "Sessions"
  defp entity_group(kind) when kind in [:entity, "entity"], do: "Entities"
  defp entity_group(_), do: "Entities"

  defp search(query, candidates) do
    command_source = Module.concat([Ezagent.UI, CommandSource])

    if Code.ensure_loaded?(command_source) and function_exported?(command_source, :search, 2) do
      command_source
      |> apply(:search, [query, candidates])
      |> Enum.map(&jsonable/1)
    else
      Enum.take(candidates, 20) |> Enum.map(&jsonable/1)
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_map, _key), do: nil

  defp jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(other), do: other
end
