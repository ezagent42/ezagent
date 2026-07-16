defmodule Ezagent.ActionSet.GitTaskAccess do
  @moduledoc """
  Lifecycle host for the authoritative Git task-access policy and its closed
  provider-neutral operation vocabulary.
  """

  use Ezagent.Lifecycle

  alias Ezagent.DomainGit.{
    AdapterRegistry,
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef,
    TaskAccessSupervisor
  }

  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews
  ]
  @allowed_keys %{
    resolve_repository: [:repository],
    create_change_request: [:changes, :repository, :request],
    read_change_request: [:change_request_id, :repository],
    list_checks: [:commit_sha, :repository],
    list_reviews: [:change_request_id, :repository]
  }

  action(:resolve_repository,
    args: %{repository: :term},
    returns: :term,
    caps: [:resolve_repository],
    modes: [:call],
    description: "Resolve the task-bound repository"
  )

  action(:create_change_request,
    args: %{repository: :term, changes: {:list, :term}, request: :term},
    returns: :term,
    caps: [:create_change_request],
    modes: [:call],
    description: "Create a task-bound change request"
  )

  action(:read_change_request,
    args: %{repository: :term, change_request_id: :term},
    returns: :term,
    caps: [:read_change_request],
    modes: [:call],
    description: "Read a task-bound change request"
  )

  action(:list_checks,
    args: %{repository: :term, commit_sha: :term},
    returns: :term,
    caps: [:list_checks],
    modes: [:call],
    description: "List checks for a task-bound commit"
  )

  action(:list_reviews,
    args: %{repository: :term, change_request_id: :term},
    returns: :term,
    caps: [:list_reviews],
    modes: [:call],
    description: "List reviews for a task-bound change request"
  )

  @impl Ezagent.ActionSet
  def cap_subjects, do: Enum.map(@actions, &{&1, "Git task operation #{&1}"})

  @impl Ezagent.ActionSet
  def required_caps do
    Map.new(@actions, &{&1, Ezagent.Capability.cap(:resource, __MODULE__, &1)})
  end

  @impl Ezagent.ActionSet
  def data_owner(_instance), do: :any

  @impl Ezagent.Lifecycle
  def create(%{uri: uri, policy: policy}) do
    with {:ok, validated} <- GitTaskAccess.revalidate(policy),
         true <- uri == GitTaskAccess.uri_from_args(validated) do
      {:ok, %{policy: validated}}
    else
      false -> raise ArgumentError, "GitTaskAccess spawn URI does not match policy"
      {:error, reason} -> raise ArgumentError, "invalid GitTaskAccess policy: #{inspect(reason)}"
    end
  end

  @doc false
  def handle_resolve_repository(args, ctx),
    do: dispatch_operation(:resolve_repository, args, ctx)

  @doc false
  def handle_create_change_request(args, ctx),
    do: dispatch_operation(:create_change_request, args, ctx)

  @doc false
  def handle_read_change_request(args, ctx),
    do: dispatch_operation(:read_change_request, args, ctx)

  @doc false
  def handle_list_checks(args, ctx), do: dispatch_operation(:list_checks, args, ctx)
  @doc false
  def handle_list_reviews(args, ctx), do: dispatch_operation(:list_reviews, args, ctx)

  defp dispatch_operation(action, args, ctx) do
    uri = Map.fetch!(ctx, :self_uri)

    TaskAccessSupervisor.with_lifecycle(uri, fn ->
      with {:ok, policy} <- GitTaskAccess.revalidate(ctx.read.(:policy, nil)),
           :ok <- validate_static_request(policy, action, args),
           {:ok, operation_context} <- operation_context(policy, action, ctx),
           {:ok, adapter} <- lookup_adapter(policy.provider_adapter) do
        invoke(adapter, action, operation_context, policy.repository, args)
      end
    end)
  end

  defp validate_static_request(policy, action, %{repository: repository} = args) do
    with :ok <- validate_exact_keys(action, args),
         {:ok, repository} <- RepositoryRef.new(Map.from_struct(repository)),
         true <- repository == policy.repository,
         :ok <-
           GitTaskAccess.validate_invocation(
             policy,
             invocation_comparison_args(action, args)
           ),
         :ok <- validate_action_values(action, args) do
      :ok
    else
      false -> {:error, :repository_mismatch}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :repository_mismatch}
  end

  defp validate_static_request(_policy, _action, _args), do: {:error, :repository_mismatch}

  defp validate_exact_keys(action, args) do
    unknown =
      args |> Map.keys() |> Enum.reject(&(&1 in Map.fetch!(@allowed_keys, action))) |> Enum.sort()

    if unknown == [], do: :ok, else: {:error, {:unknown_invocation_keys, unknown}}
  end

  defp invocation_comparison_args(:create_change_request, args),
    do: %{action: :create_change_request, head_ref: args.request.head_ref}

  defp invocation_comparison_args(action, _args), do: %{action: action}

  defp validate_action_values(:resolve_repository, _args), do: :ok

  defp validate_action_values(:create_change_request, %{changes: changes, request: request}) do
    with :ok <- FileChange.validate_many(changes),
         {:ok, _request} <- CreateChangeRequest.new(Map.from_struct(request)) do
      :ok
    end
  rescue
    _ -> {:error, :invalid_create_request}
  end

  defp validate_action_values(:read_change_request, %{change_request_id: id}),
    do: validate_value(ChangeRequestId, id)

  defp validate_action_values(:list_checks, %{commit_sha: sha}),
    do: validate_value(CommitSha, sha)

  defp validate_action_values(:list_reviews, %{change_request_id: id}),
    do: validate_value(ChangeRequestId, id)

  defp validate_action_values(_action, _args), do: {:error, :invalid_operation_arguments}

  defp validate_value(module, value) do
    module.new(Map.from_struct(value))
    |> case do
      {:ok, _validated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_operation_arguments}
  end

  defp operation_context(policy, action, ctx) do
    OperationContext.new(%{
      task_access_uri: Map.fetch!(ctx, :self_uri),
      caller_uri: Map.fetch!(ctx, :caller),
      grantee_uri: policy.grantee_uri,
      idempotency_key:
        "#{policy.idempotency_inputs.task_id}:#{policy.idempotency_inputs.generation}:#{action}"
    })
  end

  defp lookup_adapter(provider_adapter) do
    case AdapterRegistry.lookup_for_action_set(Atom.to_string(provider_adapter)) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, :provider_adapter_not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke(adapter, :resolve_repository, context, repository, _args),
    do: adapter.resolve_repository(context, repository)

  defp invoke(adapter, :create_change_request, context, repository, args),
    do: adapter.create_change_request(context, repository, args.changes, args.request)

  defp invoke(adapter, :read_change_request, context, repository, args),
    do: adapter.read_change_request(context, repository, args.change_request_id)

  defp invoke(adapter, :list_checks, context, repository, args),
    do: adapter.list_checks(context, repository, args.commit_sha)

  defp invoke(adapter, :list_reviews, context, repository, args),
    do: adapter.list_reviews(context, repository, args.change_request_id)
end
