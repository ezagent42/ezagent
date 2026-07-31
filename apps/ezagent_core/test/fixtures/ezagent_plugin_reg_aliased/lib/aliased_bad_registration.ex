defmodule EzagentPluginRegAliased.AliasedBadRegistration do
  @moduledoc """
  A RUNTIME plugin module that bypasses `Ezagent.Plugin.boot/1` by calling
  a `*Registry.register` API directly — but via the ALIASED short form
  rather than the fully-qualified name. check 7 MUST flag this: the AST
  detector keys on the alias's last segment (`AdapterRegistry`), so the
  aliased call is caught exactly like a fully-qualified one. The gate only
  reads source (it never compiles this file), so the referenced modules
  need not exist.
  """

  alias Ezagent.ExternalMirror.AdapterRegistry

  def install do
    AdapterRegistry.register(SomeAdapter)
  end
end
