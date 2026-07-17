defmodule Ezagent.Kind.LaunchContextRelay do
  @moduledoc false

  use GenServer

  def issue(context) do
    {:ok, relay} = GenServer.start(__MODULE__, {context, self()})
    relay
  end

  def take(relay) when is_pid(relay), do: safe_call(relay, :take, {:error, :launch_context_lost})
  def discard(relay) when is_pid(relay), do: safe_call(relay, :discard, :ok)
  def commit(relay) when is_pid(relay), do: GenServer.call(relay, :commit)
  def force_discard(relay) when is_pid(relay), do: safe_call(relay, :force_discard, :ok)

  @impl true
  def init({context, issuer}), do: {:ok, {:pending, context, Process.monitor(issuer)}}

  @impl true
  def handle_call(:take, {kind_pid, _tag}, {:pending, context, issuer_ref}) do
    Process.demonitor(issuer_ref, [:flush])
    {:reply, {:ok, context}, {:taken, kind_pid, Process.monitor(kind_pid)}}
  end

  def handle_call(:take, {kind_pid, _tag}, {:committed, nil, nil}) do
    {:reply, :consumed, {:committed, kind_pid, Process.monitor(kind_pid)}}
  end

  def handle_call(:take, {kind_pid, _tag}, {:committed, old_kind_pid, old_kind_ref}) do
    if kind_pid != old_kind_pid, do: Process.demonitor(old_kind_ref, [:flush])
    kind_ref = if kind_pid == old_kind_pid, do: old_kind_ref, else: Process.monitor(kind_pid)
    {:reply, :consumed, {:committed, kind_pid, kind_ref}}
  end

  def handle_call(:commit, {kind_pid, _tag}, {:taken, kind_pid, kind_ref}) do
    {:reply, :ok, {:committed, kind_pid, kind_ref}}
  end

  def handle_call(:commit, _from, state), do: {:reply, :ok, state}

  def handle_call(:discard, _from, {:pending, _context, issuer_ref}) do
    Process.demonitor(issuer_ref, [:flush])
    {:stop, :normal, :ok, :discarded}
  end

  def handle_call(:discard, _from, {:taken, _kind_pid, kind_ref}) do
    Process.demonitor(kind_ref, [:flush])
    {:stop, :normal, :ok, :discarded}
  end

  def handle_call(:discard, _from, state), do: {:reply, :ok, state}
  def handle_call(:force_discard, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, issuer_ref, :process, _issuer, _reason}, {:pending, _, issuer_ref}) do
    {:stop, :normal, :abandoned}
  end

  def handle_info({:DOWN, kind_ref, :process, kind_pid, _reason}, {:taken, kind_pid, kind_ref}) do
    {:stop, :normal, :abandoned}
  end

  def handle_info(
        {:DOWN, kind_ref, :process, kind_pid, _reason},
        {:committed, kind_pid, kind_ref}
      ) do
    {:noreply, {:committed, nil, nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(_status), do: %{state: :redacted}

  defp safe_call(relay, message, fallback) do
    GenServer.call(relay, message)
  catch
    :exit, _reason -> fallback
  end
end
