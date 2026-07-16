defmodule Ezagent.DomainGit.TestSupport.GitEffectProbe do
  @moduledoc false

  use Agent

  def start_link(owner) do
    Agent.start_link(fn -> %{owner: owner, ref: make_ref(), block?: false} end, name: __MODULE__)
  end

  def ref, do: Agent.get(__MODULE__, & &1.ref)
  def block_next, do: Agent.update(__MODULE__, &%{&1 | block?: true})

  def trip(operation, context) do
    %{owner: owner, ref: ref, block?: block?} = Agent.get(__MODULE__, & &1)

    Enum.each([:adapter, :http, :secret, :filesystem], fn sentinel ->
      send(owner, {:git_probe, ref, sentinel, operation, context})
    end)

    if block? do
      Agent.update(__MODULE__, &%{&1 | block?: false})
      send(owner, {:git_probe, ref, :callback_waiting, self()})

      receive do
        {:git_probe_release, ^ref} -> :ok
      end
    else
      :ok
    end
  end

  def mutation(operation) do
    %{owner: owner, ref: ref} = Agent.get(__MODULE__, & &1)
    send(owner, {:git_probe, ref, :mutation, operation})
    :ok
  end
end
