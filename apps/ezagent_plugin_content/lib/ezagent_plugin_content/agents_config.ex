defmodule EzagentPluginContent.AgentsConfig do
  @moduledoc """
  Platform-level agent configuration loaded from the skeleton's `config/agents.yaml`.

  This is a master-only platform config packaged in `priv/skeleton/` — it is
  intentionally NOT read from tenant sandbox or release directories.
  """

  alias EzagentPluginContent.TenantPaths

  @doc """
  Load the platform agents config from `priv/skeleton/config/agents.yaml`.

  Returns the parsed map, e.g. `%{"fast" => %{...}, "slow" => %{...}}`.
  """
  @spec load() :: map()
  def load do
    path = Path.join([TenantPaths.skeleton_dir(), "config", "agents.yaml"])
    YamlElixir.read_from_file!(path)
  end

  @doc """
  Return the config map for the given role.

  Raises `ArgumentError` if the role is unknown.
  """
  @spec for_role(String.t()) :: map()
  def for_role(role) when is_binary(role) do
    config = load()

    case Map.fetch(config, role) do
      {:ok, value} ->
        value

      :error ->
        known = config |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        raise ArgumentError, "unknown role #{inspect(role)}; known roles: #{known}"
    end
  end
end
