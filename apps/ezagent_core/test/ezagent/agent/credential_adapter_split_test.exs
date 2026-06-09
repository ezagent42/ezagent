defmodule Ezagent.Agent.CredentialAdapterSplitTest do
  use ExUnit.Case, async: true

  # Every credentialled flavor must declare secret_relpaths/0, and the secret set
  # must be DISJOINT from the config paths (config.toml is config, not a secret — H4).
  test "cc/codex declare secret_relpaths and secrets are not config files" do
    for mod <- [Ezagent.PluginCc.Template.CcAgent, Ezagent.PluginCodex.Template.CodexAgent] do
      assert function_exported?(mod, :secret_relpaths, 0),
             "#{inspect(mod)} must implement secret_relpaths/0"

      secrets = mod.secret_relpaths()
      assert is_list(secrets) and secrets != []
      # config.toml is configuration, must NOT be a secret path
      refute "config.toml" in secrets
    end
  end

  test "cc secret is the credentials file; codex secret is auth.json only" do
    assert Ezagent.PluginCc.Template.CcAgent.secret_relpaths() == [".credentials.json"]
    assert Ezagent.PluginCodex.Template.CodexAgent.secret_relpaths() == ["auth.json"]
  end
end
