defmodule Ezagent.Invariants.CascadePr0FoundationsTest do
  # DataCase (not plain ExUnit): the registered-resolver check exercises the resolver,
  # which reads the Repo — so it needs the SQL sandbox.
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  test "grant store, user-source registry, grant cap, adapter split all present" do
    assert Code.ensure_loaded?(Ezagent.Credential.GrantRow)
    assert Code.ensure_loaded?(Ezagent.Credential.UserDefaultSource)
    assert Code.ensure_loaded?(Ezagent.Credential.GrantCap)
    assert function_exported?(Ezagent.Credential.GrantCap, :read_cap_for, 1)

    # System-principal elimination (north star): the `credential-materializer`
    # audit-label principal is REMOVED — api-key materialization runs under the
    # agent's own entity self-authority and per-grant source-read authority is the
    # narrow `GrantCap` cap (no cataloged principal). The REJECTED per-grant dynamic
    # principal accessor also does NOT exist.
    refute Ezagent.SystemPrincipal.Catalog.member?(
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

  test ":workspace_shared_credential_source is a registered UriQuery attribute" do
    refute match?(
             {:error, {:no_resolver, _}},
             Ezagent.UriQuery.resolve(
               :workspace_shared_credential_source,
               {URI.new!("workspace://team-a"), "cc"}
             )
           )
  end

  test ":config_dir is a registered UriQuery attribute" do
    refute match?(
             {:error, {:no_resolver, _}},
             Ezagent.UriQuery.resolve(:config_dir, URI.new!("entity://team-a/agent/unconfigured"))
           )
  end

  test "session-template spawned members enter the cascade create chokepoint" do
    creator_source =
      File.read!(
        Path.expand(
          "../../../ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
          __DIR__
        )
      )

    team_source =
      File.read!(
        Path.expand(
          "../../../ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex",
          __DIR__
        )
      )

    assert creator_source =~ "def list_caps_for_materialization(%URI{} = actor_uri),"
    assert creator_source =~ "do: Ezagent.Identity.list_caps_for(actor_uri)"
    assert team_source =~ "source_template_uri: source_template_uri"
    assert team_source =~ "caller: granted_by"
    assert team_source =~ "list_caps_for_materialization("
  end

  test "session orchestrator spawn enters the cascade create chokepoint" do
    source =
      File.read!(
        Path.expand(
          "../../../ezagent_domain_session/lib/ezagent/entity/session.ex",
          __DIR__
        )
      )

    assert source =~ "source_template_uri: orch_template_uri"
    assert source =~ "caller: owner_uri"
    assert source =~ "caps: Ezagent.Identity.list_caps_for(owner_uri)"
  end
end
