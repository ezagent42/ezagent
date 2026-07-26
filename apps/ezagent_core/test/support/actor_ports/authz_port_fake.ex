defmodule Ezagent.Kind.Ports.AuthzPortFake do
  @moduledoc """
  Strict no-op `:test` fake for `Ezagent.Kind.Ports.AuthzPort` — lets the
  actor framework's own suite run spine-free (§3.4). Core's suite wires the
  real `Ezagent.Kind.Adapters.AuthzAdapter`; this fake is for the future
  `ezagent_actor` app's test env.
  """

  @behaviour Ezagent.Kind.Ports.AuthzPort

  @impl true
  def authorize_dispatch(_kind_module, _behavior_module, _action, _target, _holder, _ctx),
    do: {:ok, nil}

  @impl true
  def authorize_and_issue_grant(_kind_module, _target, _origin, _ctx, _grantee, _cap),
    do: {:error, :invalid_artifact}

  @impl true
  def data_owner_of(_behavior, _instance), do: :no_owner

  @impl true
  def holds_cap?(_kind_module, _entity_uri, _needed), do: false

  @impl true
  def default_holds_cap?(_entity_uri, _needed), do: false
end
