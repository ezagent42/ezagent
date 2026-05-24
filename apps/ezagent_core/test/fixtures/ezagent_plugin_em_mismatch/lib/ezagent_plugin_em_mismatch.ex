defmodule EzagentPluginEmMismatch.AdapterA do
  @moduledoc "Adapter that claims `BindingA` but the plugin pairs it with `BindingB`."
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "em_mismatch"

  @impl true
  def display_name, do: "EM Mismatch (illegal)"

  @impl true
  def description, do: "Bidirectional Grill-5 mismatch — must fail."

  @impl true
  def binding_module, do: EzagentPluginEmMismatch.BindingA
end

defmodule EzagentPluginEmMismatch.BindingA do
  @moduledoc "The binding `AdapterA` thinks it owns."
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: EzagentPluginEmMismatch.AdapterA
end

defmodule EzagentPluginEmMismatch.BindingB do
  @moduledoc """
  A different binding declared in `adapters/0` — `AdapterA` does NOT
  name this module, so the Grill-5 bidirectional check fails.
  """
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: EzagentPluginEmMismatch.AdapterA
end

defmodule EzagentPluginEmMismatch do
  @moduledoc """
  Non-conforming plugin — `AdapterA.binding_module()` returns
  `BindingA`, but `adapters/0` declares `{AdapterA, BindingB}`.
  The `:ezagent_plugin_check` gate must reject this fixture's build.
  """
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "em-mismatch",
      name: "EM Mismatch Fixture",
      description: "Bidirectional adapter↔binding mismatch — illegal.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters do
    [{EzagentPluginEmMismatch.AdapterA, EzagentPluginEmMismatch.BindingB}]
  end
end
