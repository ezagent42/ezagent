defmodule EzagentPluginContent.AgentsConfig do
  @moduledoc """
  Platform-level agent configuration loaded from the skeleton's `config/agents.yaml`.

  This is a master-only platform config packaged in `priv/skeleton/` — it is
  intentionally NOT read from tenant sandbox or release directories.
  """

  alias EzagentPluginContent.TenantPaths

  @doc """
  Load the platform agents config from `priv/skeleton/config/agents.yaml`.

  Returns `{:ok, map}` or `{:error, {:agents_config_unreadable, reason}}`.
  """
  @spec load() :: {:ok, map()} | {:error, {:agents_config_unreadable, term()}}
  def load do
    path = Path.join([TenantPaths.skeleton_dir(), "config", "agents.yaml"])

    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:error, reason} -> {:error, {:agents_config_unreadable, reason}}
    end
  end

  @doc """
  Return the config map for the given role.

  Returns `{:ok, map}`, `{:error, {:unknown_role, role, known: [...]}}`, or
  `{:error, {:agents_config_unreadable, reason}}`.
  """
  @spec for_role(String.t()) ::
          {:ok, map()}
          | {:error, {:unknown_role, String.t(), known: [String.t()]}}
          | {:error, {:agents_config_unreadable, term()}}
  def for_role(role) when is_binary(role) do
    with {:ok, config} <- load() do
      case Map.fetch(config, role) do
        {:ok, value} ->
          {:ok, value}

        :error ->
          known = config |> Map.keys() |> Enum.sort()
          {:error, {:unknown_role, role, known: known}}
      end
    end
  end
end
