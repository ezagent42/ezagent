defmodule Ezagent.Behavior.Workspace.AgentCreate.FlavorConfig do
  @moduledoc false

  @create_arg_keys ~w(flavor name cwd with_pty from flavor_config)

  @doc false
  def coerce(flavor, args) when is_binary(flavor) and is_map(args) do
    with {:ok, nested} <- nested(args) do
      schema_fields = fields(flavor)
      allowed = schema_fields |> Enum.map(& &1.key) |> MapSet.new()
      required = required_keys(schema_fields)

      submitted =
        args
        |> top_level()
        |> Map.merge(nested)

      unknown =
        submitted
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(allowed, &1))
        |> Enum.sort()

      if unknown == [] do
        {:ok, normalize(submitted, required)}
      else
        {:error, {:unknown_flavor_config_keys, flavor, unknown}}
      end
    end
  end

  @doc false
  def fields(flavor) do
    with {:ok, %{template_class: template_class}} <- Ezagent.AgentFlavorRegistry.lookup(flavor),
         true <- is_atom(template_class),
         true <- Code.ensure_loaded?(template_class),
         true <- function_exported?(template_class, :config_schema, 0) do
      template_class.config_schema()
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(is_binary(Map.get(&1, :key)) and Map.get(&1, :key) != ""))
    else
      _ -> []
    end
  end

  @doc false
  def from_template(flavor, tmpl) when is_binary(flavor) and is_map(tmpl) do
    flavor
    |> fields()
    |> Enum.reduce(%{}, fn %{key: key}, acc ->
      case Map.fetch(tmpl, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp nested(args) do
    case Map.get(args, :flavor_config) || Map.get(args, "flavor_config") do
      nil -> {:ok, %{}}
      config when is_map(config) -> {:ok, stringify_keys(config)}
      other -> {:error, {:bad_flavor_config, other}}
    end
  end

  defp top_level(args) do
    args
    |> Enum.reject(fn {key, _value} -> create_arg_key?(key) end)
    |> Map.new(fn {key, value} -> {to_key(key), value} end)
  end

  defp create_arg_key?(key) when is_atom(key), do: Atom.to_string(key) in @create_arg_keys
  defp create_arg_key?(key) when is_binary(key), do: key in @create_arg_keys
  defp create_arg_key?(_), do: false

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_key(key), value} end)

  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key) when is_binary(key), do: key
  defp to_key(key), do: inspect(key)

  defp normalize(submitted, required) do
    submitted
    |> Enum.reject(fn
      {_key, nil} -> true
      {key, ""} -> not MapSet.member?(required, key)
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp required_keys(fields) do
    fields
    |> Enum.filter(&(Map.get(&1, :required) == true))
    |> Enum.map(& &1.key)
    |> MapSet.new()
  end
end
