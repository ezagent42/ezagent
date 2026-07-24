defmodule EzagentPluginFeishu.TestSupport.FailingPolicy do
  @moduledoc """
  Test-only fake policy module for deterministic rollback testing.

  Injected via `config :ezagent_plugin_feishu, :binding_policy_mod`.

  `do_apply/2` always returns `{:error, :policy_failure_synthetic}`,
  triggering the Behavior's rollback path deterministically.
  """
  def do_apply(_user_uri, _admin_uri), do: {:error, :policy_failure_synthetic}
end
