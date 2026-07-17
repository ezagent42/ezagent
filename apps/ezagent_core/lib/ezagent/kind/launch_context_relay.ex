defmodule Ezagent.Kind.LaunchContextRelay do
  @moduledoc false
  use GenServer

  def issue(context) do
    {:ok, relay} = GenServer.start(__MODULE__, {context, self()})
    relay
  end

  def take(relay), do: safe_call(relay, :take, {:error, :launch_context_lost})
  def commit(relay, child), do: safe_call(relay, {:commit, child}, :ok)
  def discard(relay), do: safe_call(relay, :discard, :ok)
  def force_discard(relay), do: safe_call(relay, :force_discard, :ok)

  @impl true
  def init({context, issuer}), do: {:ok, {:pending, context, issuer, Process.monitor(issuer)}}

  @impl true
  def handle_call(:take, {child, _}, {:pending, context, issuer, issuer_ref}) do
    {:reply, {:ok, context},
     {:taken, issuer, issuer_ref, child, Process.monitor(child), false, false}}
  end

  def handle_call(:take, {child, _}, {:taken, _issuer, issuer_ref, _old, old_ref, _, _}) do
    Process.demonitor(issuer_ref, [:flush])
    Process.demonitor(old_ref, [:flush])
    {:reply, :consumed, {:committed, child, Process.monitor(child)}}
  end

  def handle_call(:take, {child, _}, {:committed, nil, nil}),
    do: {:reply, :consumed, {:committed, child, Process.monitor(child)}}

  def handle_call(:take, {child, _}, {:committed, old, old_ref}) do
    if child != old, do: Process.demonitor(old_ref, [:flush])
    ref = if child == old, do: old_ref, else: Process.monitor(child)
    {:reply, :consumed, {:committed, child, ref}}
  end

  def handle_call(
        {:commit, child},
        {issuer, _},
        {:taken, issuer, issuer_ref, child, child_ref, _, _}
      ) do
    Process.demonitor(issuer_ref, [:flush])
    {:reply, :ok, {:committed, child, child_ref}}
  end

  def handle_call({:commit, _}, _from, state), do: {:reply, :ok, state}
  def handle_call(:discard, _from, {:committed, _, _} = state), do: {:reply, :ok, state}
  def handle_call(:discard, _from, state), do: {:stop, :normal, :ok, state}
  def handle_call(:force_discard, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, issuer, _}, {:pending, _, issuer, ref}),
    do: {:stop, :normal, :issuer_down}

  def handle_info(
        {:DOWN, ref, :process, issuer, _},
        {:taken, issuer, ref, child, child_ref, down?, false}
      ),
      do: taken_transition(down?, true, issuer, ref, child, child_ref)

  def handle_info(
        {:DOWN, ref, :process, child, _},
        {:taken, issuer, issuer_ref, child, ref, false, down?}
      ),
      do: taken_transition(true, down?, issuer, issuer_ref, child, ref)

  def handle_info({:DOWN, ref, :process, child, _}, {:committed, child, ref}),
    do: {:noreply, {:committed, nil, nil}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(_), do: %{state: :redacted}

  defp taken_transition(true, true, _, _, _, _), do: {:stop, :normal, :abandoned}

  defp taken_transition(cd, id, issuer, ir, child, cr),
    do: {:noreply, {:taken, issuer, ir, child, cr, cd, id}}

  defp safe_call(relay, message, fallback) do
    GenServer.call(relay, message)
  catch
    :exit, _ -> fallback
  end
end
