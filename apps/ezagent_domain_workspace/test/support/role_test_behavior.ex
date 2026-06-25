defmodule Ezagent.Workspace.RoleTestBehavior do
  @moduledoc false
  # RF-5a test-only Behavior: a real new-style Behavior that is NOT in
  # `Ezagent.Entity.Agent.behaviors/0` (the generic host declares nothing
  # role-specific). It proves the keystone: a recipe-loaded UNDECLARED behavior
  # (1) materializes its slice via RF-1's generalized `init_set`, (2) dispatches
  # via per-instance resolution, and (3) is still cap-gated. Its `:ping` action
  # uses the `:agent` cap kind so a minted role cap (kind `:agent`) authorizes it.
  use Ezagent.Lifecycle, state_slice: :role_test

  action(:ping,
    args: %{},
    returns: %{pong: :boolean},
    caps: [:ping],
    modes: [:call],
    description: "test-only role behavior action for RF-5a (recipe-loaded, undeclared)"
  )

  # Override the macro-derived `:any` kind so the cap subject is `:agent` —
  # symmetric to `Ezagent.Behavior.Sandbox.required_caps/0`. A role recipe that
  # requests `%{behavior: __MODULE__, action: :ping}` mints a cap on the `:agent`
  # kind axis, which this `required_caps` then matches at dispatch.
  def required_caps do
    %{ping: Ezagent.Capability.cap(:agent, __MODULE__, :ping)}
  end

  # Per-entity ownership — the agent owns its own role_test slice.
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{pinged: false}}

  def handle_ping(_args, _ctx) do
    {:ok, %{pong: true}, [{:set, :pinged, true}]}
  end
end
