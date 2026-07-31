defmodule EzagentPluginRegDoccomment.DocOnlyMentions do
  @moduledoc """
  A RUNTIME plugin module that MENTIONS registry APIs in prose but never
  calls one — the exact shape of the forgejo false positive (#1643).

  The adapter declaration is DECLARATIVE: `AdapterRegistry.register/2`
  validates the callbacks, but this module never calls it — registration
  goes through `Ezagent.Plugin.boot/1`. Likewise the driver pair is
  reconciled into a registry by a supervised owner, so no
  `Ezagent.PluginRegistry.register/1` call appears in this source.

  check 7 must NOT flag this file: every occurrence above is prose, and
  the one below is a `#` comment — neither is a call node.
  """

  # NOTE: registration is declarative; we do NOT call
  # `Ezagent.PluginRegistry.register(__MODULE__)` here — boot/1 does it.
  def children, do: []
end
