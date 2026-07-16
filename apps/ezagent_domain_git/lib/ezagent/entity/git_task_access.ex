defmodule Ezagent.Entity.GitTaskAccess do
  @moduledoc """
  Ephemeral, exact-resource policy for one Git task access grant.

  The struct is the closed authoritative policy. Provider, repository,
  credential ownership, grantee, branch, and idempotency coordinates are accepted
  only during initialization and cannot be selected by invocation arguments.
  Runtime ownership and teardown are deliberately outside this module.
  """

  use Ezagent.Kind,
    pattern: :resource,
    type_name: :git_task_access

  @behaviour Ezagent.Kind

  alias Ezagent.DomainGit.RepositoryRef

  @resource_type "git-task-access"
  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]
  @fields [
    :id,
    :task_id,
    :generation,
    :workspace_uri,
    :credential_owner_uri,
    :grantee_uri,
    :repository,
    :provider_adapter,
    :allowed_head_ref,
    :allowed_actions,
    :idempotency_inputs
  ]
  @policy_only_fields [
    :workspace_uri,
    :credential_owner_uri,
    :grantee_uri,
    :repository,
    :provider_adapter,
    :allowed_head_ref,
    :allowed_actions,
    :idempotency_inputs,
    :operation_context
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t(),
          generation: pos_integer(),
          workspace_uri: URI.t(),
          credential_owner_uri: URI.t(),
          grantee_uri: URI.t(),
          repository: RepositoryRef.t(),
          provider_adapter: atom(),
          allowed_head_ref: String.t(),
          allowed_actions: [atom()],
          idempotency_inputs: %{task_id: String.t(), generation: pos_integer()}
        }

  @impl Ezagent.Kind
  def behaviors, do: []

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def uri_from_args(args) when is_map(args) do
    workspace = args |> Map.fetch!(:workspace_uri) |> Ezagent.URI.workspace_name!()
    Ezagent.URI.resource(workspace, @resource_type, Map.fetch!(args, :id))
  end

  @spec action_uri(map() | t(), atom()) :: URI.t()
  def action_uri(args, action) when action in @actions do
    args
    |> uri_from_args()
    |> Ezagent.URI.with_action(:git_task_access, action)
  end

  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         :ok <- validate_policy(attrs) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}

  @doc "Initializes once, permits an identical retry, and rejects policy collision."
  @spec initialize(nil | t(), term()) :: {:ok, t()} | {:error, term()}
  def initialize(nil, attrs), do: new(attrs)

  def initialize(%__MODULE__{} = current, attrs) do
    case new(attrs) do
      {:ok, ^current} -> {:ok, current}
      {:ok, %__MODULE__{}} -> {:error, :conflicting_initialization}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rejects invocation attempts to select stored policy coordinates."
  @spec validate_invocation(t(), term()) :: :ok | {:error, term()}
  def validate_invocation(%__MODULE__{} = policy, args) when is_map(args) do
    case Enum.find(@policy_only_fields, &provided?(args, &1)) do
      nil -> validate_requested_head(args, policy.allowed_head_ref)
      field -> {:error, {:forbidden_invocation_field, field}}
    end
  end

  def validate_invocation(%__MODULE__{}, _args), do: {:error, :invalid_invocation_args}

  defp validate_keys(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_attributes}

      Enum.any?(keys, &(&1 not in @fields)) ->
        {:error, :unknown_fields}

      missing = Enum.find(@fields, &(not Map.has_key?(attrs, &1))) ->
        {:error, {:missing_field, missing}}

      true ->
        :ok
    end
  end

  defp validate_policy(attrs) do
    with {:ok, workspace} <- exact_workspace(attrs.workspace_uri),
         :ok <- valid_identifier(:id, attrs.id),
         :ok <- valid_identifier(:task_id, attrs.task_id),
         :ok <- positive_generation(attrs.generation),
         :ok <- entity_in_workspace(:credential_owner_uri, attrs.credential_owner_uri, workspace),
         :ok <- agent_in_workspace(attrs.grantee_uri, workspace),
         :ok <- repository_binding(attrs.repository, attrs.provider_adapter, workspace),
         :ok <- allowed_head_ref(attrs.allowed_head_ref),
         :ok <- allowed_actions(attrs.allowed_actions),
         :ok <- idempotency_inputs(attrs.idempotency_inputs, attrs.task_id, attrs.generation) do
      :ok
    end
  end

  defp exact_workspace(%URI{} = uri) do
    with {:ok, workspace} <- Ezagent.URI.workspace_name(uri),
         true <- uri == Ezagent.URI.workspace(workspace) do
      {:ok, workspace}
    else
      _ -> {:error, {:invalid_field, :workspace_uri}}
    end
  rescue
    _ -> {:error, {:invalid_field, :workspace_uri}}
  end

  defp exact_workspace(_), do: {:error, {:invalid_field, :workspace_uri}}

  defp valid_identifier(field, value) when is_binary(value) and byte_size(value) in 1..255 do
    if String.match?(value, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) and
         not String.contains?(value, "..") do
      :ok
    else
      {:error, {:invalid_field, field}}
    end
  end

  defp valid_identifier(field, _value), do: {:error, {:invalid_field, field}}

  defp positive_generation(value) when is_integer(value) and value > 0, do: :ok
  defp positive_generation(_value), do: {:error, {:invalid_field, :generation}}

  defp entity_in_workspace(field, %URI{} = uri, workspace) do
    if Ezagent.URI.bare_principal?(uri) and Ezagent.URI.workspace_name(uri) == {:ok, workspace},
      do: :ok,
      else: {:error, {:invalid_field, field}}
  end

  defp entity_in_workspace(field, _uri, _workspace), do: {:error, {:invalid_field, field}}

  defp agent_in_workspace(%URI{} = uri, workspace) do
    if Ezagent.URI.bare_principal?(uri) and Ezagent.URI.type(uri) == {:ok, "agent"} and
         Ezagent.URI.workspace_name(uri) == {:ok, workspace},
       do: :ok,
       else: {:error, {:invalid_field, :grantee_uri}}
  end

  defp agent_in_workspace(_uri, _workspace), do: {:error, {:invalid_field, :grantee_uri}}

  defp repository_binding(%RepositoryRef{} = repository, provider_adapter, workspace) do
    cond do
      Ezagent.URI.workspace_name(repository.repository_uri) != {:ok, workspace} ->
        {:error, {:invalid_field, :repository}}

      not is_atom(provider_adapter) or is_nil(provider_adapter) or
          repository.provider_adapter != provider_adapter ->
        {:error, {:invalid_field, :provider_adapter}}

      true ->
        :ok
    end
  end

  defp repository_binding(_repository, _provider_adapter, _workspace),
    do: {:error, {:invalid_field, :repository}}

  defp allowed_head_ref(value) do
    if RepositoryRef.valid_ref?(value),
      do: :ok,
      else: {:error, {:invalid_field, :allowed_head_ref}}
  end

  defp allowed_actions(actions) when is_list(actions) and actions != [] do
    if Enum.uniq(actions) == actions and Enum.all?(actions, &(&1 in @actions)),
      do: :ok,
      else: {:error, {:invalid_field, :allowed_actions}}
  end

  defp allowed_actions(_actions), do: {:error, {:invalid_field, :allowed_actions}}

  defp idempotency_inputs(
         %{task_id: task_id, generation: generation} = inputs,
         task_id,
         generation
       )
       when map_size(inputs) == 2,
       do: :ok

  defp idempotency_inputs(_inputs, _task_id, _generation),
    do: {:error, {:invalid_field, :idempotency_inputs}}

  defp provided?(args, field),
    do: Map.has_key?(args, field) or Map.has_key?(args, Atom.to_string(field))

  defp validate_requested_head(args, allowed_head_ref) do
    case Map.fetch(args, :head_ref) do
      :error ->
        case Map.fetch(args, "head_ref") do
          :error -> :ok
          {:ok, ^allowed_head_ref} -> :ok
          {:ok, _other} -> {:error, :head_ref_not_allowed}
        end

      {:ok, ^allowed_head_ref} ->
        :ok

      {:ok, _other} ->
        {:error, :head_ref_not_allowed}
    end
  end
end
