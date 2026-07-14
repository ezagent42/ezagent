defmodule Ezagent.Invariants.CapSigningInvariantTest do
  use ExUnit.Case, async: false

  alias Ezagent.{Cap, Capability}

  @seed "0123456789abcdef0123456789abcdef"
  @issuer Ezagent.URI.new!("entity://team-alpha/user/issuer")
  @target Ezagent.URI.new!("entity://team-alpha/user/grantee")
  @admin Ezagent.URI.new!("entity://system/user/admin")

  setup do
    previous_cap_config = Application.get_env(:ezagent_core, Cap, [])
    loader = EzagentCore.Test.CapAuthorityLoaderStub

    Application.put_env(:ezagent_core, loader, MapSet.new([Capability.admin_genesis_cap()]))

    Application.put_env(
      :ezagent_core,
      Cap,
      previous_cap_config
      |> Keyword.put(:authority_loader, loader)
      |> Keyword.put(:signing, signing_config(require_signature: false))
    )

    on_exit(fn ->
      Application.put_env(:ezagent_core, Cap, previous_cap_config)
      Application.delete_env(:ezagent_core, loader)
    end)
  end

  test "INV-SIGN-1: every authorizer artifact in a receiver slice verifies under enforce" do
    assert {:ok, issued} = Cap.issue({:genesis, @issuer}, @target, signable_cap())

    assert {:ok, genesis} =
             Cap.issue({:genesis, @admin}, @admin, Capability.admin_genesis_cap())

    slices = [
      {@target, MapSet.new([issued, Capability.cap(:session, Ezagent.ActionSet.Session, :send)])},
      {@admin, MapSet.new([genesis])}
    ]

    enable_signature_enforcement!()

    authorizer_count =
      for {holder, caps} <- slices,
          %Capability{granted_by: granted_by} = cap <- caps,
          granted_by != :plugin_declared do
        assert Cap.verify(cap)
        assert Cap.verify_for(cap, holder)
        cap
      end
      |> length()

    assert authorizer_count == 2
  end

  test "INV-SIGN-2: trusted signed artifacts raise when key material is unavailable" do
    assert {:ok, issued} = Cap.issue({:genesis, @issuer}, @target, signable_cap())
    replace_seed_provider(fn _version -> {:error, :missing_seed} end)

    assert_raise RuntimeError, ~r/signing seed unavailable/, fn ->
      Cap.verify(issued)
    end

    assert_raise RuntimeError, ~r/signing seed unavailable/, fn ->
      Cap.verified_set([issued])
    end
  end

  defp signable_cap do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: Ezagent.URI.new!("session://team-alpha/default/chat"),
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: @issuer,
      granted_at: ~U[2026-07-14 00:00:00Z]
    }
  end

  defp signing_config(opts) do
    [
      seed_provider: fn
        1 -> {:ok, @seed}
        _version -> {:error, :missing_test_seed}
      end,
      active_key_version: 1,
      require_signature: Keyword.fetch!(opts, :require_signature)
    ]
  end

  defp enable_signature_enforcement! do
    config = Application.fetch_env!(:ezagent_core, Cap)
    signing = Keyword.fetch!(config, :signing)

    Application.put_env(
      :ezagent_core,
      Cap,
      Keyword.put(config, :signing, Keyword.put(signing, :require_signature, true))
    )
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
