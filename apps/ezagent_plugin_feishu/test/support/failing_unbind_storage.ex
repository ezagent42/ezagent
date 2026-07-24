defmodule EzagentPluginFeishu.TestSupport.FailingUnbindStorage do
  @moduledoc """
  Test-only fake storage module for deterministic rollback-log testing.

  Injected via `config :ezagent_plugin_feishu, :user_binding_storage_mod`.

  Delegates `bind/3`, `bind/4`, `resolve/1`, and `list_all/0` to the real
  `EzagentPluginFeishu.UserBinding`. Only `unbind/1` returns an error,
  causing the Behavior's `rollback_binding` to fail → `log_rollback_failure/4`
  fires in production code.
  """
  defdelegate bind(oid, uuri, by), to: EzagentPluginFeishu.UserBinding
  defdelegate bind(oid, uuri, by, at), to: EzagentPluginFeishu.UserBinding
  def unbind(_oid), do: {:error, :synthetic_unbind_failure}
  defdelegate resolve(oid), to: EzagentPluginFeishu.UserBinding
  defdelegate list_all, to: EzagentPluginFeishu.UserBinding
end
