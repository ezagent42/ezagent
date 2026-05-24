defmodule EzagentPluginEmConforming.GoodAdapter do
  @moduledoc "Valid Adapter for the positive-control fixture."
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "em_conforming"

  @impl true
  def display_name, do: "EM Conforming"

  @impl true
  def description, do: "Positive control adapter for PR-EM-1 gate."

  @impl true
  def binding_module, do: EzagentPluginEmConforming.GoodBinding
end

defmodule EzagentPluginEmConforming.GoodBinding do
  @moduledoc "Valid Binding for the positive-control fixture."
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: EzagentPluginEmConforming.GoodAdapter
end

defmodule EzagentPluginEmConforming do
  @moduledoc """
  A CONFORMING plugin declaring one valid ExternalMirror
  `{adapter, binding}` pair — positive control for the PR-EM-1
  Grill-5 compiler gate.
  """
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "em-conforming",
      name: "EM Conforming Fixture",
      description: "Positive control for the ExternalMirror Grill-5 gate.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters do
    [{EzagentPluginEmConforming.GoodAdapter, EzagentPluginEmConforming.GoodBinding}]
  end
end
