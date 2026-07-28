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
    TaskAccessSupervisor,
    WorkspaceChangePort,
    WorkspaceChangeRegistry,
    WorkspaceProvisionPort,
    WorkspaceProvisionRegistry
  }

  alias Ezagent.Entity.GitTaskAccess

  @actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace,
    :collect_workspace_changes
  ]
  @allowed_keys %{
    resolve_repository: [:repository],
    create_change_request: [:changes, :repository, :request],
    read_change_request: [:change_request_id, :repository],
    list_checks: [:commit_sha, :repository],
    list_reviews: [:change_request_id, :repository],
    provision_workspace: [:generation, :task_uri],
    cleanup_workspace: [:generation, :task_uri],
    collect_workspace_changes: [:generation, :task_uri]
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

  action(:provision_workspace,
    args: %{task_uri: :term, generation: :integer},
    returns: :term,
    caps: [:provision_workspace],
    modes: [:call],
    description: "Prepare the exact task generation workspace"
  )

  action(:cleanup_workspace,
    args: %{task_uri: :term, generation: :integer},
    returns: :term,
    caps: [:cleanup_workspace],
    modes: [:call],
    description: "Clean the exact task generation workspace"
  )

  action(:collect_workspace_changes,
    args: %{task_uri: :term, generation: :integer},
    returns: :term,
    caps: [:collect_workspace_changes],
    modes: [:call],
    description:
      "Collect the bounded V1 UTF-8 upsert change envelope for the exact task generation workspace"
  )

  @impl Ezagent.ActionSet
  def required_caps do
    Map.new(@actions, &{&1, Ezagent.Capability.cap(:git_task_access, __MODULE__, &1)})
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

  @doc false
  def handle_provision_workspace(args, ctx),
    do: dispatch_workspace_operation(:provision_workspace, :prepare, args, ctx)

  @doc false
  def handle_cleanup_workspace(args, ctx),
    do: dispatch_workspace_operation(:cleanup_workspace, :cleanup, args, ctx)

  @doc false
  def handle_collect_workspace_changes(args, ctx),
    do: dispatch_change_collection(args, ctx)

  defp dispatch_operation(action, args, ctx) do
    uri = Map.fetch!(ctx, :self_uri)

    TaskAccessSupervisor.with_lifecycle(uri, fn ->
      with {:ok, policy} <- GitTaskAccess.revalidate(ctx.read.(:policy, nil)),
           {:ok, validated_args} <- validate_static_request(policy, action, args),
           :ok <- authorize_receiver(policy, action, ctx),
           {:ok, operation_context} <- operation_context(policy, action, ctx),
           {:ok, adapter} <- lookup_adapter(policy.provider_adapter) do
        invoke(adapter, action, operation_context, policy.repository, validated_args)
      end
    end)
  end

  defp dispatch_workspace_operation(action, operation, args, ctx) do
    task_access_uri = Map.fetch!(ctx, :self_uri)

    TaskAccessSupervisor.with_lifecycle(task_access_uri, fn ->
      with {:ok, policy} <- GitTaskAccess.revalidate(ctx.read.(:policy, nil)),
           {:ok, validated_args} <- validate_workspace_request(policy, action, args),
           :ok <- authorize_receiver(policy, action, ctx),
           {:ok, request} <-
             WorkspaceProvisionPort.Request.new_authorized(
               %{
                 task_access_uri: task_access_uri,
                 task_uri: validated_args.task_uri,
                 generation: validated_args.generation,
                 operation: operation,
                 provision_id:
                   provision_id(
                     policy.workspace_uri,
                     validated_args.task_uri,
                     validated_args.generation
                   )
               },
               policy
             ),
           {:ok, implementation} <- WorkspaceProvisionRegistry.implementation() do
        invoke_workspace(implementation, operation, request)
      end
    end)
  end

  defp dispatch_change_collection(args, ctx) do
    task_access_uri = Map.fetch!(ctx, :self_uri)

    TaskAccessSupervisor.with_lifecycle(task_access_uri, fn ->
      with {:ok, policy} <- GitTaskAccess.revalidate(ctx.read.(:policy, nil)),
           {:ok, validated_args} <-
             validate_workspace_request(policy, :collect_workspace_changes, args),
           :ok <- authorize_receiver(policy, :collect_workspace_changes, ctx),
           {:ok, request} <-
             WorkspaceChangePort.Request.new(%{
               task_access_uri: task_access_uri,
               task_uri: validated_args.task_uri,
               generation: validated_args.generation,
               provision_id:
                 provision_id(
                   policy.workspace_uri,
                   validated_args.task_uri,
                   validated_args.generation
                 )
             }),
           {:ok, implementation} <- WorkspaceChangeRegistry.implementation() do
        implementation.collect(request)
      end
    end)
  end

  defp validate_workspace_request(policy, action, args) when is_map(args) do
    with :ok <- validate_exact_keys(action, args),
         :ok <-
           GitTaskAccess.validate_invocation(policy, %{
             action: action,
             task_uri: Map.get(args, :task_uri),
             generation: Map.get(args, :generation)
           }) do
      {:ok, args}
    end
  end

  defp validate_workspace_request(_policy, _action, _args),
    do: {:error, :invalid_operation_arguments}

  defp validate_static_request(policy, action, %{repository: repository} = args) do
    with :ok <- validate_exact_keys(action, args),
         {:ok, repository} <- validate_repository(repository),
         true <- repository == policy.repository,
         {:ok, validated_args} <- validate_action_values(action, args),
         :ok <-
           GitTaskAccess.validate_invocation(
             policy,
             invocation_comparison_args(action, validated_args)
           ) do
      {:ok, Map.put(validated_args, :repository, repository)}
    else
      false -> {:error, :repository_mismatch}
      {:error, reason} -> {:error, reason}
    end
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

  defp validate_repository(%RepositoryRef{} = repository),
    do: RepositoryRef.new(Map.from_struct(repository))

  defp validate_repository(_repository), do: {:error, :repository_mismatch}

  defp validate_action_values(:resolve_repository, args), do: {:ok, args}

  defp validate_action_values(
         :create_change_request,
         %{changes: changes, request: %CreateChangeRequest{} = request} = args
       ) do
    with :ok <- FileChange.validate_many(changes),
         {:ok, validated_request} <- CreateChangeRequest.new(Map.from_struct(request)) do
      {:ok, %{args | request: validated_request}}
    end
  end

  defp validate_action_values(:create_change_request, _args),
    do: {:error, {:invalid_field, :request}}

  defp validate_action_values(:read_change_request, %{change_request_id: id} = args),
    do: validate_value(args, :change_request_id, ChangeRequestId, id)

  defp validate_action_values(:list_checks, %{commit_sha: sha} = args),
    do: validate_value(args, :commit_sha, CommitSha, sha)

  defp validate_action_values(:list_reviews, %{change_request_id: id} = args),
    do: validate_value(args, :change_request_id, ChangeRequestId, id)

  defp validate_action_values(_action, _args), do: {:error, :invalid_operation_arguments}

  defp validate_value(args, field, module, value) do
    with {:ok, validated} <- rebuild_value(module, value) do
      {:ok, Map.put(args, field, validated)}
    end
  end

  defp rebuild_value(ChangeRequestId, %ChangeRequestId{} = value),
    do: ChangeRequestId.new(Map.from_struct(value))

  defp rebuild_value(CommitSha, %CommitSha{} = value), do: CommitSha.new(Map.from_struct(value))
  defp rebuild_value(_module, _value), do: {:error, :invalid_operation_arguments}

  defp operation_context(policy, action, ctx) do
    OperationContext.new(%{
      task_access_uri: Map.fetch!(ctx, :self_uri),
      caller_uri: Map.fetch!(ctx, :caller),
      grantee_uri: policy.grantee_uri,
      idempotency_key:
        "#{URI.to_string(policy.idempotency_inputs.task_uri)}:" <>
          "#{policy.idempotency_inputs.generation}:#{action}"
    })
  end

  # Runtime dispatch step 5.5 (`Cap.Verifier.authorize/5`) already strictly
  # crypto-verifies the presented cap for every cap-gated action here — signature
  # valid under the target Kind's current authority, bound to the authenticated
  # presenter (caller), and matching the required shape — before this handler
  # runs. The one authorization fact the in-handler adds beyond step 5.5 is
  # binding the presenter to THIS policy's grantee. A redundant in-handler cap
  # re-scan would only duplicate 5.5 with a forgeable presence-only check — the
  # `AuthorizeChokepointRatchetTest` :bare_match_authorization_authorizes offender.
  defp authorize_receiver(policy, action, ctx) do
    caller = Map.get(ctx, :caller)

    if authorized_receiver?(action, caller, policy) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp authorized_receiver?(:provision_workspace, caller, policy),
    do: caller == policy.grantee_uri

  defp authorized_receiver?(:cleanup_workspace, caller, policy),
    do: caller == policy.grantee_uri

  defp authorized_receiver?(:collect_workspace_changes, caller, policy),
    do: caller == policy.grantee_uri

  defp authorized_receiver?(_action, caller, policy), do: caller == policy.grantee_uri

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

  defp invoke_workspace(implementation, :prepare, request),
    do: implementation.prepare(request)

  defp invoke_workspace(implementation, :cleanup, request),
    do: implementation.cleanup(request)

  defp provision_id(workspace_uri, task_uri, generation) do
    :sha256
    |> :crypto.hash([
      URI.to_string(workspace_uri),
      <<0>>,
      URI.to_string(task_uri),
      <<0>>,
      Integer.to_string(generation)
    ])
    |> Base.encode16(case: :lower)
  end
end
