defmodule Ezagent.ActionSet.ProviderConnection do
  @moduledoc "Stateless, registry-only owner command boundary for provider connections."

  use Ezagent.Lifecycle

  @actions [
    :begin_authorization,
    :consume_callback,
    :reauthorize,
    :refresh,
    :revoke,
    :disconnect,
    :read_connection
  ]

  action(:begin_authorization,
    args: %{
      connection_id: :string,
      provider_id: :string,
      governed_host: :string,
      acquisition_method: :string,
      execution_identity: :string,
      requested_permissions_digest: :string,
      redirect_uri_id: :string,
      correlation_id: :string,
      callback_artifact: :map
    },
    returns: %{attempt_ref: :string, authorization_url: :string, expires_at: :string},
    caps: [{:begin_authorization, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Begin an owner-scoped provider authorization attempt."
  )

  action(:consume_callback,
    args: %{attempt_ref: :string, callback: :map, correlation_id: :string},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:consume_callback, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Consume an owner-scoped provider authorization callback."
  )

  action(:reauthorize,
    args: %{connection_id: :string, expected_version: :integer, assurance: :map},
    returns: %{attempt_ref: :string, authorization_url: :string, expires_at: :string},
    caps: [{:reauthorize, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Reauthorize an owner-scoped provider connection."
  )

  action(:refresh,
    args: %{connection_id: :string, expected_version: :integer, correlation_id: :string},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:refresh, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Refresh an owner-scoped provider connection."
  )

  action(:revoke,
    args: %{connection_id: :string, expected_version: :integer, assurance: :map},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:revoke, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Revoke an owner-scoped provider connection."
  )

  action(:disconnect,
    args: %{connection_id: :string, expected_version: :integer, assurance: :map},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:disconnect, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Disconnect an owner-scoped provider connection."
  )

  action(:read_connection,
    args: %{connection_id: :string},
    returns: %{connection: :map},
    caps: [{:read_connection, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Read an owner-scoped provider connection."
  )

  @spec required_caps() :: %{atom() => Ezagent.Capability.t()}
  def required_caps,
    do: Map.new(@actions, &{&1, Ezagent.Capability.cap(:user, __MODULE__, &1)})

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_begin_authorization(args, ctx) do
    with %Ezagent.Capability{} = artifact <- Map.get(args, :callback_artifact),
         :ok <- validate_callback_artifact(artifact, ctx) do
      invoke_boundary(:begin_authorization, args, ctx)
    else
      nil -> {:error, :callback_artifact_required}
      {:error, _} = error -> error
    end
  end

  def handle_consume_callback(args, ctx), do: invoke_boundary(:consume_callback, args, ctx)
  def handle_refresh(args, ctx), do: invoke_boundary(:refresh, args, ctx)
  def handle_read_connection(args, ctx), do: invoke_boundary(:read_connection, args, ctx)

  for action <- [:reauthorize, :revoke, :disconnect] do
    def unquote(String.to_atom("handle_#{action}"))(args, ctx) do
      with :ok <- validate_assurance(unquote(action), args, ctx) do
        invoke_boundary(unquote(action), args, ctx)
      end
    end
  end

  defp validate_callback_artifact(artifact, %{self_uri: owner} = ctx) do
    workspace = Ezagent.Capability.workspace_of(owner)
    grantee = Map.get(ctx, :caller)

    with %URI{} <- grantee,
         :ok <- Ezagent.Cap.validate_for_current_target(artifact, grantee),
         true <- artifact.kind == :user,
         true <- artifact.behavior == __MODULE__,
         true <- artifact.action == :consume_callback,
         true <- artifact.instance == Ezagent.URI.instance(owner),
         true <- artifact.workspace_uri == workspace,
         true <- artifact.grantee_uri == grantee do
      :ok
    else
      {:error, _} = error -> error
      nil -> {:error, :invalid_callback_artifact_coordinates}
      false -> {:error, :invalid_callback_artifact_coordinates}
    end
  end

  defp validate_assurance(action, args, %{self_uri: owner} = ctx) do
    assurance = Map.get(args, :assurance)
    workspace = Ezagent.Capability.workspace_of(owner)

    with %{} <- assurance,
         true <- Map.get(assurance, :owner_uri) == owner,
         true <- Map.get(assurance, :workspace_uri) == workspace,
         true <- Map.get(assurance, :grantee_uri) == Map.get(ctx, :caller),
         true <- Map.get(assurance, :connection_id) == Map.get(args, :connection_id),
         true <- Map.get(assurance, :connection_version) == Map.get(args, :expected_version),
         attempt_ref when is_binary(attempt_ref) <- Map.get(assurance, :attempt_ref),
         attempt_version when is_integer(attempt_version) and attempt_version >= 0 <-
           Map.get(assurance, :attempt_version),
         :valid <- Map.get(assurance, :status),
         signature when is_binary(signature) and byte_size(signature) > 0 <-
           Map.get(assurance, :signature),
         %DateTime{} = expires_at <- Map.get(assurance, :expires_at),
         :gt <- DateTime.compare(expires_at, DateTime.utc_now()),
         :ok <- invoke_assurance_validator(action, assurance, ctx) do
      :ok
    else
      nil -> {:error, :assurance_required}
      false -> {:error, :invalid_assurance_coordinates}
      {:error, _} = error -> error
      _ -> {:error, :invalid_assurance}
    end
  end

  defp invoke_assurance_validator(action, assurance, ctx) do
    case Application.get_env(:ezagent_domain_provider_connection, :assurance_validator) do
      fun when is_function(fun, 3) ->
        fun.(action, assurance, ctx)

      module when is_atom(module) and not is_nil(module) ->
        module.validate(action, assurance, ctx)

      nil ->
        {:error, :assurance_validation_unavailable}
    end
  end

  defp invoke_boundary(action, args, ctx) do
    case Application.get_env(:ezagent_domain_provider_connection, :command_boundary) do
      fun when is_function(fun, 3) -> fun.(action, args, ctx)
      module when is_atom(module) and not is_nil(module) -> module.execute(action, args, ctx)
      nil -> {:error, :provider_connection_orchestration_not_implemented}
    end
  end
end
