defmodule Ezagent.Socialware.CompositionGrantTest do
  @moduledoc """
  通用运行时"发一把钥匙"入口 `CompositionCaps.mint_cap/4`。

  一个通用函数,发什么钥匙由传入的 `actions` 决定:
    * 传读动作(`[:get_tree]`)→ 铸出只读钥匙;
    * 传增删改(`[:add_node, ...]`)→ 铸出操作钥匙。
  同一个函数、同一条 issue+absorb 路,动作是参数。granter 永远 = target 的
  data_owner(板主人授权,#154),读写都一样。target 无属主 → fail-closed。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.CompositionCaps

  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "granting only a read action mints a read-only key; the ungranted write is refused" do
    owner = user_uri("board-owner")
    grantee = live_agent("grantee", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("board", owner, [Target])
    unrelated = live_agent("unrelated-board", owner, [Target])

    assert {:ok, [%Ezagent.Capability{} = artifact]} =
             CompositionCaps.mint_cap(grantee, target, Target, [:get_tree])

    # (a) grantee 持指向 target 的实例精确 cap、granted_by == owner(板主人)
    assert artifact.behavior == Target
    assert artifact.action == :get_tree
    assert artifact.instance == Ezagent.URI.instance(target)
    assert artifact.granted_by == owner
    refute artifact.instance == :any

    assert eventually(fn -> holds_cap?(grantee, target, :get_tree) end)

    # (b) grantee 自身份 dispatch 只读动作到 target 成功
    assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)

    # 同一函数只给了读动作 → 写动作没有钥匙 → 越权拒
    assert {:error, :missing_cap} = dispatch(grantee, target, :add_node)

    # (c) 到无关 target 越权拒
    assert {:error, :invalid_cap_signature} = dispatch(grantee, unrelated, :get_tree)
  end

  test "granting write actions mints an operate key over the same code path" do
    owner = user_uri("operate-owner")
    grantee = live_agent("operate-grantee", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("operate-board", owner, [Target])

    assert {:ok, artifacts} =
             CompositionCaps.mint_cap(grantee, target, Target, [:add_node, :get_tree])

    assert length(artifacts) == 2
    assert Enum.all?(artifacts, &(&1.granted_by == owner))
    assert Enum.all?(artifacts, &(&1.instance == Ezagent.URI.instance(target)))

    assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)

    assert {:ok, %{ok: true}} = dispatch(grantee, target, :add_node)
    assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)
  end

  test "an ownerless target fails closed and grants nothing" do
    owner = user_uri("ownerless-owner")
    grantee = live_agent("ownerless-grantee", owner, Ezagent.Entity.Agent.base_behaviors())
    # data_owner resolves only for an agent with recorded lineage; this target
    # carries none, so ownership resolution must fail closed before ISSUE.
    target = orphan_agent("ownerless-board", [Target])

    assert {:error, {:operate_target_ownerless, _uri, Target}} =
             CompositionCaps.mint_cap(grantee, target, Target, [:get_tree])

    refute eventually(fn -> holds_cap?(grantee, target, :get_tree) end, 5)
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
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :composition_grant_target, action),
      mode: :call,
      args: %{},
      ctx: %{
        caller: caller,
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
    uri = Ezagent.URI.new!("entity://composition/user/#{name}-#{System.unique_integer([:positive])}")
    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{System.unique_integer([:positive])}", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/agent/#{name}-#{System.unique_integer([:positive])}")
end
