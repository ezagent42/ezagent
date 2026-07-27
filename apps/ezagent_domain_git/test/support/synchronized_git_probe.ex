defmodule Ezagent.DomainGit.TestSupport.SynchronizedGitProbe do
  @moduledoc false

  def call(label, operation, context) do
    owner = owner_from_context(context)
    send(owner, {:task11_adapter_call, label, operation, context})
    owner
  end

  def mutation(owner, label, operation) do
    send(owner, {:task11_provider_mutation, label, operation})
    :ok
  end

  # The idempotency key is `<task_uri>:<generation>:<action>`, and the fixture
  # encodes the test owner pid in the task URI's name segment.
  defp owner_from_context(%{idempotency_key: key}) do
    "owner-" <> encoded = key |> String.split("/") |> List.last()
    [pid, _action] = String.split(encoded, ":", parts: 2)
    [a, b, c] = String.split(pid, "-", parts: 3)
    :erlang.list_to_pid(String.to_charlist("<#{a}.#{b}.#{c}>"))
  end
end
