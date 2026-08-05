defmodule Ezagent.Socialware.ManifestYaml do
  @moduledoc """
  YAML interchange for socialware manifests.

  The library API is content-only: callers pass YAML bytes, never filesystem
  paths. Operator tasks and boot seed code own file reads before calling here.
  """

  alias Ezagent.ConfigGovernance.Socialware, as: Governance

  alias Ezagent.Socialware.{
    Conformance,
    Definition,
    DefinitionRegistry,
    ManifestResolver,
    ManifestViews
  }

  @top_level_order [
    "name",
    "version",
    "title",
    "description",
    "uses",
    "requires",
    "bases",
    "shape",
    "views",
    "roles",
    "routing_rules",
    "visibility_policy",
    "assets",
    "prompt_templates",
    "legends",
    "orchestrator_template_uri",
    "adapters",
    "ingress",
    "owner_policy"
  ]

  @doc "Parse YAML content into Definition attrs."
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(binary) when is_binary(binary) do
    with {:ok, decoded} <- YamlElixir.read_from_string(binary),
         %{} = attrs <- decoded,
         {:ok, attrs} <- normalize_module_list(attrs, "bases"),
         {:ok, attrs} <- normalize_module_list(attrs, "shape") do
      {:ok, attrs}
    else
      {:error, error} -> {:error, error}
      other -> {:error, {:invalid_manifest_yaml, other}}
    end
  end

  @doc "Render a Definition to canonical YAML content."
  @spec render(Definition.t()) :: {:ok, binary()} | {:error, term()}
  def render(%Definition{} = definition) do
    body = Definition.body(definition)
    ingress_yaml = ingress_yaml(body.ingress)

    with {:ok, views} <- render_views(definition.views) do
      body
      |> Map.put("views", views)
      |> Map.put("bases", Enum.map(definition.bases, &module_name/1))
      |> Map.put("shape", Enum.map(definition.shape, &module_name/1))
      |> canonical_map()
      |> yaml_encode()
      |> then(&(ingress_yaml <> &1))
      |> then(&{:ok, &1})
    end
  end

  @doc "Import YAML content through resolve, conformance, and governed publish."
  @spec import(binary(), map()) :: {:ok, :published | :upgraded | :exists} | {:error, term()}
  def import(yaml_binary, ctx) when is_binary(yaml_binary) and is_map(ctx) do
    with {:ok, attrs} <- parse(yaml_binary),
         {:ok, %Definition{} = definition} <-
           attrs
           |> Map.put("workspace_uri", Map.fetch!(ctx, :workspace_uri))
           |> ManifestResolver.resolve(),
         :ok <- Conformance.check_candidate(definition, Map.fetch!(ctx, :workspace_uri)) do
      Governance.publish_or_upgrade(definition, ctx)
    end
  end

  @doc "Export a published definition as YAML."
  @spec export(String.t(), URI.t() | String.t()) :: {:ok, binary()} | {:error, term()}
  def export(name, workspace_uri) when is_binary(name) do
    case DefinitionRegistry.lookup(workspace_uri, name) do
      {:ok, %Definition{} = definition, _object} -> render(definition)
      :error -> {:error, {:unknown_socialware_definition, name}}
    end
  end

  @doc "Operator admin context for a definition import/export seed."
  @spec operator_admin_ctx(String.t(), URI.t() | String.t()) :: map()
  def operator_admin_ctx(name, workspace_uri) when is_binary(name) do
    ws = workspace_uri_struct(workspace_uri)
    admin = Ezagent.URI.user(:system, :admin)

    %{
      caller: admin,
      authenticated_principal: admin,
      workspace_uri: ws,
      caps:
        MapSet.new([
          Governance.manage_cap(name, ws, admin)
        ])
    }
  end

  defp normalize_module_list(attrs, key) do
    case Map.get(attrs, key, []) do
      list when is_list(list) ->
        Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
          case module_ref(value) do
            {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, modules} -> {:ok, Map.put(attrs, key, Enum.reverse(modules))}
          error -> error
        end

      other ->
        {:error, {:invalid_manifest_field, key, other}}
    end
  end

  defp module_ref(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod),
    do: {:ok, mod}

  defp module_ref(name) when is_binary(name) do
    module_name = if String.starts_with?(name, "Elixir."), do: name, else: "Elixir." <> name

    mod = String.to_existing_atom(module_name)

    if Code.ensure_loaded?(mod) do
      {:ok, mod}
    else
      {:error, {:unknown_module, name}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_module, name}}
  end

  defp module_ref(other), do: {:error, {:unknown_module, other}}

  defp render_views(views) do
    view_modules = view_modules()

    Enum.reduce_while(views, {:ok, []}, fn behavior, {:ok, acc} ->
      case view_id_for_behavior(view_modules, behavior) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp view_id_for_behavior(view_modules, behavior) do
    Enum.find_value(view_modules, fn view_module ->
      if backing_behavior(view_module) == behavior do
        {:ok, Atom.to_string(view_module.id())}
      end
    end) || {:error, {:unrenderable_view, behavior}}
  end

  defp view_modules do
    with {:ok, registry} <- ManifestViews.session_view_registry(),
         :ok <- apply(registry, :init, []),
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
    if Code.ensure_loaded?(view_module) and function_exported?(view_module, :view_behavior, 0) do
      view_module.view_behavior()
    end
  rescue
    _ -> nil
  end

  defp canonical_map(map) do
    Map.new(@top_level_order, fn key -> {key, manifest_get(map, key)} end)
    |> Enum.reject(fn {_key, value} -> empty_value?(value) end)
    |> Map.new()
  end

  defp manifest_get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp empty_value?(nil), do: true
  defp empty_value?(""), do: true
  defp empty_value?([]), do: true
  defp empty_value?(%{}), do: true
  defp empty_value?(_), do: false

  defp ingress_yaml(nil), do: ""
  defp ingress_yaml(ingress), do: encode_pair("ingress", ingress, 0)

  defp yaml_encode(map) when is_map(map) do
    map
    |> ordered_pairs()
    |> Enum.map(fn {key, value} -> encode_pair(to_string(key), value, 0) end)
    |> Enum.join("")
  end

  defp encode_pair(key, value, indent) when is_map(value) do
    "#{spaces(indent)}#{key}:\n" <> encode_map(value, indent + 2)
  end

  defp encode_pair(key, value, indent) when is_list(value) do
    "#{spaces(indent)}#{key}:\n" <> encode_list(value, indent + 2)
  end

  defp encode_pair(key, value, indent), do: "#{spaces(indent)}#{key}: #{encode_scalar(value)}\n"

  defp encode_map(map, indent) do
    map
    |> ordered_pairs()
    |> Enum.map(fn {key, value} -> encode_pair(to_string(key), value, indent) end)
    |> Enum.join("")
  end

  defp encode_list(list, indent) do
    Enum.map_join(list, "", fn
      value when is_map(value) ->
        case ordered_pairs(value) do
          [] ->
            "#{spaces(indent)}- {}\n"

          pairs ->
            "#{spaces(indent)}-\n" <>
              Enum.map_join(pairs, "", fn {key, val} ->
                encode_pair(to_string(key), val, indent + 2)
              end)
        end

      value when is_list(value) ->
        "#{spaces(indent)}-\n" <> encode_list(value, indent + 2)

      value ->
        "#{spaces(indent)}- #{encode_scalar(value)}\n"
    end)
  end

  defp ordered_pairs(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), yaml_value(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp yaml_value(%URI{} = uri), do: URI.to_string(uri)
  defp yaml_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)

  defp yaml_value(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {to_string(key), yaml_value(val)} end)

  defp yaml_value(value) when is_list(value), do: Enum.map(value, &yaml_value/1)
  defp yaml_value(value), do: value

  defp encode_scalar(true), do: "true"
  defp encode_scalar(false), do: "false"
  defp encode_scalar(nil), do: "null"
  defp encode_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp encode_scalar(value) when is_binary(value), do: inspect(value)

  defp module_name(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp workspace_uri_struct(%URI{} = uri), do: uri
  defp workspace_uri_struct(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  defp spaces(count), do: String.duplicate(" ", count)
end
