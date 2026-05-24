defmodule EzagentPluginEmDual.DualModule do
  @moduledoc """
  A single module implementing BOTH Adapter AND Binding behaviours.
  Grill-5 rule (e) — `adapter != binding` — must reject this.
  """
  @behaviour Ezagent.ExternalMirror.Adapter
  @behaviour Ezagent.ExternalMirror.Binding

  @impl Ezagent.ExternalMirror.Adapter
  def adapter_id, do: "em_dual"

  @impl Ezagent.ExternalMirror.Adapter
  def display_name, do: "EM Dual (illegal)"

  @impl Ezagent.ExternalMirror.Adapter
  def description, do: "Dissolves boundary — must fail Grill-5."

  @impl Ezagent.ExternalMirror.Adapter
  def binding_module, do: __MODULE__

  @impl Ezagent.ExternalMirror.Binding
  def adapter_module, do: __MODULE__
end

defmodule EzagentPluginEmDual do
  @moduledoc """
  Non-conforming plugin — adapter and binding are the SAME module.
  Used as the negative test for the PR-EM-1 acceptance: the
  `:ezagent_plugin_check` gate must reject this fixture's build.
  """
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "em-dual",
      name: "EM Dual Fixture",
      description: "Single module implementing both behaviours — illegal.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters do
    [{EzagentPluginEmDual.DualModule, EzagentPluginEmDual.DualModule}]
  end
end
