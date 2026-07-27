defmodule Ezagent.Kind.Ports.AuthorityPortFake do
  @moduledoc """
  Strict no-op `:test` fake for `Ezagent.Kind.Ports.AuthorityPort` — lets
  the actor framework's own suite run spine-free (§3.4). Core's suite wires
  the real `Ezagent.Kind.Adapters.AuthorityAdapter`; this fake is for the
  future `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.AuthorityPort

  @impl true
  def open(_uri, _kind_type, _freshness), do: {:ok, :fake_authority_token}

  @impl true
  def with_authority(_token, fun), do: fun.()

  @impl true
  def regenesis(_uri, _kind_type, _ctx), do: {:ok, :fake_authority_token}

  @impl true
  def retire(_uri), do: :ok

  @impl true
  def validate_artifact(_artifact, _receiver), do: :ok

  @impl true
  def verify_artifact(_artifact, _presenter), do: true

  @impl true
  def generation(_token), do: 0

  @impl true
  def verified_set(caps, _receiver_uri), do: caps

  @impl true
  def with_runtime_view(_kind_module, _state, fun), do: fun.()
end
