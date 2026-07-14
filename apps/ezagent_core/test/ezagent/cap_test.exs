defmodule Ezagent.CapTest do
  use ExUnit.Case, async: false

  alias Ezagent.{Cap, Capability}
  alias Ezagent.Cap.Signing

  @seed "0123456789abcdef0123456789abcdef"
  @issuer Ezagent.URI.new!("entity://team-alpha/user/issuer")
  @target Ezagent.URI.new!("entity://team-alpha/user/grantee")
  @other_target Ezagent.URI.new!("entity://team-alpha/user/other-grantee")
  @non_entity Ezagent.URI.new!("system://bootstrap")

  setup do
    previous_cap_config = Application.get_env(:ezagent_core, Cap, [])
    loader = EzagentCore.Test.CapAuthorityLoaderStub

    signing = [
      seed_provider: fn
        1 -> {:ok, @seed}
        _version -> {:error, :missing_test_seed}
      end,
      active_key_version: 1,
      require_signature: false
    ]

    Application.put_env(:ezagent_core, loader, MapSet.new([Capability.admin_genesis_cap()]))

    Application.put_env(
      :ezagent_core,
      Cap,
      previous_cap_config
      |> Keyword.put(:authority_loader, loader)
      |> Keyword.put(:signing, signing)
    )

    on_exit(fn ->
      Application.put_env(:ezagent_core, Cap, previous_cap_config)
      Application.delete_env(:ezagent_core, loader)
    end)
  end

  defp unstamped_cap do
    %Capability{
      kind: :session,
      behavior: :example,
      action: :send,
      instance: :any,
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: @non_entity,
      granted_at: ~U[2020-01-01 00:00:00Z]
    }
  end

  describe "issue/3" do
    for {name, authorization} <- [
          held_by: {:held_by, @issuer},
          admin: {:admin, @issuer},
          rule: {:rule, :test_rule, @issuer}
        ] do
      test "signs a #{name} authorizer artifact", %{test: _test} do
        authorization = unquote(Macro.escape(authorization))

        assert {:ok, artifact} = Cap.issue(authorization, @target, signable_cap())
        assert_signed_by(artifact, @issuer)
      end
    end

    test "produces an artifact whose provenance is the issuer" do
      before_issue = DateTime.utc_now()

      assert {:ok, artifact} = Cap.issue({:genesis, @issuer}, @target, unstamped_cap())
      assert artifact.granted_by == @issuer
      assert artifact.grantee_uri == @target
      assert DateTime.compare(artifact.granted_at, before_issue) in [:eq, :gt]
      assert_signed_by(artifact, @issuer)
    end

    test "binds the issued signature to the requested grantee" do
      assert {:ok, artifact} = Cap.issue({:genesis, @issuer}, @target, signable_cap())
      trust_domain = Signing.trust_domain(artifact.workspace_uri)
      {public_key, _private_key} = Signing.derive_keypair(@issuer, trust_domain, 1)

      assert artifact.grantee_uri == @target

      refute Signing.verify(
               %{artifact | grantee_uri: @other_target},
               artifact.signature,
               public_key
             )
    end

    test "signs the system admin genesis shape in the any trust domain" do
      genesis = Capability.admin_genesis_cap()
      admin_uri = genesis.granted_by

      assert Ezagent.URI.stable_key(admin_uri) == "entity://system/user/admin"
      assert genesis.workspace_uri == :any

      assert {:ok, artifact} = Cap.issue({:genesis, admin_uri}, admin_uri, genesis)
      assert artifact.key_id == Signing.key_id(1, "a:*")
      assert artifact.grantee_uri == admin_uri
      assert_signed_by(artifact, admin_uri)
    end

    test "rejects a missing or wildcard grantee before authorization" do
      for invalid_grantee <- [nil, :any] do
        assert_raise FunctionClauseError, fn ->
          Cap.issue({:genesis, @issuer}, invalid_grantee, signable_cap())
        end
      end
    end

    test "rejects a non-entity issuer" do
      assert {:error, {:granter_not_entity, @non_entity}} =
               Cap.issue({:genesis, @non_entity}, @target, unstamped_cap())
    end

    test "rejects an unbounded rule grant before producing an artifact" do
      unbounded = %{unstamped_cap() | kind: :any, behavior: :any, instance: :any}

      assert {:error, :rule_grant_must_be_concrete_scoped} =
               Cap.issue({:rule, :public_view, @issuer}, @target, unbounded)
    end

    test "a manager lacking the delegated cap cannot issue an artifact" do
      previous = Application.get_env(:ezagent_core, Cap)
      loader = EzagentCore.Test.CapAuthorityLoaderStub
      target = Ezagent.URI.new!("entity://team-alpha/agent/managed")
      workspace = Ezagent.URI.new!("workspace://team-alpha")

      manage = Ezagent.CreatorGrant.manage_cap(:agent, target, workspace, @issuer)
      Application.put_env(:ezagent_core, loader, MapSet.new([manage]))
      Application.put_env(:ezagent_core, Cap, authority_loader: loader)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ezagent_core, Cap, previous),
          else: Application.delete_env(:ezagent_core, Cap)

        Application.delete_env(:ezagent_core, loader)
      end)

      delegated = %Capability{
        kind: :agent,
        behavior: EzagentCore.Test.CapOwnedBehaviorStub,
        action: :read,
        instance: target,
        workspace_uri: workspace,
        granted_by: @non_entity,
        granted_at: ~U[2020-01-01 00:00:00Z]
      }

      assert {:error, :grant_not_delegable} =
               Cap.issue({:held_by, @issuer}, @target, delegated)
    end

    test "raises when the active signing seed is unavailable" do
      replace_seed_provider(fn _version -> {:error, :missing_seed} end)

      assert_raise RuntimeError, ~r/signing seed unavailable/, fn ->
        Cap.issue({:genesis, @issuer}, @target, signable_cap())
      end
    end
  end

  describe "declarative caps" do
    test "remain unsigned sentinels" do
      declared = Capability.cap(:session, Ezagent.ActionSet.Session, :send)

      assert declared.granted_by == :plugin_declared
      assert declared.granted_at == :compile_time
      assert declared.signature == nil
      assert declared.key_id == nil
    end
  end

  describe "verify/1" do
    test "is total and trusts only entity provenance" do
      assert Cap.verify(%{unstamped_cap() | granted_by: @issuer})
      refute Cap.verify(unstamped_cap())
      refute Cap.verify(:not_an_artifact)
    end
  end

  defp signable_cap do
    %{
      unstamped_cap()
      | instance: Ezagent.URI.new!("session://team-alpha/default/chat"),
        workspace_uri: Ezagent.URI.new!("workspace://team-alpha")
    }
  end

  defp assert_signed_by(artifact, issuer) do
    trust_domain = Signing.trust_domain(artifact.workspace_uri)

    assert artifact.granted_by == issuer
    assert is_binary(artifact.signature)
    assert artifact.key_id == Signing.key_id(1, trust_domain)
    assert {public_key, _private_key} = Signing.derive_keypair(issuer, trust_domain, 1)
    assert Signing.verify(artifact, artifact.signature, public_key)
  end

  defp replace_seed_provider(seed_provider) do
    config = Application.fetch_env!(:ezagent_core, Cap)
    signing = Keyword.fetch!(config, :signing)

    Application.put_env(
      :ezagent_core,
      Cap,
      Keyword.put(config, :signing, Keyword.put(signing, :seed_provider, seed_provider))
    )
  end
end
