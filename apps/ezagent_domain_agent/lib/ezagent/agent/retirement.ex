defmodule Ezagent.Agent.Retirement do
  @moduledoc "Authorized and transaction-provenanced Agent retirement."

  alias Ezagent.Invocation
  alias Ezagent.Agent.RetirementObligations

  @required_context_keys [
    :caller,
    :authenticated_principal,
    :caps,
    :workspace_uri,
    :provenance_root,
    :creation_attempt_id,
    :reason
  ]

  @type report :: %{
          required(:termination) => :destroyed | :not_destroyed,
          optional(:cleanup) => :complete | :pending,
          optional(:reason) => term(),
          optional(:failures) => [term()]
        }

  @spec retire(URI.t(), map()) :: {:ok, report()} | {:partial, report()} | {:error, report()}
  @doc false
  def retire(%URI{} = agent_uri, context) when is_map(context) do
    with :ok <- validate_context(context),
         :ok <- validate_agent_target(agent_uri),
         :ok <- validate_workspace(agent_uri, context.workspace_uri),
         :ok <- validate_creation_inventory(agent_uri, context),
         :ok <- validate_provenance(agent_uri, context.provenance_root),
         {:ok, obligation} <- persist_obligation(agent_uri, context) do
      if obligation.status == :resolved,
        do: {:ok, %{termination: :destroyed, cleanup: :complete, idempotent: true}},
        else: dispatch_destroy(agent_uri, context, obligation)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         %{termination: :not_destroyed, reason: {:obligation_persist_failed, changeset.errors}}}

      {:error, reason} ->
        {:error, %{termination: :not_destroyed, reason: reason}}
    end
  end

  def retire(_agent_uri, _context),
    do: {:error, %{termination: :not_destroyed, reason: :invalid_retirement_context}}

  defp validate_context(context) do
    if Enum.all?(@required_context_keys, &Map.has_key?(context, &1)) and
         match?(%URI{}, context.caller) and match?(%URI{}, context.workspace_uri) and
         match?(%URI{}, context.authenticated_principal) and
         match?(%URI{}, context.provenance_root) and is_binary(context.creation_attempt_id) and
         context.creation_attempt_id != "" and
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

  defp validate_creation_inventory(agent_uri, context) do
    if Ezagent.Agent.CreationInventory.member?(
         context.creation_attempt_id,
         agent_uri,
         context.provenance_root,
         context.workspace_uri
       ),
       do: :ok,
       else: {:error, :creation_attempt_mismatch}
  end

  defp validate_provenance(agent_uri, provenance_root) do
    if Ezagent.AgentLineage.spawned_in_lineage?(agent_uri, provenance_root),
      do: :ok,
      else: {:error, :provenance_mismatch}
  end

  defp persist_obligation(agent_uri, context) do
    RetirementObligations.create_pending(%{
      agent_uri: URI.to_string(agent_uri),
      workspace_uri: URI.to_string(context.workspace_uri),
      provenance_root_uri: URI.to_string(context.provenance_root),
      creation_attempt_id: context.creation_attempt_id,
      retirement_reason: inspect(context.reason),
      pending_steps: retirement_steps(agent_uri, context.caller)
    })
  end

  defp retirement_steps(agent_uri, caller_uri) do
    agent_uri_string = URI.to_string(agent_uri)
    caller_uri_string = URI.to_string(caller_uri)

    termination = %{
      "sandbox_destroy" => %{
        "agent_uri" => agent_uri_string,
        "caller_uri" => caller_uri_string
      }
    }

    cleanup =
      case Ezagent.ActionSet.Sandbox.read_persisted_state(agent_uri) do
        %{config_dir_path: path, template_class: template_class}
        when is_binary(path) and not is_nil(template_class) ->
          %{
            "sandbox_cleanup" => %{
              "config_dir_path" => path,
              "template_class" => inspect(template_class)
            }
          }

        _ ->
          %{}
      end

    Map.merge(termination, cleanup)
  end

  defp dispatch_destroy(agent_uri, context, obligation) do
    result =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(agent_uri, :sandbox, :destroy),
        mode: :call,
        args: %{},
        ctx: %{
          caller: context.caller,
          authenticated_principal: context.authenticated_principal,
          caps: context.caps,
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })

    interpret_destroy_result(result, obligation)
  end

  defp interpret_destroy_result({:ok, %{destroyed: true, cleanup: :ok}}, obligation) do
    resolve_complete(obligation)
  end

  defp interpret_destroy_result(
         {:ok, %{destroyed: true, cleanup: {:error, reason}}},
         obligation
       ) do
    cleanup_steps = Map.delete(obligation.pending_steps, "sandbox_destroy")
    _ = RetirementObligations.update_pending_steps(obligation.id, cleanup_steps)
    _ = RetirementObligations.record_failure(obligation.id, reason)

    {:partial,
     %{
       termination: :destroyed,
       cleanup: :pending,
       obligation_id: obligation.id,
       failures: [reason]
     }}
  end

  defp interpret_destroy_result({:ok, %{destroyed: true}}, obligation),
    do: resolve_complete(obligation)

  defp interpret_destroy_result({:error, reason}, obligation)
       when reason in [:unauthorized, :missing_cap, :identity_read_unavailable] do
    _ = RetirementObligations.resolve(obligation.id)
    {:error, %{termination: :not_destroyed, reason: reason}}
  end

  defp interpret_destroy_result({:error, :no_such_actor}, obligation) do
    remaining = Map.delete(obligation.pending_steps, "sandbox_destroy")

    if map_size(remaining) == 0 do
      resolve_complete(obligation)
    else
      _ = RetirementObligations.update_pending_steps(obligation.id, remaining)

      {:partial,
       %{
         termination: :destroyed,
         cleanup: :pending,
         obligation_id: obligation.id,
         failures: [:termination_already_absent]
       }}
    end
  end

  defp interpret_destroy_result({:error, reason}, obligation) do
    {:error,
     %{
       termination: :unknown,
       cleanup: :pending,
       obligation_id: obligation.id,
       reason: reason
     }}
  end

  defp interpret_destroy_result(other, obligation) do
    {:error,
     %{
       termination: :unknown,
       cleanup: :pending,
       obligation_id: obligation.id,
       reason: {:unexpected_destroy_result, other}
     }}
  end

  defp resolve_complete(obligation) do
    case RetirementObligations.resolve(obligation.id) do
      {:ok, _resolved} ->
        {:ok, %{termination: :destroyed, cleanup: :complete}}

      {:error, reason} ->
        {:partial,
         %{
           termination: :destroyed,
           cleanup: :pending,
           obligation_id: obligation.id,
           failures: [{:obligation_resolve_failed, reason}]
         }}
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
