defmodule Ezagent.Socialware.ShareTest do
  @moduledoc """
  URI-share unification (A1) — the claim edge.

  `Share.claim/2` = verify a BEARER share link (`ShareToken`) → mint a
  grantee-bound cap toward its target for the clicker (`CompositionCaps.mint_cap`,
  granter ≡ target's data_owner). URI-agnostic: the target is any agent with a
  resolvable owner; `behavior`/`actions` ride in the signed token (zero plugin
  literal). Mirrors `CompositionGrantTest`'s mint setup.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.ShareToken
  alias Ezagent.Socialware.Share
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "claiming a bearer link mints a grantee-bound read cap; the ungranted write is refused" do
    owner = user_uri("share-owner")
    clicker = live_agent("clicker", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("shared-board", owner, [Target])

    token = ShareToken.mint_link!(target, Target, [:get_tree], ttl_seconds: 60)

    assert {:ok, %{target: claimed, grantee: ^clicker}} = Share.claim(token, clicker)
    assert Ezagent.URI.instance(claimed) == Ezagent.URI.instance(target)

    # cap-as-truth: clicker now holds the shared read cap → read dispatch OK,
    # the ungranted write is refused (only the link's actions were minted).
    assert eventually(fn -> holds_cap?(clicker, target, :get_tree) end)
    assert {:ok, %{ok: true}} = dispatch(clicker, target, :get_tree)
    assert {:error, :missing_cap} = dispatch(clicker, target, :add_node)
  end

  test "a read link grants ONLY read; an operate link grants operate (actions ride the token)" do
    owner = user_uri("share-owner-op")
    clicker = live_agent("clicker-op", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("shared-board-op", owner, [Target])

    token = ShareToken.mint_link!(target, Target, [:add_node, :get_tree], ttl_seconds: 60)

    assert {:ok, _} = Share.claim(token, clicker)
    assert eventually(fn -> holds_cap?(clicker, target, :add_node) end)
    assert {:ok, %{ok: true}} = dispatch(clicker, target, :add_node)
  end

  test "a tampered link mints nothing (fail-closed)" do
    owner = user_uri("share-owner-2")
    clicker = live_agent("clicker-2", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("shared-board-2", owner, [Target])

    token = ShareToken.mint_link!(target, Target, [:get_tree], ttl_seconds: 60)

    assert {:error, _} = Share.claim(token <> "x", clicker)
    refute eventually(fn -> holds_cap?(clicker, target, :get_tree) end, 5)
  end

  test "claiming a link toward an ownerless target fails closed (no owner to grant from)" do
    owner = user_uri("share-owner-3")
    clicker = live_agent("clicker-3", owner, Ezagent.Entity.Agent.base_behaviors())
    target = orphan_agent("ownerless-shared", [Target])

    token = ShareToken.mint_link!(target, Target, [:get_tree], ttl_seconds: 60)

    assert {:error, {:operate_target_ownerless, _, Target}} = Share.claim(token, clicker)
    refute eventually(fn -> holds_cap?(clicker, target, :get_tree) end, 5)
  end

  # --- fixture helpers (same CompositionGrantTargetBehavior fixture as
  #     CompositionGrantTest; copied verbatim to keep A1 self-contained) --------

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

  # A target with NO recorded lineage: its data_owner cannot resolve.
  defp orphan_agent(name, extra_behaviors) do
    uri = agent_uri(name)
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri())
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
        cap.instance == Ezagent.URI.instance(target) and
        cap.workspace_uri == workspace_uri()
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
