defmodule EzagentPluginRegRuntime.RuntimeBadRegistration do
  @moduledoc """
  A RUNTIME plugin module (NOT a Mix task) that bypasses the sanctioned
  `Ezagent.Plugin.boot/1` path by calling a `*Registry.register` API
  directly. check 7 MUST flag this file. The gate only greps source
  text (it never compiles this file), so the referenced module need not
  exist.
  """

  def install do
    Ezagent.PluginRegistry.register(SomePlugin)
  end
end
