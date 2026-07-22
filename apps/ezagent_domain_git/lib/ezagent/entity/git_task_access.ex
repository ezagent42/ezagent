defmodule Ezagent.Entity.GitTaskAccess do
  @moduledoc """
  Ephemeral, exact-operation policy for one Git task access grant.

  The struct is the closed authoritative policy. Provider, repository,
  credential ownership, grantee, branch, and idempotency coordinates are accepted
  only during initialization and cannot be selected by invocation arguments.
  Runtime ownership and teardown are deliberately outside this module.
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :git_task_access

  @behaviour Ezagent.Kind

  alias Ezagent.DomainGit.RepositoryRef

  attach(Ezagent.ActionSet.GitTaskAccess)

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace
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
  def behaviors, do: [Ezagent.ActionSet.GitTaskAccess]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def supervisor, do: Ezagent.DomainGit.TaskAccessSupervisor

  @impl Ezagent.Kind
  def uri_from_args(%{policy: %__MODULE__{} = policy}), do: uri_from_args(policy)

  def uri_from_args(%__MODULE__{} = policy) do
    case revalidate(policy) do
      {:ok, validated} -> build_uri(validated)
      {:error, reason} -> raise ArgumentError, "invalid GitTaskAccess policy: #{inspect(reason)}"
    end
  end

  @doc "Returns whether a URI is the exact action-free Git task-access receiver shape."
  @spec task_access_uri?(term()) :: boolean()
  def task_access_uri?(%URI{} = uri) do
    RepositoryRef.ezagent_uri?(uri, "entity", "worker") and
      match?({:ok, "gta_" <> <<_digest::binary-size(64)>>}, Ezagent.URI.name(uri)) and
      uri
      |> Ezagent.URI.name()
      |> elem(1)
      |> String.match?(~r/\Agta_[a-f0-9]{64}\z/)
  end

  def task_access_uri?(_uri), do: false

  @doc "Builds an action URI only when the action is part of the validated task policy."
  @spec action_uri(t(), atom()) :: {:ok, URI.t()} | {:error, term()}
  def action_uri(%__MODULE__{} = policy, action) do
    with {:ok, validated} <- revalidate(policy),
         :ok <- action_allowed(validated, action) do
      {:ok,
       validated
       |> build_uri()
       |> Ezagent.URI.with_action(:git_task_access, action)}
    end
  end

  @doc "Builds a closed Git task-access policy after validating every authority coordinate."
  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         {:ok, validated_repository} <- validate_policy(attrs) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :repository, validated_repository))}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}

  @doc "Revalidates a public policy struct before it reaches authority-sensitive code."
  @spec revalidate(term()) :: {:ok, t()} | {:error, term()}
  def revalidate(%__MODULE__{} = policy), do: policy |> Map.from_struct() |> new()
  def revalidate(_policy), do: {:error, :invalid_attributes}

  @doc "Rejects invocation attempts to select stored policy coordinates."
  @spec validate_invocation(t(), term()) :: :ok | {:error, term()}
  def validate_invocation(%__MODULE__{} = policy, args) when is_map(args) do
    with {:ok, validated} <- revalidate(policy) do
      case Enum.find(@policy_only_fields, &provided?(args, &1)) do
        nil -> validate_invocation_action(args, validated)
        field -> {:error, {:forbidden_invocation_field, field}}
      end
    end
  end

  def validate_invocation(%__MODULE__{}, _args), do: {:error, :invalid_invocation_args}

  @doc "Compares a requested initialization with the authoritative live policy slice."
  @spec initialization_result(URI.t(), t()) :: :ok | {:error, term()}
  def initialization_result(%URI{} = uri, %__MODULE__{} = requested) do
    with {:ok, validated_requested} <- revalidate(requested),
         {:ok, %{policy: current}} <- Ezagent.Kind.get_slice(uri, :git_task_access),
         {:ok, validated_current} <- revalidate_current(current) do
      if validated_current == validated_requested,
        do: :ok,
        else: {:error, :conflicting_initialization}
    else
      {:ok, _unexpected_slice} -> {:error, :invalid_live_policy_slice}
      {:error, reason} -> {:error, reason}
    end
  end

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
         {:ok, repository} <-
           repository_binding(attrs.repository, attrs.provider_adapter, workspace),
         :ok <- allowed_head_ref(attrs.allowed_head_ref),
         :ok <- allowed_actions(attrs.allowed_actions),
         :ok <- idempotency_inputs(attrs.idempotency_inputs, attrs.task_id, attrs.generation) do
      {:ok, repository}
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
    with {:ok, validated} <- RepositoryRef.new(Map.from_struct(repository)) do
      cond do
        Ezagent.URI.workspace_name(validated.repository_uri) != {:ok, workspace} ->
          {:error, {:invalid_field, :repository}}

        not is_atom(provider_adapter) or is_nil(provider_adapter) or
            validated.provider_adapter != provider_adapter ->
          {:error, {:invalid_field, :provider_adapter}}

        true ->
          {:ok, validated}
      end
    else
      {:error, _reason} -> {:error, {:invalid_field, :repository}}
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

  defp build_uri(%__MODULE__{} = policy) do
    workspace = Ezagent.URI.workspace_name!(policy.workspace_uri)

    digest =
      policy
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Ezagent.URI.worker(workspace, "gta_#{digest}")
  end

  defp action_allowed(%__MODULE__{allowed_actions: actions}, action) do
    if action in actions, do: :ok, else: {:error, :action_not_allowed}
  end

  defp validate_invocation_action(args, policy) do
    with {:ok, action} <- fetch_action(args),
         :ok <- action_allowed(policy, action),
         :ok <- validate_task_coordinates(action, args, policy),
         :ok <- validate_requested_head(action, args, policy.allowed_head_ref) do
      :ok
    end
  end

  defp validate_task_coordinates(action, args, policy)
       when action in [:provision_workspace, :cleanup_workspace] do
    with {:ok, task_uri} <- Map.fetch(args, :task_uri),
         true <- exact_task_uri?(task_uri, policy),
         {:ok, generation} <- Map.fetch(args, :generation),
         true <- generation == policy.generation do
      :ok
    else
      :error -> {:error, :task_coordinates_required}
      false -> task_coordinate_error(args, policy)
    end
  end

  defp validate_task_coordinates(_action, _args, _policy), do: :ok

  defp task_coordinate_error(args, policy) do
    if exact_task_uri?(Map.get(args, :task_uri), policy),
      do: {:error, :task_generation_mismatch},
      else: {:error, :task_uri_mismatch}
  end

  defp exact_task_uri?(%URI{scheme: "resource"} = task_uri, policy) do
    workspace = Ezagent.URI.workspace_name!(policy.workspace_uri)

    task_uri == Ezagent.URI.resource(workspace, "kanban-task", policy.task_id)
  rescue
    _ -> false
  end

  defp exact_task_uri?(_task_uri, _policy), do: false

  defp fetch_action(args) do
    case {Map.fetch(args, :action), Map.fetch(args, "action")} do
      {{:ok, _atom_action}, {:ok, _string_action}} ->
        {:error, :ambiguous_action}

      {{:ok, action}, :error} when is_atom(action) ->
        {:ok, action}

      {:error, {:ok, action}} when is_binary(action) ->
        case Enum.find(@actions, &(Atom.to_string(&1) == action)) do
          nil -> {:error, :action_not_allowed}
          known -> {:ok, known}
        end

      _ ->
        {:error, :action_required}
    end
  end

  defp revalidate_current(current) do
    case revalidate(current) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, {:invalid_current_policy, reason}}
    end
  end

  defp validate_requested_head(:create_change_request, args, allowed_head_ref) do
    case {Map.fetch(args, :head_ref), Map.fetch(args, "head_ref")} do
      {{:ok, _atom_ref}, {:ok, _string_ref}} -> {:error, :ambiguous_head_ref}
      {{:ok, ^allowed_head_ref}, :error} -> :ok
      {:error, {:ok, ^allowed_head_ref}} -> :ok
      _ -> {:error, :head_ref_not_allowed}
    end
  end

  defp validate_requested_head(_action, args, _allowed_head_ref) do
    case {Map.has_key?(args, :head_ref), Map.has_key?(args, "head_ref")} do
      {true, true} -> {:error, :ambiguous_head_ref}
      {false, false} -> :ok
      _ -> {:error, :head_ref_not_allowed}
    end
  end
end
