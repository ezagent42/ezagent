defmodule Ezagent.WorkspaceOwnerGate do
  @moduledoc """
  Enforces that workspace-bound runtime work happens on the workspace owner.
  """

  @type operation ::
          {:dispatch, URI.t()}
          | {:spawn, URI.t()}
          | {:session_create, URI.t()}
          | {:session_repair, URI.t()}
          | {:plugin_ingress, term(), term()}
          | {:mcp_join, URI.t()}
          | {:resource_access, URI.t()}
          | term()

  @spec assert_local_owner(URI.t(), operation()) :: :ok | {:error, term()}
  def assert_local_owner(%URI{scheme: "workspace"} = workspace_uri, operation) do
    current = Ezagent.RuntimeIdentity.current()

    case Ezagent.WorkspacePlacement.owner_of(workspace_uri) do
      {:ok, ^current} ->
        :ok

      {:ok, expected} ->
        violation = {:not_workspace_owner, workspace_uri, expected, current, operation}
        handle_violation(workspace_uri, expected, current, operation, violation)

      {:error, _reason} ->
        violation = {:workspace_owner_unknown, workspace_uri, operation}
        handle_violation(workspace_uri, nil, current, operation, violation)
    end
  end

  def assert_local_owner(other, operation) do
    {:error, {:workspace_required, operation, other}}
  end

  @spec assert_local_owner_for_uri(URI.t(), operation()) :: :ok | {:error, term()}
  def assert_local_owner_for_uri(%URI{} = uri, operation) do
    case Ezagent.URI.workspace_of(uri) do
      %URI{} = workspace_uri -> assert_local_owner(workspace_uri, operation)
      :any -> :ok
    end
  end

  defp handle_violation(workspace_uri, expected, current, operation, violation) do
    mode = mode()

    :telemetry.execute(
      [:ezagent, :workspace_owner_gate, :violation],
      %{},
      %{
        workspace_uri: workspace_uri,
        operation: operation,
        mode: mode,
        expected_owner: expected,
        current_runtime: current,
        result: violation
      }
    )

    case mode do
      :observe -> :ok
      :enforce -> {:error, violation}
    end
  end

  defp mode do
    Application.get_env(:ezagent_core, Ezagent.WorkspacePlacement, [])[:mode] || :enforce
  end
end
