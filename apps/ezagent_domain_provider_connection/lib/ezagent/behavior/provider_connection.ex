defmodule Ezagent.ActionSet.ProviderConnection do
  @moduledoc """
  Stateless, registry-only owner command boundary for provider connections.

  Durable connection truth belongs to the provider-connection aggregate. This
  Lifecycle contributes no connection state to the owner User snapshot.
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
    args: %{command: :map},
    returns: :map,
    caps: [{:begin_authorization, kind: :user}],
    modes: [:call],
    description: "Begin an owner-scoped provider authorization attempt."
  )

  action(:consume_callback,
    args: %{command: :map},
    returns: :map,
    caps: [{:consume_callback, kind: :user}],
    modes: [:call],
    description: "Consume an owner-scoped provider authorization callback."
  )

  action(:reauthorize,
    args: %{command: :map},
    returns: :map,
    caps: [{:reauthorize, kind: :user}],
    modes: [:call],
    description: "Reauthorize an owner-scoped provider connection."
  )

  action(:refresh,
    args: %{command: :map},
    returns: :map,
    caps: [{:refresh, kind: :user}],
    modes: [:call],
    description: "Refresh an owner-scoped provider connection."
  )

  action(:revoke,
    args: %{command: :map},
    returns: :map,
    caps: [{:revoke, kind: :user}],
    modes: [:call],
    description: "Revoke an owner-scoped provider connection."
  )

  action(:disconnect,
    args: %{command: :map},
    returns: :map,
    caps: [{:disconnect, kind: :user}],
    modes: [:call],
    description: "Disconnect an owner-scoped provider connection."
  )

  action(:read_connection,
    args: %{command: :map},
    returns: :map,
    caps: [{:read_connection, kind: :user}],
    modes: [:call],
    description: "Read an owner-scoped provider connection."
  )

  @spec required_caps() :: %{atom() => Ezagent.Capability.t()}
  def required_caps do
    Map.new(@actions, fn action ->
      {action, Ezagent.Capability.cap(:user, __MODULE__, action)}
    end)
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  for action_name <- @actions do
    handler = String.to_atom("handle_#{action_name}")

    def unquote(handler)(%{command: command}, ctx) when is_map(command) do
      execute(unquote(action_name), command, ctx)
    end
  end

  defp execute(:begin_authorization, command, ctx) do
    with %Ezagent.Capability{} = artifact <- Map.get(command, :callback_artifact),
         %URI{} = receiver <- Map.get(ctx, :self_uri),
         :ok <- Ezagent.Cap.validate_for_current_target(artifact, receiver) do
      invoke_boundary(:begin_authorization, command, ctx)
    else
      nil -> {:error, :callback_artifact_required}
      {:error, _reason} = error -> error
    end
  end

  defp execute(action, command, ctx), do: invoke_boundary(action, command, ctx)

  defp invoke_boundary(action, command, ctx) do
    case Application.get_env(:ezagent_domain_provider_connection, :command_boundary) do
      fun when is_function(fun, 3) -> fun.(action, command, ctx)
      nil -> {:error, :provider_connection_orchestration_not_implemented}
      module when is_atom(module) -> apply(module, :execute, [action, command, ctx])
    end
  end
end
