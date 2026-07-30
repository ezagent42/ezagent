defmodule Ezagent.Socialware.ShareTest do
  @moduledoc """
  URI-share unification (A1) — the Feishu-style two-layer share.

  Permission = caps (who holds one). Sharing = a per-target `ShareSetting` toggle
  the OWNER turns on (that IS the authorization, codex M1) and off (revocation,
  codex D3). A link (`ShareToken`) is a stateless pointer; `Share.claim/2` records
  a `ShareClaim` (NOT a durable cap) only while sharing is enabled, and access is
  re-derived LIVE via `Share.shared_to?/2` (`ShareSetting.active` AND the claim) —
  so disabling the setting cuts every claimer off instantly (codex Fix 1), exactly
  like Feishu "anyone with the link can view". The read chokepoint
  (`SessionReads.authorize_external_read`) AND-s `shared_to?/2` after its held-cap
  check; that integration is exercised in the web/world layer.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Share, ShareClaim, ShareSetting}
  alias EzagentCore.Repo
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "owner enables sharing → a claimed link makes the clicker shared_to?; a non-claimer is not" do
    owner = user_uri("owner")
    clicker = user_uri("clicker")
    stranger = user_uri("stranger")
    target = live_agent("board", owner, [Target])

    assert {:ok, _setting} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    refute Share.shared_to?(target, clicker)
    assert {:ok, %{grantee: ^clicker}} = Share.claim(token, clicker)

    # Model A: no durable cap is minted — access is the live claim + enabled setting.
    assert Share.shared_to?(target, clicker)
    refute Share.shared_to?(target, stranger)
  end

  test "M1: without the owner enabling sharing, a link claims NOTHING (link ≠ authority)" do
    owner = user_uri("m1-owner")
    clicker = user_uri("m1-clicker")
    target = live_agent("m1-board", owner, [Target])

    # A perfectly valid signed link, but sharing was never turned on.
    token = Share.mint_link(target)

    assert {:error, :share_disabled} = Share.claim(token, clicker)
    refute Share.shared_to?(target, clicker)
  end

  test "M1: only the target's data_owner can enable sharing (a non-owner cannot)" do
    owner = user_uri("m1o-owner")
    attacker = user_uri("m1o-attacker")
    target = live_agent("m1o-board", owner, [Target])

    assert {:error, {:share_setting_not_target_owner, _, _}} =
             Share.enable(target, attacker, Target, [:get_tree])

    assert {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
  end

  test "Fix 1 (instant disable): disabling sharing denies EVERY claimer on the very next check" do
    owner = user_uri("f1-owner")
    clicker = user_uri("f1-clicker")
    target = live_agent("f1-board", owner, [Target])

    {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    assert {:ok, _} = Share.claim(token, clicker)
    assert Share.shared_to?(target, clicker)

    # Owner flips the setting off — the ALREADY-claimed clicker loses access
    # immediately (no per-person revoke, no re-check race). This is the whole
    # point of the live model vs. minting an independent cap.
    assert {:ok, _} = Share.disable(target, owner)
    refute Share.shared_to?(target, clicker)

    # Re-enabling restores it — the claim itself persisted, only the toggle moved.
    assert {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
    assert Share.shared_to?(target, clicker)
  end

  test "D3: only the owner can disable sharing" do
    owner = user_uri("d3o-owner")
    attacker = user_uri("d3o-attacker")
    target = live_agent("d3o-board", owner, [Target])

    {:ok, _} = Share.enable(target, owner, Target, [:get_tree])

    assert {:error, {:share_setting_not_target_owner, _, _}} = Share.disable(target, attacker)
    # Still enabled — the attacker's disable was refused.
    assert {:ok, _} = Share.disable(target, owner)
  end

  test "Fix 2: a claim is refused when the setting's granter is no longer the current owner" do
    owner = user_uri("f2-owner")
    clicker = user_uri("f2-clicker")
    target = live_agent("f2-board", owner, [Target])

    {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    # Simulate an ownership transfer AFTER enable: the stored setting's granter is
    # now stale (someone who no longer owns the target). Claim must fail closed —
    # the new owner never authorized this share.
    stale = Ezagent.URI.new!("entity://composition/user/ex-owner-#{u()}")

    {1, _} =
      Repo.update_all(
        ShareSetting
        |> where_target(target),
        set: [granter_uri: URI.to_string(Ezagent.URI.instance(stale))]
      )

    assert {:error, :share_owner_changed} = Share.claim(token, clicker)
    refute Share.shared_to?(target, clicker)
  end

  test "M2: enabling sharing for a behavior the target does NOT carry is refused (conformance)" do
    owner = user_uri("m2-owner")
    target = live_agent("m2-plain", owner, [])

    assert {:error, {:share_target_not_conformant, _, Target, :get_tree, _}} =
             Share.enable(target, owner, Target, [:get_tree])
  end

  test "link_anon is fail-closed until wired (A-series follow-up composing A4)" do
    owner = user_uri("la-owner")
    target = live_agent("la-board", owner, [Target])

    assert {:error, :anon_share_not_yet_supported} =
             Share.enable(target, owner, Target, [:get_tree], visibility: :link_anon)

    assert {:ok, _} = Share.enable(target, owner, Target, [:get_tree], visibility: :link_login)
  end

  test "a tampered link is rejected (fail-closed)" do
    owner = user_uri("t-owner")
    clicker = user_uri("t-clicker")
    target = live_agent("t-board", owner, [Target])

    {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    assert {:error, _} = Share.claim(token <> "x", clicker)
    refute Share.shared_to?(target, clicker)
    refute ShareClaim.claimed?(target, clicker)
  end

  # --- fixtures -------------------------------------------------------------

  defp u, do: System.unique_integer([:positive])

  defp where_target(query, target) do
    import Ecto.Query
    key = URI.to_string(Ezagent.URI.instance(target))
    from(s in query, where: s.target_uri == ^key)
  end

  defp live_agent(name, owner, extra_behaviors) do
    uri = agent_uri(name)
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri())
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://composition")

  defp user_uri(name) do
    uri = Ezagent.URI.new!("entity://composition/user/#{name}-#{u()}")

    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{u()}", [])

    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp agent_uri(name),
    do: Ezagent.URI.new!("entity://composition/agent/#{name}-#{u()}")
end
