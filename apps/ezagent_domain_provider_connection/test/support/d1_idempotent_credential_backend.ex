defmodule Ezagent.ProviderConnection.Test.D1IdempotentCredentialBackend do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @state_key :d1_idempotent_credential_backend_state

  def new_state do
    %{
      invocations: [],
      logical_effects: MapSet.new(),
      barrier: nil,
      fail_after_effect_once?: false,
      failed_keys: MapSet.new(),
      missing_idempotency_keys: 0
    }
  end

  def put_barrier(state, owner), do: Agent.update(state, &%{&1 | barrier: owner})

  def fail_after_effect_once(state),
    do: Agent.update(state, &%{&1 | fail_after_effect_once?: true})

  def snapshot(state), do: Agent.get(state, & &1)

  @impl true
  def store(_command), do: {:error, :credential_conflict}

  @impl true
  def replace(_command), do: {:error, :credential_conflict}

  @impl true
  def status(command), do: {:ok, command}

  @impl true
  def lease_for_operation(command), do: {:ok, command}

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def revoke(command) do
    state = Application.fetch_env!(:ezagent_domain_provider_connection, @state_key)

    case Map.fetch(command, :idempotency_key) do
      {:ok, key} -> revoke_once(state, key, command)
      :error -> record_missing_key(state, command)
    end
  end

  defp revoke_once(state, key, command) do
    {reply, barrier} =
      Agent.get_and_update(state, fn current ->
        first_effect? = not MapSet.member?(current.logical_effects, key)
        fail? = first_effect? and current.fail_after_effect_once?

        next = %{
          current
          | invocations: [command | current.invocations],
            logical_effects: MapSet.put(current.logical_effects, key),
            failed_keys:
              if(fail?, do: MapSet.put(current.failed_keys, key), else: current.failed_keys)
        }

        reply = if fail?, do: {:error, :backend_unavailable}, else: :ok
        barrier = if first_effect? and not fail?, do: current.barrier
        {{reply, barrier}, next}
      end)

    maybe_barrier(barrier, command)
    reply
  end

  defp record_missing_key(state, command) do
    Agent.update(state, fn current ->
      %{
        current
        | invocations: [command | current.invocations],
          missing_idempotency_keys: current.missing_idempotency_keys + 1
      }
    end)

    {:error, :credential_conflict}
  end

  defp maybe_barrier(nil, _command), do: :ok

  defp maybe_barrier(owner, command) do
    send(owner, {:d1_revoke_effect, self(), command})

    receive do
      :release_d1_revoke -> :ok
    end
  end
end
