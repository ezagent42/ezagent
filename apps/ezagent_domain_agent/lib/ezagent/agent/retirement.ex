defmodule Ezagent.Agent.Retirement do
  @moduledoc "Authorized and transaction-provenanced Agent retirement."

  alias Ezagent.Invocation

  @required_context_keys [
    :caller,
    :caps,
    :workspace_uri,
    :provenance_root,
    :creation_attempt_id,
    :created_agent_uris,
    :reason
  ]

  @type report :: %{
          required(:termination) => :destroyed | :not_destroyed,
          optional(:cleanup) => :complete | :pending,
          optional(:reason) => term(),
          optional(:failures) => [term()]
        }

  @spec retire(URI.t(), map()) :: {:ok, report()} | {:partial, report()} | {:error, report()}
  def retire(%URI{} = agent_uri, context) when is_map(context) do
    with :ok <- validate_context(context),
         :ok <- validate_agent_target(agent_uri),
         :ok <- validate_workspace(agent_uri, context.workspace_uri),
         :ok <- validate_creation_inventory(agent_uri, context.created_agent_uris),
         :ok <- validate_provenance(agent_uri, context.provenance_root) do
      dispatch_destroy(agent_uri, context)
    else
      {:error, reason} -> {:error, %{termination: :not_destroyed, reason: reason}}
    end
  end

  def retire(_agent_uri, _context),
    do: {:error, %{termination: :not_destroyed, reason: :invalid_retirement_context}}

  defp validate_context(context) do
    if Enum.all?(@required_context_keys, &Map.has_key?(context, &1)) and
         match?(%URI{}, context.caller) and match?(%URI{}, context.workspace_uri) and
         match?(%URI{}, context.provenance_root) and is_binary(context.creation_attempt_id) and
         context.creation_attempt_id != "" and is_list(context.created_agent_uris) and
         (match?(%MapSet{}, context.caps) or is_list(context.caps)) do
      :ok
    else
      {:error, :invalid_retirement_context}
    end
  end

  defp validate_agent_target(agent_uri) do
    if Ezagent.URI.scheme?(agent_uri, :entity) and Ezagent.URI.type?(agent_uri, :agent),
      do: :ok,
      else: {:error, :invalid_agent_target}
  end

  defp validate_workspace(agent_uri, workspace_uri) do
    if same_uri?(Ezagent.URI.workspace_of(agent_uri), workspace_uri),
      do: :ok,
      else: {:error, :workspace_mismatch}
  end

  defp validate_creation_inventory(agent_uri, created_agent_uris) do
    if Enum.any?(created_agent_uris, &match_uri?(&1, agent_uri)),
      do: :ok,
      else: {:error, :creation_attempt_mismatch}
  end

  defp validate_provenance(agent_uri, provenance_root) do
    if Ezagent.AgentLineage.spawned_in_lineage?(agent_uri, provenance_root),
      do: :ok,
      else: {:error, :provenance_mismatch}
  end

  defp dispatch_destroy(agent_uri, context) do
    result =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(agent_uri, :sandbox, :destroy),
        mode: :call,
        args: %{},
        ctx: %{
          caller: context.caller,
          caps: context.caps,
          reply: {:caller_inbox, self()}
        }
      })

    interpret_destroy_result(result)
  end

  defp interpret_destroy_result({:ok, %{destroyed: true, cleanup: :ok}}),
    do: {:ok, %{termination: :destroyed, cleanup: :complete}}

  defp interpret_destroy_result({:ok, %{destroyed: true, cleanup: {:error, reason}}}),
    do: {:partial, %{termination: :destroyed, cleanup: :pending, failures: [reason]}}

  defp interpret_destroy_result({:ok, %{destroyed: true}}),
    do: {:ok, %{termination: :destroyed, cleanup: :complete}}

  defp interpret_destroy_result({:error, reason}),
    do: {:error, %{termination: :not_destroyed, reason: reason}}

  defp interpret_destroy_result(other),
    do: {:error, %{termination: :not_destroyed, reason: {:unexpected_destroy_result, other}}}

  defp match_uri?(%URI{} = left, %URI{} = right), do: same_uri?(left, right)
  defp match_uri?(left, %URI{} = right) when is_binary(left), do: left == URI.to_string(right)
  defp match_uri?(_left, _right), do: false

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
