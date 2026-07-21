defmodule Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority do
  @moduledoc false

  use GenServer

  @doc false
  def start(owner, binding_digest) when is_pid(owner) and is_binary(binding_digest) do
    GenServer.start(__MODULE__, {owner, binding_digest})
  end

  @doc false
  def claim(authority, token, binding_digest) when is_pid(authority) do
    GenServer.call(authority, {:claim, token, binding_digest})
  catch
    :exit, _reason -> {:error, :correlation_conflict}
  end

  @doc false
  def consume_claim(authority, token, binding_digest, proof) when is_pid(authority) do
    GenServer.call(authority, {:consume_claim, token, binding_digest, proof})
  catch
    :exit, _reason -> {:error, :correlation_conflict}
  end

  @doc false
  def validate_claim(authority, token, binding_digest, proof) when is_pid(authority) do
    GenServer.call(authority, {:validate_claim, token, binding_digest, proof})
  catch
    :exit, _reason -> {:error, :correlation_conflict}
  end

  @doc false
  def invalidate(authority) when is_pid(authority) do
    GenServer.cast(authority, :invalidate)
  end

  @impl true
  def init({owner, binding_digest}) do
    monitor = Process.monitor(owner)
    token = make_ref()

    {:ok,
     %{
       owner: owner,
       monitor: monitor,
       binding_digest: binding_digest,
       token: token,
       claimed?: false,
       claim_proof: nil,
       consumed?: false
     }}
  end

  @impl true
  def handle_call(:open, {owner, _tag}, %{owner: owner, claimed?: false} = state) do
    {:reply, {:ok, state.token}, state}
  end

  def handle_call(:open, _from, state), do: {:reply, {:error, :correlation_conflict}, state}

  def handle_call(
        {:claim, token, binding_digest},
        {owner, _tag},
        %{owner: owner, token: token, binding_digest: binding_digest, claimed?: false} = state
      ) do
    proof = make_ref()
    {:reply, {:ok, proof}, %{state | claimed?: true, claim_proof: proof}}
  end

  def handle_call({:claim, _token, _digest}, _from, state),
    do: {:reply, {:error, :correlation_conflict}, state}

  def handle_call(
        {:consume_claim, token, binding_digest, proof},
        _from,
        %{
          token: token,
          binding_digest: binding_digest,
          claim_proof: proof,
          claimed?: true,
          consumed?: false
        } = state
      )
      when is_reference(proof) do
    {:reply, :ok, %{state | consumed?: true}}
  end

  def handle_call({:consume_claim, _token, _digest, _proof}, _from, state),
    do: {:reply, {:error, :correlation_conflict}, state}

  def handle_call(
        {:validate_claim, token, binding_digest, proof},
        _from,
        %{
          token: token,
          binding_digest: binding_digest,
          claim_proof: proof,
          claimed?: true,
          consumed?: true
        } = state
      )
      when is_reference(proof),
      do: {:reply, :ok, state}

  def handle_call({:validate_claim, _token, _digest, _proof}, _from, state),
    do: {:reply, {:error, :correlation_conflict}, state}

  @impl true
  def handle_cast(:invalidate, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{monitor: monitor, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  @doc false
  def open(authority), do: GenServer.call(authority, :open)
end
