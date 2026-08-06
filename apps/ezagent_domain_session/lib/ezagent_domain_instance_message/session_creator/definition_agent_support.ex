defmodule EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupport do
  @moduledoc false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.AgentFlavorRegistry

  @doc false
  @spec lookup_recipe(URI.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def lookup_recipe(%URI{} = workspace_uri, recipe_name) do
    case RecipeRegistry.lookup(URI.to_string(workspace_uri), recipe_name) do
      {:ok, recipe} -> {:ok, recipe}
      :error -> {:error, {:unknown_agent_recipe, recipe_name}}
    end
  end

  @doc false
  @spec lookup_ref(term()) :: term()
  def lookup_ref("recipe:" <> rest) when rest != "", do: rest
  def lookup_ref(name), do: name

  @doc false
  @spec planned_agent_uri(URI.t()) :: URI.t()
  def planned_agent_uri(%URI{} = workspace_uri) do
    workspace_uri
    |> Ezagent.URI.workspace_name!()
    |> Ezagent.URI.agent(Ecto.UUID.generate())
  end

  @doc false
  @spec passive_recipe?(map()) :: boolean()
  def passive_recipe?(recipe),
    do: Map.get(recipe, :passive, Map.get(recipe, "passive", false)) == true

  @doc false
  @spec orchestrator_recipe_slot?(map()) :: boolean()
  def orchestrator_recipe_slot?(agent),
    do: role_name_of(agent) == "orchestrator" and lookup_ref(recipe_of(agent)) == "orchestrator"

  @doc false
  @spec recipe_of(map()) :: term()
  def recipe_of(agent), do: Map.get(agent, :recipe) || Map.get(agent, "recipe")

  @doc false
  @spec role_name_of(map()) :: term()
  def role_name_of(agent), do: Map.get(agent, :role_name) || Map.get(agent, "role_name")

  @doc false
  @spec install_mode_of(map()) :: :fresh | :reuse
  def install_mode_of(agent) do
    case Map.get(agent, :install_mode) || Map.get(agent, "install_mode") || Map.get(agent, :mode) ||
           Map.get(agent, "mode") do
      mode when mode in [:reuse, "reuse"] -> :reuse
      _ -> :fresh
    end
  end

  @doc false
  @spec flavor_of(map()) :: String.t()
  def flavor_of(agent) do
    case Map.get(agent, :flavor) || Map.get(agent, "flavor") do
      flavor when is_binary(flavor) and flavor != "" -> flavor
      _ -> "cc"
    end
  end

  @doc false
  @spec credential_admission_of(map()) :: :before_session_join | :immediate
  def credential_admission_of(agent) do
    opts =
      case provider_of(agent) do
        provider when is_binary(provider) -> [role: agent, backend_profile: provider]
        nil -> [role: agent]
      end

    flavor = flavor_of(agent)

    case Ezagent.Agent.CredentialConnection.for_flavor(flavor, opts) do
      {:ok, :not_required} -> declared_credential_admission(agent)
      {:ok, _connection} -> :before_session_join
      {:error, _reason} -> admission_for_connection_error(flavor, agent)
    end
  end

  defp admission_for_connection_error(flavor, agent) do
    case AgentFlavorRegistry.lookup(flavor) do
      {:ok, _declaration} -> :before_session_join
      :error -> declared_credential_admission(agent)
    end
  end

  defp declared_credential_admission(agent) do
    case Map.get(agent, :credential_admission) || Map.get(agent, "credential_admission") do
      value when value in [:before_session_join, "before_session_join"] ->
        :before_session_join

      _ ->
        :immediate
    end
  end

  @doc false
  @spec provider_of(map()) :: String.t() | nil
  def provider_of(agent) do
    case Map.get(agent, :provider) || Map.get(agent, "provider") do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> nil
    end
  end

  @doc false
  @spec role_config(map()) :: map()
  def role_config(agent) do
    case map_field(agent, :config) do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  @doc false
  @spec merge_role_config(map(), map()) :: map()
  def merge_role_config(recipe, config) when is_map(recipe) and is_map(config) do
    base =
      case map_field(recipe, :config) do
        current when is_map(current) -> current
        _ -> %{}
      end

    Map.put(recipe, :config, Map.merge(base, config))
  end

  @doc false
  @spec map_field(map(), atom()) :: term()
  def map_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
