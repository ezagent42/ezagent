defmodule EzagentPluginContent.Soul.SoulStore do
  @moduledoc """
  Read/write tenant soul slot_values as YAML files.
  Supports sandbox and release paths via `_current` symlink.
  """

  @doc """
  Read slot_values for a tenant role.
  Returns `{:ok, map()}` or `{:error, reason}`.
  """
  @spec read_slots(binary(), String.t(), String.t(), :sandbox | :release) :: {:ok, map()} | {:error, term()}
  def read_slots(base_dir, tid, role, source)

  def read_slots(base_dir, tid, role, :sandbox) do
    path = sandbox_path(base_dir, tid, role)
    read_yaml(path)
  end

  def read_slots(base_dir, tid, role, :release) do
    path = release_path(base_dir, tid, role)
    read_yaml(path)
  end

  @doc """
  Write (merge) slot_values. Preserves existing keys, only updates the given ones.
  """
  @spec write_slots(binary(), String.t(), String.t(), map(), :sandbox | :release) :: :ok | {:error, term()}
  def write_slots(base_dir, tid, role, values, source) when source in [:sandbox, :release] do
    path = path_for(base_dir, tid, role, source)

    existing =
      case read_yaml(path) do
        {:ok, m} -> m
        _ -> %{}
      end

    merged = deep_merge(existing, values)
    write_yaml(path, merged)
  end

  @doc """
  Get default slot values from skeleton template.
  Parses the template for {{key}} and returns empty defaults.
  """
  @spec defaults(binary(), String.t()) :: map()
  def defaults(_tid, _role) do
    # Will be populated in T0A.5 when tenant_runtime is available.
    # For now: parse skeleton template from priv/
    %{}
  end

  # Private helpers
  defp path_for(base, tid, role, :sandbox),
    do: sandbox_path(base, tid, role)

  defp path_for(base, tid, role, :release),
    do: release_path(base, tid, role)

  defp sandbox_path(base, tid, role),
    do: Path.join([base, tid, "sandbox", "slots", "#{role}.yaml"])

  defp release_path(base, tid, role),
    do: Path.join([base, tid, "release", "_current", "slots", "#{role}.yaml"])

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> {:ok, data}
      # No file = empty slots
      {:error, _} -> {:ok, %{}}
    end
  end

  defp write_yaml(path, data) do
    path |> Path.dirname() |> File.mkdir_p!()
    yaml = encode_yaml(data)
    File.write!(path, yaml)
    :ok
  end

  # Simple YAML encoder for string-keyed nested maps
  defp encode_yaml(map, indent \\ 0)

  defp encode_yaml(map, indent) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      prefix = String.duplicate("  ", indent)

      if is_map(v) do
        "#{prefix}#{k}:\n#{encode_yaml(v, indent + 1)}"
      else
        "#{prefix}#{k}: #{v}"
      end
    end)
    |> Enum.join("\n")
  end

  defp encode_yaml(value, _indent), do: "#{value}"

  defp deep_merge(map1, map2) do
    Map.merge(map1, map2, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end
end
