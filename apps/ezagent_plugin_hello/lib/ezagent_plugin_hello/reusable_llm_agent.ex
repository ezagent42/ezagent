defmodule EzagentPluginHello.ReusableLlmAgent do
  @moduledoc """
  Discovers and revalidates existing agents that may fill Hello's `llm` role.

  The list is only a convenience for selectors. `validate/4` is the synchronous
  creation-time gate and re-reads durable recipe/flavor/profile state, current
  caller authority, and the non-activating credential status.
  """

  alias Ezagent.Agent.{
    CredentialAdapter,
    CredentialSliceAdapter,
    RecipeAttributes,
    RecipeResolver
  }

  alias Ezagent.Entity.Agent
  alias Ezagent.Identity.Authority
  alias EzagentPluginHello.App

  @recipe "hello.llm"
  @credentialed_statuses [:authenticated, :expiring]
  @provider_profiles %{
    "curl" => "deepseek",
    "cc-headless-custom" => "deepseek"
  }

  @type candidate :: %{
          agent_uri: URI.t(),
          flavor: String.t(),
          provider_profile: String.t() | nil,
          credential_status: atom()
        }

  @doc "List caller-managed, ready `hello.llm` agents for an exact flavor."
  @spec list(URI.t(), URI.t(), String.t()) ::
          {:ok, [candidate()]} | {:error, term()}
  def list(%URI{} = caller, %URI{} = workspace_uri, flavor) when is_binary(flavor) do
    with :ok <- validate_supported_flavor(flavor) do
      candidates =
        @recipe
        |> RecipeResolver.list_by_recipe(workspace_uri)
        |> Enum.reduce([], fn agent_uri, acc ->
          case validate(caller, workspace_uri, flavor, agent_uri) do
            {:ok, candidate} -> [candidate | acc]
            {:error, _reason} -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, candidates}
    end
  end

  def list(_caller, _workspace_uri, _flavor), do: {:error, :invalid_arguments}

  @doc "Revalidate one selected reusable LLM agent immediately before creation."
  @spec validate(URI.t(), URI.t(), String.t(), URI.t()) ::
          {:ok, candidate()} | {:error, term()}
  def validate(
        %URI{} = caller,
        %URI{} = workspace_uri,
        flavor,
        %URI{} = agent_uri
      )
      when is_binary(flavor) do
    with :ok <- validate_supported_flavor(flavor),
         :ok <- validate_agent_uri(agent_uri),
         :ok <- validate_workspace_agent(workspace_uri, agent_uri),
         :ok <- validate_authority(caller, agent_uri),
         :ok <- validate_recipe(agent_uri),
         :ok <- validate_flavor(agent_uri, flavor),
         {:ok, provider_profile} <- validate_provider_profile(agent_uri, flavor),
         {:ok, status} <- validate_credential_status(caller, agent_uri, flavor) do
      {:ok,
       %{
         agent_uri: agent_uri,
         flavor: flavor,
         provider_profile: provider_profile,
         credential_status: status
       }}
    end
  end

  def validate(_caller, _workspace_uri, _flavor, _agent_uri),
    do: {:error, :invalid_arguments}

  defp validate_supported_flavor(flavor) do
    if flavor in App.llm_flavors(),
      do: :ok,
      else: {:error, {:unsupported_flavor, flavor}}
  end

  defp validate_agent_uri(%URI{} = agent_uri) do
    if Ezagent.URI.scheme?(agent_uri, :entity) and Ezagent.URI.type?(agent_uri, :agent),
      do: :ok,
      else: {:error, :invalid_agent_uri}
  end

  # The persisted agent directory is the live+dormant existence source and the
  # workspace boundary. Cross-workspace and stale selections intentionally
  # collapse to the same non-leaking error.
  defp validate_workspace_agent(workspace_uri, agent_uri) do
    same_workspace? =
      Ezagent.Capability.workspace_of(agent_uri)
      |> same_uri?(workspace_uri)

    exists? =
      same_workspace? and
        Enum.any?(Agent.list_in_workspace(workspace_uri), &same_uri?(&1, agent_uri))

    if exists?, do: :ok, else: {:error, :not_found}
  end

  defp validate_authority(caller, agent_uri) do
    if Authority.manages?(caller, agent_uri), do: :ok, else: {:error, :unauthorized}
  end

  defp validate_recipe(agent_uri) do
    case RecipeAttributes.fetch_or_resolve(agent_uri) do
      {:ok, @recipe} -> :ok
      {:ok, actual} -> {:error, {:recipe_mismatch, actual}}
      :none -> {:error, {:recipe_mismatch, nil}}
    end
  end

  defp validate_flavor(agent_uri, expected) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:flavor_mismatch, actual}}
      :none -> {:error, {:flavor_mismatch, nil}}
    end
  end

  defp validate_provider_profile(agent_uri, flavor) do
    expected = Map.get(@provider_profiles, flavor)
    actual = provider_profile(agent_uri, flavor)

    if actual == expected,
      do: {:ok, actual},
      else: {:error, {:provider_profile_mismatch, expected, actual}}
  end

  defp validate_credential_status(caller, agent_uri, flavor) do
    ctx = %{caller: caller, authenticated_principal: caller}

    case Ezagent.Domain.Agent.read_credential_status(agent_uri, ctx) do
      {:ok, %{status: status}} ->
        if eligible_credential_status?(flavor, status),
          do: {:ok, status},
          else: {:error, {:ineligible_credential_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp eligible_credential_status?(flavor, status) do
    case Ezagent.AgentFlavorRegistry.lookup(flavor) do
      {:ok, %{template_class: template_class}} when is_atom(template_class) ->
        credentialed? =
          CredentialAdapter.credentialled?(template_class) or
            CredentialSliceAdapter.credentialled?(template_class)

        if credentialed?, do: status in @credentialed_statuses, else: status == :n_a

      _ ->
        false
    end
  end

  defp provider_profile(agent_uri, "curl") do
    agent_uri
    |> read_slice(:curl_agent)
    |> field(:provider)
    |> normalize_profile()
  end

  defp provider_profile(agent_uri, "cc-headless-custom") do
    agent_uri
    |> read_slice(:sandbox)
    |> field(:respawn_template_data)
    |> field(:provider)
    |> normalize_profile()
  end

  defp provider_profile(_agent_uri, _flavor), do: nil

  defp read_slice(agent_uri, slice_key) do
    case Ezagent.Kind.read(agent_uri, slice_key, spawn: :never) do
      {:ok, slice} when is_map(slice) ->
        slice

      _ ->
        case Ezagent.Kind.read_durable(agent_uri, slice_key) do
          {:ok, slice, _meta} when is_map(slice) -> slice
          _ -> %{}
        end
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_other, _key), do: nil

  defp normalize_profile(profile) when is_binary(profile) and profile != "", do: profile
  defp normalize_profile(_profile), do: nil

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
