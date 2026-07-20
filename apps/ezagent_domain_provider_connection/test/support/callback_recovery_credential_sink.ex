Code.require_file(Path.expand("refresh_exchange_backend_support.ex", __DIR__))

defmodule Ezagent.ProviderConnection.Test.CallbackRecoveryCredentialSink do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @impl true
  def store(command), do: apply_effect(:store, command)

  @impl true
  def replace(command), do: apply_effect(:replace, command)

  defp apply_effect(
         kind,
         %{credential_material: material, correlation_id: correlation_id} = command
       ) do
    owner = Application.fetch_env!(:ezagent_domain_provider_connection, :task7_test_owner)
    state = Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)

    {result, block_response?, hook} =
      Agent.get_and_update(state, fn state ->
        canonical_digest =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(Map.delete(command, :credential_material))
          )

        {result, results, logical_effects, effects} =
          case Map.fetch(state.results, correlation_id) do
            {:ok, result} ->
              if Map.get(state.canonical_digests, correlation_id) == canonical_digest,
                do: {result, state.results, state.logical_effects, state.effects},
                else: {:correlation_conflict, state.results, state.logical_effects, state.effects}

            :error ->
              result = %{
                credential_ref: "credential-ref-#{map_size(state.results) + 1}",
                credential_version: map_size(state.results) + 1
              }

              effect = %{kind: kind, command: Map.delete(command, :credential_material)}

              {result, Map.put(state.results, correlation_id, result), state.logical_effects + 1,
               [effect | state.effects]}
          end

        next = %{
          state
          | results: results,
            canonical_digests:
              Map.put_new(state.canonical_digests, correlation_id, canonical_digest),
            logical_effects: logical_effects,
            effects: effects,
            invocations: state.invocations + 1,
            block_once?: false,
            hook: nil
        }

        {{result, state.block_once?, state.hook}, next}
      end)

    if result == :correlation_conflict do
      {:error, :correlation_conflict}
    else
      send(owner, {:credential_effect, kind, material, correlation_id})
      if is_function(hook, 1), do: hook.(command)

      if block_response? do
        send(owner, {:credential_committed_without_response, self(), correlation_id, result})

        receive do
          :return_credential_response -> {:ok, result}
        end
      else
        {:ok, result}
      end
    end
  end

  @impl true
  def status(command), do: {:ok, command}

  @impl true
  def lease_for_operation(command), do: {:ok, command}

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def begin_refresh_exchange(command),
    do: Ezagent.ProviderConnection.Test.RefreshExchangeBackendSupport.begin(__MODULE__, command)

  @impl true
  def consume_refresh_exchange(command),
    do: Ezagent.ProviderConnection.Test.RefreshExchangeBackendSupport.consume(__MODULE__, command)

  @impl true
  def revoke(command) do
    state = Application.fetch_env!(:ezagent_domain_provider_connection, :task7_credential_state)
    Agent.update(state, &update_in(&1.revocations, fn calls -> [command | calls] end))
    :ok
  end
end
