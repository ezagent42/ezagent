defmodule Ezagent.Socialware.MountReconcileTest do
  @moduledoc """
  `Ezagent.Socialware.Mount.reconcile_session_mounts/1` —— 让运行时挂载在 session
  重建后存活。

  一个 mount 的钥匙落在 grantee 的 self-store cap slice 里;session 重启时该 slice
  重建、钥匙不会自动重发。挂载表(`MountRow`)是 mount 的 durable SoT,重启后仍在。
  reconcile 读回每条挂载行、对每条重跑发钥匙(复用 `mount/6` = mint_cap + upsert),
  使钥匙重现。幂等:mint 复用现成 issue+absorb chokepoint,重跑覆盖;挂载表仍 N 行。

  用通用 test 靶 behavior `CompositionGrantTargetBehavior`(`:get_tree` 读 +
  `:add_node` 写),参考 `mount_test.exs` 的 setup。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Mount, MountRow}

  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  describe "reconcile_session_mounts/1 — session 重启后钥匙重现" do
    test "撤钥匙(不删挂载行)模拟重启丢失 → reconcile → 钥匙重现、dispatch 又成" do
      owner = user_uri("rec-owner")
      grantee = live_agent("rec-grantee", owner)
      target = live_agent("rec-board", owner, [Target])
      session = session_uri()

      # (1) 挂一条:grantee 持钥匙、dispatch 成
      assert {:ok, %{mount: %MountRow{} = row}} =
               Mount.mount(session, target, grantee, Target, [:add_node, :get_tree],
                 access: :operate
               )

      assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :add_node)

      # (2) 撤掉钥匙模拟 session 重启丢失 self-store cap slice —— 但**不删**挂载表行
      revoke_all(grantee, target, [:add_node, :get_tree], row.granted_by)

      assert eventually(fn ->
               match?({:error, _reason}, dispatch(grantee, target, :add_node))
             end)

      # 挂载表行仍在(durable SoT 不受重启影响)
      assert MountRow.get(session, target, grantee, Target) != nil

      # (3) reconcile → 钥匙重现
      assert {:ok, %{reconciled: 1}} = Mount.reconcile_session_mounts(session)

      assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :add_node)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)
    end

    test "reconcile 幂等:连跑两次不报错、挂载表仍 N 行" do
      owner = user_uri("recidem-owner")
      grantee = live_agent("recidem-grantee", owner)
      target = live_agent("recidem-board", owner, [Target])
      session = session_uri()

      assert {:ok, _} =
               Mount.mount(session, target, grantee, Target, [:get_tree], access: :read)

      assert {:ok, %{reconciled: 1}} = Mount.reconcile_session_mounts(session)
      assert {:ok, %{reconciled: 1}} = Mount.reconcile_session_mounts(session)

      rows = MountRow.list_for_session(session)
      assert length(rows) == 1
      assert hd(rows).access == "read"

      # 钥匙仍在、只读 dispatch 成
      assert eventually(fn -> holds_cap?(grantee, target, :get_tree) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)
    end

    test "空 session(无挂载行)→ reconciled: 0" do
      session = session_uri()
      assert {:ok, %{reconciled: 0}} = Mount.reconcile_session_mounts(session)
    end
  end

  describe "reconcile_person_mounts/1 — person 行的 reconcile 路(不挂 session activate)" do
    test "撤钥匙(不删行)→ session 路扫不到、person 路重发钥匙重现" do
      owner = user_uri("prec-owner")
      grantee = live_agent("prec-holder", owner)
      target = live_agent("prec-board", owner, [Target])
      session = session_uri()

      assert {:ok, %{mount: %MountRow{scope: "person"} = row}} =
               Mount.mount_for_person(target, grantee, Target, [:get_tree], access: :read)

      assert eventually(fn -> holds_cap?(grantee, target, :get_tree) end)

      revoke_all(grantee, target, [:get_tree], row.granted_by)

      assert eventually(fn ->
               match?({:error, _reason}, dispatch(grantee, target, :get_tree))
             end)

      # person 行不属于任何 session —— session 路 reconciled: 0,钥匙不回来
      assert {:ok, %{reconciled: 0}} = Mount.reconcile_session_mounts(session)
      assert {:error, _reason} = dispatch(grantee, target, :get_tree)

      # person 路(按 grantee)重发 → 钥匙重现
      assert {:ok, %{reconciled: 1}} = Mount.reconcile_person_mounts(grantee)
      assert eventually(fn -> holds_cap?(grantee, target, :get_tree) end)
      assert {:ok, %{ok: true}} = dispatch(grantee, target, :get_tree)
    end

    test "幂等,且与同 grantee 的 session 行互不干扰(各扫各的行)" do
      owner = user_uri("pmix-owner")
      grantee = live_agent("pmix-holder", owner)
      target = live_agent("pmix-board", owner, [Target])
      session = session_uri()

      assert {:ok, _} = Mount.mount(session, target, grantee, Target, [:get_tree], access: :read)

      assert {:ok, _} =
               Mount.mount_for_person(target, grantee, Target, [:get_tree], access: :read)

      assert {:ok, %{reconciled: 1}} = Mount.reconcile_session_mounts(session)
      assert {:ok, %{reconciled: 1}} = Mount.reconcile_person_mounts(grantee)
      assert {:ok, %{reconciled: 1}} = Mount.reconcile_person_mounts(grantee)

      assert length(MountRow.list_for_session(session)) == 1
      assert length(MountRow.list_person_mounts_for_grantee(grantee)) == 1
    end

    test "无 person 行的 grantee → reconciled: 0" do
      assert {:ok, %{reconciled: 0}} = Mount.reconcile_person_mounts(user_uri("nobody"))
    end
  end

  # --- helpers -------------------------------------------------------------

  # 撤销 grantee 指向 target 的每把 action 钥匙,granter = 挂载行 granted_by(宿主主人)。
  # 走 `{:held_by, granter}` 授权(#1457 后 rule 元组已删;与 mount.ex unmount 同款)。
  defp revoke_all(grantee, target, actions, granted_by) do
    granter = Ezagent.URI.new!(granted_by)
    workspace_uri = Ezagent.Capability.workspace_of(target)
    target_instance = Ezagent.URI.instance(target)

    Enum.each(actions, fn action ->
      cap = Ezagent.Capability.cap(:agent, Target, action, target_instance, workspace_uri)

      :ok =
        Ezagent.Identity.Grant.revoke_cap(
          grantee,
          cap,
          {:held_by, granter}
        )
    end)
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

  defp uniq, do: System.unique_integer([:positive])

  defp session_uri,
    do: Ezagent.URI.new!("session://composition/default/mountrec-#{uniq()}")

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
