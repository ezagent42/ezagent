defmodule Ezagent.Kind.Ports.DispatchPolicyPortFake do
  @moduledoc """
  Strict no-op `:test` fake for `Ezagent.Kind.Ports.DispatchPolicyPort` —
  lets the actor framework's own suite run spine-free (§3.4). Core's suite
  wires the real `Ezagent.Kind.Adapters.DispatchPolicyAdapter`; this fake is
  for the future `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.DispatchPolicyPort

  @impl true
  def before_delivery(inv), do: {:ok, inv}

  @impl true
  def validate_origin(_origin, _ctx), do: :ok

  @impl true
  def assert_local_owner(_uri, _tag), do: :ok
end
