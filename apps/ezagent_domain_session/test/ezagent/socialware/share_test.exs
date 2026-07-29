defmodule Ezagent.Socialware.ShareTest do
  @moduledoc """
  URI-share unification (A1) — the Feishu-style two-layer share.

  Permission = caps (who holds one). Sharing = a per-target `ShareSetting` toggle
  the OWNER turns on (that IS the authorization, codex M1) and off (revocation,
  codex D3). A link (`ShareToken`) is a stateless pointer; `Share.claim/2` mints
  ONLY while the target's sharing setting is enabled.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.Share
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "owner enables sharing → a link claim mints the declared cap; the ungranted action is refused" do
    owner = user_uri("owner")
    clicker = live_agent("clicker", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("board", owner, [Target])

    assert {:ok, _setting} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    assert {:ok, %{grantee: ^clicker}} = Share.claim(token, clicker)
    assert eventually(fn -> holds_cap?(clicker, target, :get_tree) end)
    assert {:ok, %{ok: true}} = dispatch(clicker, target, :get_tree)
    assert {:error, :missing_cap} = dispatch(clicker, target, :add_node)
  end

  test "M1: without the owner enabling sharing, a link mints NOTHING (link ≠ authority)" do
    owner = user_uri("m1-owner")
    clicker = live_agent("m1-clicker", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("m1-board", owner, [Target])

    # A perfectly valid signed link, but sharing was never turned on.
    token = Share.mint_link(target)

    assert {:error, :share_disabled} = Share.claim(token, clicker)
    refute eventually(fn -> holds_cap?(clicker, target, :get_tree) end, 5)
  end

  test "M1: only the target's data_owner can enable sharing (a non-owner cannot)" do
    owner = user_uri("m1o-owner")
    attacker = user_uri("m1o-attacker")
    target = live_agent("m1o-board", owner, [Target])

    assert {:error, {:share_setting_not_target_owner, _, _}} =
             Share.enable(target, attacker, Target, [:get_tree])

    assert {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
  end

  test "D3: the owner disables sharing → the SAME reusable link stops minting (revocation)" do
    owner = user_uri("d3-owner")
    c1 = live_agent("d3-c1", owner, Ezagent.Entity.Agent.base_behaviors())
    c2 = live_agent("d3-c2", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("d3-board", owner, [Target])

    {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    # Reusable: first clicker claims fine.
    assert {:ok, _} = Share.claim(token, c1)
    assert eventually(fn -> holds_cap?(c1, target, :get_tree) end)

    # Owner revokes by flipping the setting off — the SAME link now mints nothing.
    assert {:ok, _} = Share.disable(target, owner)
    assert {:error, :share_disabled} = Share.claim(token, c2)
    refute eventually(fn -> holds_cap?(c2, target, :get_tree) end, 5)

    # Already-granted access (c1's cap) is untouched by disabling the link.
    assert holds_cap?(c1, target, :get_tree)
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

  test "M2: enabling sharing for a behavior the target does NOT carry is refused (conformance)" do
    owner = user_uri("m2-owner")
    target = live_agent("m2-plain", owner, [])

    assert {:error, {:share_target_not_conformant, _, Target, :get_tree, _}} =
             Share.enable(target, owner, Target, [:get_tree])
  end

  test "link_anon is fail-closed until wired (A-series follow-up composing A4)" do
    owner = user_uri("la-owner")
    target = live_agent("la-board", owner, [Target])

    # The superset enum value exists, but its wiring (dedicated per-resource
    # public session + A4 mount) is a later piece — so it can't be set yet.
    assert {:error, :anon_share_not_yet_supported} =
             Share.enable(target, owner, Target, [:get_tree], visibility: :link_anon)

    # link_login is fully implemented.
    assert {:ok, _} = Share.enable(target, owner, Target, [:get_tree], visibility: :link_login)
  end

  test "a tampered link is rejected (fail-closed)" do
    owner = user_uri("t-owner")
    clicker = live_agent("t-clicker", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("t-board", owner, [Target])

    {:ok, _} = Share.enable(target, owner, Target, [:get_tree])
    token = Share.mint_link(target)

    assert {:error, _} = Share.claim(token <> "x", clicker)
    refute eventually(fn -> holds_cap?(clicker, target, :get_tree) end, 5)
  end

  # --- fixtures -------------------------------------------------------------

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

  defp dispatch(caller, target, action) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :composition_grant_target, action),
      mode: :call,
      args: %{},
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: MapSet.new(Ezagent.Identity.list_caps_for(caller)),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp holds_cap?(grantee, target, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      cap.kind == :agent and cap.behavior == Target and
        cap.action == action and
        cap.instance == Ezagent.URI.instance(target)
    end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://composition")

  defp user_uri(name) do
    uri =
      Ezagent.URI.new!("entity://composition/user/#{name}-#{System.unique_integer([:positive])}")

    {:ok, _} =
      Ezagent.Users.create(uri, "test-password-#{System.unique_integer([:positive])}", [])

    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/agent/#{name}-#{System.unique_integer([:positive])}")
end
