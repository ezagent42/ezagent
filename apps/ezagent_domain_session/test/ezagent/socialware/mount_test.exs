defmodule Ezagent.Socialware.MountTest do
  @moduledoc """
  通用挂载生命周期 API `Ezagent.Socialware.Mount` —— 把「挂载一个数据宿主 agent 进
  session」做成 behavior/role/actions 全参数化的三入口:

    * `mount/6`   —— `mint_cap`(发钥匙)+ `MountRow.upsert`(落表)。access 由 opts 传。
    * `unmount/4` —— 撤 cap(每个 action)+ `MountRow.delete_by_natural_key`。
    * `provision/6` —— `Workspace.create_agent`(建宿主,data_owner=owner)+ 当场 `mount`。

  零 kanban 字面:用通用 test 靶 behavior `CompositionGrantTargetBehavior`
  (`:get_tree` 读 + `:add_node` 写),动作/行为/access 全参数化。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Mount, MountRow}
  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}

  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  describe "mount/6 — 发钥匙 + 落表(access 由 actions 选,行为/动作参数化)" do
    test "只读动作 → grantee 持只读 cap、行 access=read、读成写拒" do
      owner = user_uri("ro-owner")
      grantee = live_agent("ro-grantee", owner)
      target = live_agent("ro-board", owner, [Target])
      session = session_uri()

      assert {:ok, %{caps: [%Ezagent.Capability{} = cap], mount: %MountRow{} = row}} =
               Mount.mount(session, target, grantee, Target, [:get_tree], access: :read)

      # (a) 只读钥匙:实例精确、granted_by == 宿主 data_owner(板主人 #154)
      assert cap.behavior == Target
      assert cap.action == :get_tree
      assert cap.instance == Ezagent.URI.instance(target)
      assert URI.to_string(cap.granted_by) == URI.to_string(owner)

      # (b) 挂载表有该自然键的行、access 记为 "read"
      assert row.access == "read"
      assert row.behavior == inspect(Target)
      assert MountRow.get(session, target, grantee, Target) != nil
      assert URI.to_string(User.admin_uri()) != row.granted_by
      assert row.granted_by == URI.to_string(owner)

      # (c) grantee 自身份 dispatch:只读动作成、写动作越权拒
      assert eventually(fn -> holds_cap?(grantee, target, :get_tree) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)
      assert {:error, :missing_cap} = dispatch(grantee, target, :add_node)
    end

    test "写动作 → grantee 持操作 cap、行 access=operate、两动作都成" do
      owner = user_uri("op-owner")
      grantee = live_agent("op-grantee", owner)
      target = live_agent("op-board", owner, [Target])
      session = session_uri()

      assert {:ok, %{caps: caps, mount: %MountRow{} = row}} =
               Mount.mount(session, target, grantee, Target, [:add_node, :get_tree],
                 access: :operate
               )

      assert length(caps) == 2
      assert Enum.all?(caps, &(URI.to_string(&1.granted_by) == URI.to_string(owner)))
      assert row.access == "operate"

      assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :add_node)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)
    end

    test "默认 access 为 operate(不传 opts)" do
      owner = user_uri("def-owner")
      grantee = live_agent("def-grantee", owner)
      target = live_agent("def-board", owner, [Target])
      session = session_uri()

      assert {:ok, %{mount: %MountRow{access: "operate"}}} =
               Mount.mount(session, target, grantee, Target, [:add_node])
    end

    test "同自然键再 mount → 挂载表仍 1 行(覆盖,不重复)" do
      owner = user_uri("dup-owner")
      grantee = live_agent("dup-grantee", owner)
      target = live_agent("dup-board", owner, [Target])
      session = session_uri()

      assert {:ok, _} = Mount.mount(session, target, grantee, Target, [:get_tree], access: :read)

      assert {:ok, _} =
               Mount.mount(session, target, grantee, Target, [:add_node, :get_tree],
                 access: :operate
               )

      rows = MountRow.list_for_session(session)
      assert length(rows) == 1
      assert hd(rows).access == "operate"
    end

    test "mint 失败(无属主宿主)→ 不落表" do
      owner = user_uri("fc-owner")
      grantee = live_agent("fc-grantee", owner)
      target = orphan_agent("fc-board", [Target])
      session = session_uri()

      assert {:error, {:operate_target_ownerless, _uri, Target}} =
               Mount.mount(session, target, grantee, Target, [:get_tree], access: :read)

      assert MountRow.get(session, target, grantee, Target) == nil
    end
  end

  describe "unmount/4 — 撤 cap + 删行" do
    test "撤销后 dispatch 变 unauthorized、挂载行删除" do
      owner = user_uri("um-owner")
      grantee = live_agent("um-grantee", owner)
      target = live_agent("um-board", owner, [Target])
      session = session_uri()

      assert {:ok, _} =
               Mount.mount(session, target, grantee, Target, [:add_node, :get_tree],
                 access: :operate
               )

      assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :add_node)

      assert {:ok, :unmounted} = Mount.unmount(session, target, grantee, Target)

      # 行删
      assert MountRow.get(session, target, grantee, Target) == nil
      # cap 撤 → dispatch 变 unauthorized
      assert eventually(fn ->
               match?({:error, _reason}, dispatch(grantee, target, :add_node))
             end)
    end

    test "未挂载的自然键 unmount → 依然 {:ok, :unmounted}(幂等)" do
      owner = user_uri("um2-owner")
      grantee = live_agent("um2-grantee", owner)
      target = live_agent("um2-board", owner, [Target])
      session = session_uri()

      assert {:ok, :unmounted} = Mount.unmount(session, target, grantee, Target)
    end
  end

  describe "unmount_all_for_target/1 — 宿主退场清光名下全部挂载(撤钥匙 + 删行)" do
    test "跨 session、跨 grantee、含 person 行逐行卸载;钥匙撤、行删、别的 target 不动" do
      owner = user_uri("uat-owner")
      grantee_a = live_agent("uat-grantee-a", owner)
      grantee_b = live_agent("uat-grantee-b", owner)
      target = live_agent("uat-host", owner, [Target])
      other_target = live_agent("uat-other-host", owner, [Target])
      session_a = session_uri()
      session_b = session_uri()

      assert {:ok, _} =
               Mount.mount(session_a, target, grantee_a, Target, [:add_node, :get_tree],
                 access: :operate
               )

      assert {:ok, _} =
               Mount.mount(session_b, target, grantee_b, Target, [:get_tree], access: :read)

      assert {:ok, _} =
               Mount.mount_for_person(target, grantee_b, Target, [:get_tree], access: :read)

      assert {:ok, _} =
               Mount.mount(session_a, other_target, grantee_a, Target, [:get_tree], access: :read)

      assert eventually(fn -> holds_cap?(grantee_a, target, :add_node) end)
      assert eventually(fn -> holds_cap?(grantee_b, target, :get_tree) end)

      assert {:ok, %{unmounted: 3, failed: 0}} = Mount.unmount_all_for_target(target)

      # 行全删(session 两行 + person 一行)
      assert MountRow.list_for_target(target) == []
      assert MountRow.get(session_a, target, grantee_a, Target) == nil
      assert MountRow.get(session_b, target, grantee_b, Target) == nil
      assert MountRow.get_person(target, grantee_b, Target) == nil

      # 钥匙撤 → dispatch 变 unauthorized
      assert eventually(fn ->
               match?({:error, _}, dispatch(grantee_a, target, :add_node))
             end)

      assert eventually(fn ->
               match?({:error, _}, dispatch(grantee_b, target, :get_tree))
             end)

      # 别的 target 的挂载不牵连
      assert MountRow.get(session_a, other_target, grantee_a, Target) != nil
      assert eventually(fn -> holds_cap?(grantee_a, other_target, :get_tree) end)
    end

    test "无挂载行的 target → {:ok, %{unmounted: 0, failed: 0}}(no-op,不 raise)" do
      owner = user_uri("uat0-owner")
      target = live_agent("uat0-host", owner, [Target])

      assert {:ok, %{unmounted: 0, failed: 0}} = Mount.unmount_all_for_target(target)
    end
  end

  describe "mount_for_person/5 + unmount_for_person/3 — 人本位挂载(无 session 轴)" do
    # grantee 轴零改动:mint_cap 本就收任意 URI(人/agent 同款),这里沿用 live_agent
    # 作 grantee 走通 cap 全链;person-scope 的差异全在挂载行的 session 轴上。
    test "落 person 行(scope=person、无 session)+ grantee 持钥可 dispatch" do
      owner = user_uri("pm-owner")
      grantee = live_agent("pm-holder", owner)
      target = live_agent("pm-board", owner, [Target])

      assert {:ok, %{caps: [%Ezagent.Capability{} = cap], mount: %MountRow{} = row}} =
               Mount.mount_for_person(target, grantee, Target, [:get_tree], access: :read)

      assert row.scope == "person"
      assert row.session_uri == nil
      assert row.access == "read"
      assert row.granted_by == URI.to_string(owner)
      assert URI.to_string(cap.granted_by) == URI.to_string(owner)

      assert MountRow.get_person(target, grantee, Target) != nil
      assert [_] = MountRow.list_person_mounts_for_grantee(grantee)

      assert eventually(fn -> holds_cap?(grantee, target, :get_tree) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)

      # 只授了 :get_tree,:add_node 无 cap——strict-verify 口径 :missing_cap(照本文件 session 路同款)
      assert {:error, :missing_cap} = dispatch(grantee, target, :add_node)
    end

    test "同 person 自然键再 mount → 仍 1 行(覆盖)" do
      owner = user_uri("pmdup-owner")
      grantee = live_agent("pmdup-holder", owner)
      target = live_agent("pmdup-board", owner, [Target])

      assert {:ok, _} =
               Mount.mount_for_person(target, grantee, Target, [:get_tree], access: :read)

      assert {:ok, _} =
               Mount.mount_for_person(target, grantee, Target, [:add_node, :get_tree],
                 access: :operate
               )

      rows = MountRow.list_person_mounts_for_grantee(grantee)
      assert length(rows) == 1
      assert hd(rows).access == "operate"
    end

    test "unmount_for_person 撤钥匙 + 删行;未挂载幂等" do
      owner = user_uri("pmum-owner")
      grantee = live_agent("pmum-holder", owner)
      target = live_agent("pmum-board", owner, [Target])

      assert {:ok, _} =
               Mount.mount_for_person(target, grantee, Target, [:add_node, :get_tree],
                 access: :operate
               )

      assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :add_node)

      assert {:ok, :unmounted} = Mount.unmount_for_person(target, grantee, Target)

      assert MountRow.get_person(target, grantee, Target) == nil

      assert eventually(fn ->
               match?({:error, _reason}, dispatch(grantee, target, :add_node))
             end)

      # 幂等:再 unmount 一次仍 {:ok, :unmounted}
      assert {:ok, :unmounted} = Mount.unmount_for_person(target, grantee, Target)
    end

    test "mint 失败(无属主宿主)→ 不落 person 行" do
      owner = user_uri("pmfc-owner")
      grantee = live_agent("pmfc-holder", owner)
      target = orphan_agent("pmfc-board", [Target])

      assert {:error, {:operate_target_ownerless, _uri, Target}} =
               Mount.mount_for_person(target, grantee, Target, [:get_tree], access: :read)

      assert MountRow.get_person(target, grantee, Target) == nil
    end
  end

  describe "provision/6 — 建宿主(data_owner=owner)+ 当场挂操作钥匙" do
    setup do
      ws_name = "mount-prov-#{uniq()}"
      {:ok, _ws_pid} = Workspace.create(ws_name, %{})
      workspace_uri = Ezagent.URI.workspace(ws_name)
      {:ok, _admin_pid} = Ezagent.SpawnRegistry.spawn(User.admin_uri())

      flavor = "mount-native-#{uniq()}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil,
          cap_policy: &cap_policy/1
        })

      role = "mount-target-#{uniq()}"

      {:ok, _} =
        RecipeRegistry.seed_role_if_absent(%{
          name: role,
          passive: true,
          behaviors: [Target],
          requested_caps: [
            %{behavior: Target, action: :get_tree},
            %{behavior: Target, action: :add_node}
          ]
        })

      admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

      {:ok,
       ws_name: ws_name,
       workspace_uri: workspace_uri,
       flavor: flavor,
       role: role,
       admin_ctx: admin_ctx}
    end

    test "建出宿主 data_owner=owner、grantee 当场持操作 cap、挂载表有行", ctx do
      %{workspace_uri: workspace_uri, flavor: flavor, role: role, admin_ctx: admin_ctx} = ctx
      owner = admin_ctx.caller
      grantee = live_agent("prov-grantee", owner, [], Ezagent.URI.name!(workspace_uri))
      session = session_uri()

      spec = %{
        name: "prov-board-#{uniq()}",
        flavor: flavor,
        role: role,
        behaviors: [Target],
        actions: [:add_node, :get_tree]
      }

      assert {:ok, %{target: target, caps: caps, mount: %MountRow{} = row}} =
               Mount.provision(session, workspace_uri, spec, grantee, Target, admin_ctx)

      # 宿主 data_owner = owner(建者)—— 正是 mint 的 granter #154
      assert URI.to_string(
               Ezagent.CapabilityRegistry.data_owner_of(Target, Ezagent.URI.instance(target))
             ) == URI.to_string(owner)

      # grantee 当场持指向新宿主的操作 cap
      assert length(caps) == 2
      assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)

      # 挂载表有行
      assert row.access == "operate"
      assert MountRow.get(session, target, grantee, Target) != nil
    end
  end

  # --- helpers -------------------------------------------------------------

  # 把 recipe requested_caps 全放行,让新宿主自持它声明的动作(与 role_native 同款)。
  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  defp live_agent(name, owner, extra_behaviors \\ [], ws_name \\ "composition") do
    uri = agent_uri(name, ws_name)
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.URI.workspace(ws_name))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  # 无属主宿主:data_owner 无法解析 → mint fail-closed。
  defp orphan_agent(name, extra_behaviors) do
    uri = agent_uri(name, "composition")
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.URI.workspace("composition"))
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

  defp uniq, do: System.unique_integer([:positive])

  defp session_uri,
    do: Ezagent.URI.new!("session://composition/default/mount-#{uniq()}")

  defp user_uri(name) do
    uri = Ezagent.URI.new!("entity://composition/user/#{name}-#{uniq()}")
    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{uniq()}", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp agent_uri(name, ws_name),
    do: Ezagent.URI.new!("entity://#{ws_name}/agent/#{name}-#{uniq()}")
end
