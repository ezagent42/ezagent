defmodule Ezagent.Invariants.CascadePr0FoundationsTest do
  # DataCase (not plain ExUnit): the registered-resolver check exercises the resolver,
  # which reads the Repo — so it needs the SQL sandbox.
  use EzagentCore.DataCase, async: false

  test "grant store, user-source registry, grant cap, adapter split all present" do
    assert Code.ensure_loaded?(Ezagent.Credential.GrantRow)
    assert Code.ensure_loaded?(Ezagent.Credential.UserDefaultSource)
    assert Code.ensure_loaded?(Ezagent.Credential.GrantCap)
    assert function_exported?(Ezagent.Credential.GrantCap, :read_cap_for, 1)

    # the cataloged materializer identity exists; the REJECTED per-grant dynamic
    # principal accessor does NOT
    assert Ezagent.SystemPrincipal.Catalog.member?(
             Ezagent.URI.new!("system://credential-materializer")
           )

    refute function_exported?(Ezagent.SystemPrincipal, :credential_grant_uri, 1)

    Code.ensure_loaded?(Ezagent.PluginCc.Template.CcAgent)
    Code.ensure_loaded?(Ezagent.PluginCodex.Template.CodexAgent)
    assert function_exported?(Ezagent.PluginCc.Template.CcAgent, :secret_relpaths, 0)
    # secret/config disjoint per flavor (H4 invariant)
    assert "config.toml" not in Ezagent.PluginCodex.Template.CodexAgent.secret_relpaths()
  end

  test ":user_default_credential_source is a registered UriQuery attribute" do
    # registration happens at app boot; resolve returns the no-resolver error only if
    # unregistered. A registered resolver returns `:none` for an unset pointer.
    refute match?(
             {:error, {:no_resolver, _}},
             Ezagent.UriQuery.resolve(
               :user_default_credential_source,
               {"entity://team-a/user/nobody", "team-a", "cc"}
             )
           )
  end
end
