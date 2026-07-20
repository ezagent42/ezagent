defmodule Ezagent.ActionSet.ProviderConnection do
  @moduledoc """
  Stateless, registry-only owner command boundary for provider connections.

  In D1, begin, callback consumption, refresh, and read are production-reachable.
  Reauthorize, revoke, and disconnect remain registered closed protocols but are
  intentionally production-unavailable until a trusted-session assurance
  authority is approved and implemented.
  """

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
    args:
      {:closed_map,
       %{
         connection_id: :string,
         provider_id: :string,
         governed_host: :string,
         acquisition_method: :string,
         requested_execution_identity_class: :string,
         requested_permissions_digest: :string,
         redirect_uri_id: :string,
         correlation_id: :string,
         callback_artifact: {:struct, Ezagent.Capability}
       }},
    returns: %{attempt_ref: :string, authorization_url: :string, expires_at: :string},
    caps: [{:begin_authorization, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Begin an owner-scoped provider authorization attempt."
  )

  action(:consume_callback,
    args: {:closed_map, %{attempt_ref: :string, correlation_id: :string}},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:consume_callback, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Consume an owner-scoped provider authorization callback."
  )

  action(:reauthorize,
    args:
      {:closed_map,
       %{
         connection_id: :string,
         expected_version: :integer,
         requested_execution_identity_class: :string,
         requested_permissions_digest: :string,
         redirect_uri_id: :string,
         correlation_id: :string,
         callback_artifact: {:struct, Ezagent.Capability},
         assurance: {:struct, Ezagent.ProviderConnection.Assurance}
       }},
    returns: %{attempt_ref: :string, authorization_url: :string, expires_at: :string},
    caps: [{:reauthorize, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Deferred in D1: reauthorize after trusted-session assurance."
  )

  action(:refresh,
    args:
      {:closed_map,
       %{connection_id: :string, expected_version: :integer, correlation_id: :string}},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:refresh, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Refresh an owner-scoped provider connection."
  )

  action(:revoke,
    args:
      {:closed_map,
       %{
         connection_id: :string,
         expected_version: :integer,
         assurance: {:struct, Ezagent.ProviderConnection.Assurance}
       }},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:revoke, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Deferred in D1: revoke after trusted-session assurance."
  )

  action(:disconnect,
    args:
      {:closed_map,
       %{
         connection_id: :string,
         expected_version: :integer,
         assurance: {:struct, Ezagent.ProviderConnection.Assurance}
       }},
    returns: %{connection_id: :string, status: :string, version: :integer},
    caps: [{:disconnect, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Deferred in D1: disconnect after trusted-session assurance."
  )

  action(:read_connection,
    args: {:closed_map, %{connection_id: :string}},
    returns: %{connection: :map},
    caps: [{:read_connection, kind: :user}],
    data_owner: :self,
    modes: [:call],
    description: "Read an owner-scoped provider connection."
  )

  @spec required_caps() :: %{atom() => Ezagent.Capability.t()}
  @doc "Returns the exact capability required by each provider-connection action."
  @impl Ezagent.ActionSet
  def required_caps,
    do: Map.new(@actions, &{&1, Ezagent.Capability.cap(:user, __MODULE__, &1)})

  @doc false
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc false
  def handle_begin_authorization(args, ctx) do
    with {:ok, command} <- sanitize_command(:begin_authorization, args) do
      case Map.get(command, :callback_artifact) do
        %Ezagent.Capability{} = artifact ->
          with :ok <- validate_callback_artifact(artifact, ctx) do
            invoke_boundary(:begin_authorization, command, ctx)
          end

        nil ->
          {:error, :callback_artifact_required}

        _malformed ->
          {:error, :invalid_callback_artifact}
      end
    end
  end

  @doc false
  def handle_consume_callback(args, ctx), do: handle_command(:consume_callback, args, ctx)
  @doc false
  def handle_refresh(args, ctx), do: handle_command(:refresh, args, ctx)
  @doc false
  def handle_read_connection(args, ctx), do: handle_command(:read_connection, args, ctx)

  @doc false
  def handle_reauthorize(args, ctx) do
    with {:ok, command} <- sanitize_command(:reauthorize, args) do
      case Map.get(command, :callback_artifact) do
        %Ezagent.Capability{} = artifact ->
          with :ok <- validate_callback_artifact(artifact, ctx),
               :ok <- validate_assurance(:reauthorize, command, ctx) do
            invoke_boundary(:reauthorize, command, ctx)
          end

        nil ->
          {:error, :callback_artifact_required}

        _malformed ->
          {:error, :invalid_callback_artifact}
      end
    end
  end

  @doc false
  def handle_revoke(args, ctx), do: handle_destructive(:revoke, args, ctx)

  @doc false
  def handle_disconnect(args, ctx), do: handle_destructive(:disconnect, args, ctx)

  @doc "Returns the owner User URI for a concrete User target; all other shapes fail closed."
  @impl Ezagent.ActionSet
  def data_owner(%URI{} = owner) do
    if Ezagent.URI.scheme?(owner, :entity) and Ezagent.URI.type?(owner, :user),
      do: owner,
      else: :no_owner
  end

  def data_owner(_), do: :no_owner

  defp handle_destructive(action, args, ctx) do
    with {:ok, command} <- sanitize_command(action, args),
         :ok <- validate_assurance(action, command, ctx) do
      invoke_boundary(action, command, ctx)
    end
  end

  defp handle_command(action, args, ctx) do
    with {:ok, command} <- sanitize_command(action, args) do
      invoke_boundary(action, command, ctx)
    end
  end

  defp sanitize_command(action, args) when is_map(args) do
    {:closed_map, schema} = __action_spec__(action).args

    case Ezagent.InterfaceValidator.validate(args, {:closed_map, schema}) do
      :ok -> {:ok, Map.take(args, Map.keys(schema))}
      {:error, _} = error -> error
    end
  end

  defp sanitize_command(_action, _args),
    do: {:error, {:invalid_args, [{[], :expected_map}]}}

  defp validate_callback_artifact(artifact, %{self_uri: owner} = ctx) do
    workspace = Ezagent.Capability.workspace_of(owner)

    with %URI{} <- Map.get(ctx, :caller),
         :ok <- Ezagent.Cap.validate_for_current_target(artifact, owner),
         true <- artifact.kind == :user,
         true <- artifact.behavior == __MODULE__,
         true <- artifact.action == :consume_callback,
         true <- artifact.instance == Ezagent.URI.instance(owner),
         true <- artifact.workspace_uri == workspace,
         true <- artifact.grantee_uri == owner do
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

    with %Ezagent.ProviderConnection.Assurance{} <- assurance,
         :ok <- Ezagent.ProviderConnection.Assurance.validate(assurance),
         true <- assurance.action == action,
         true <- assurance.owner_uri == owner,
         true <- assurance.workspace_uri == workspace,
         true <- assurance.grantee_uri == Map.get(ctx, :caller),
         true <- assurance.connection_id == Map.get(args, :connection_id),
         true <- assurance.connection_version == Map.get(args, :expected_version),
         now = DateTime.utc_now(),
         :ok <- Ezagent.ProviderConnection.Assurance.validate_time(assurance, now),
         verification_context =
           assurance_verification_context(owner, workspace, Map.fetch!(ctx, :caller), args, now),
         :ok <- invoke_session_assurance_verifier(action, assurance, verification_context, ctx) do
      :ok
    else
      nil -> {:error, :assurance_required}
      false -> {:error, :invalid_assurance_coordinates}
      {:error, _} = error -> error
      _ -> {:error, :invalid_assurance}
    end
  end

  defp assurance_verification_context(owner, workspace, grantee, args, now) do
    %{
      owner_uri: owner,
      workspace_uri: workspace,
      grantee_uri: grantee,
      connection_id: Map.fetch!(args, :connection_id),
      connection_version: Map.fetch!(args, :expected_version),
      verified_at: now
    }
  end

  if Mix.env() == :test do
    defp invoke_session_assurance_verifier(
           action,
           assurance,
           verification_context,
           %{test_session_assurance_verifier: {verifier, verifier_state}}
         ) do
      Ezagent.ProviderConnection.SessionAssuranceVerifier.verify_and_consume(
        verifier,
        verifier_state,
        action,
        assurance,
        verification_context
      )
    end

    defp invoke_session_assurance_verifier(action, assurance, verification_context, _ctx) do
      Ezagent.ProviderConnection.UnavailableSessionAssuranceVerifier.verify_and_consume(
        action,
        assurance,
        verification_context
      )
    end
  else
    defp invoke_session_assurance_verifier(action, assurance, verification_context, _ctx) do
      Ezagent.ProviderConnection.UnavailableSessionAssuranceVerifier.verify_and_consume(
        action,
        assurance,
        verification_context
      )
    end
  end

  defp invoke_boundary(action, args, ctx) do
    case Application.get_env(:ezagent_domain_provider_connection, :command_boundary) do
      fun when is_function(fun, 3) -> fun.(action, args, ctx)
      module when is_atom(module) and not is_nil(module) -> module.execute(action, args, ctx)
      nil -> Ezagent.ProviderConnection.Store.execute(action, args, ctx)
    end
  end
end
