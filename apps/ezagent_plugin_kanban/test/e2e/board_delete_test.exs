defmodule EzagentPluginKanban.E2E.BoardDeleteTest do
  @moduledoc """
  ⑲ acceptance —— 删板入口 `Ezagent.Socialware.BoardProvision.delete_board/3`:
  板 = kanban-manager agent,建板人(= data_owner)持 Manage cap(建板时 create-entry
  授予),删板 = **cap-epoch 撤钥匙**(`Ezagent.Cap.revoke_all_to/2` 在 destroy 前 bump
  板的 authority generation → 指向板的所有 cap 一次性验签失效)+ 语义命令 `manage.delete`
  dispatch(经 Lifecycle.destroy,不直调 terminate)+ 挂载表 bookkeeping 删行。

  证三件事:
    (a) 非板主人(路人)删板 → `{:error, :not_board_owner}`(板/挂载全不动);
    (b) 板主人删板 → `{:ok, %{deleted: true}}`,板 agent 退場(KindRegistry 查无),
        挂载表指向该板的行清空;
    (c) 钥匙随 cap-epoch 撤销 —— 建板人指向该板的 Kanban cap **不再验签有效**
        (cap-epoch:撤销 = 失效不删除,故断言查**有效性**非**存在性**)。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.BoardProvision
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "t19-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "t19-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    # #1457 per-Kind signing:ambient genesis wildcard 不再过验签,ctx 走
    # signed_workspace_ctx!(canonical admin 经 workspace Kind 目标签名)。
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  @tag :integration
  test "⑲ 删板: 板主人可删(退休 agent + 清挂载 + 撤钥匙);非主人拒",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      owner_uri =
        URI.new!("entity://#{ws_name}/user/board-owner-#{System.unique_integer([:positive])}")

      {:ok, _owner_pid} =
        Ezagent.Kind.spawn(User, %{uri: owner_uri, initial_caps: MapSet.new()})

      owner_ctx = %{caller: owner_uri, caps: Ezagent.Identity.list_caps_for(owner_uri)}

      session_uri =
        URI.new!("session://#{ws_name}/default/t19-#{System.unique_integer([:positive])}")

      {:ok, _sess_pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors(),
          owner_uri: owner_uri
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
      on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)
      :ok = join_member(session_uri, owner_uri, "member", admin_ctx)

      board_name = "board-del-#{System.unique_integer([:positive])}"

      assert {:ok, %{board_uri: board_uri}} =
               BoardProvision.create_board(
                 workspace_uri,
                 session_uri,
                 %{
                   name: board_name,
                   board_role: "kanban-manager",
                   flavor: @flavor,
                   assistant_role: "kanban-assistant"
                 },
                 Ezagent.ActionSet.Kanban,
                 owner_ctx
               )

      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(board_uri)
      assert eventually(fn -> board_cap_valid?(owner_uri, board_uri, :add_node) end)
      assert MountRow.list_for_target(board_uri) != []

      # (a) 非板主人 → 拒,板/挂载全不动。
      stranger_uri =
        URI.new!("entity://#{ws_name}/user/stranger-#{System.unique_integer([:positive])}")

      {:ok, _} = Ezagent.Kind.spawn(User, %{uri: stranger_uri, initial_caps: MapSet.new()})
      on_exit(fn -> Ezagent.Kind.terminate(stranger_uri) end)

      assert {:error, :not_board_owner} =
               BoardProvision.delete_board(board_uri, Ezagent.ActionSet.Kanban, %{
                 caller: stranger_uri,
                 caps: MapSet.new()
               })

      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(board_uri)
      assert MountRow.list_for_target(board_uri) != []

      # (b) 板主人删板成功(caps 刷新 —— 建板时 create-entry 授了 Manage cap)。
      owner_ctx_fresh = %{caller: owner_uri, caps: Ezagent.Identity.list_caps_for(owner_uri)}

      assert {:ok, %{deleted: true}} =
               BoardProvision.delete_board(board_uri, Ezagent.ActionSet.Kanban, owner_ctx_fresh)

      # 板 agent 退场(manage.delete 在 reply 后 detached Task 里 destroy → eventually)。
      assert eventually(fn -> match?(:error, Ezagent.KindRegistry.lookup(board_uri)) end)

      # 挂载表指向该板的行清空。
      assert MountRow.list_for_target(board_uri) == []

      # (c) 钥匙随 cap-epoch 撤销:建板人指向该板的 Kanban cap 不再验签有效
      # (cap 仍在 store,但板 authority generation 已 bump → verify_against_current false)。
      assert eventually(fn -> not board_cap_valid?(owner_uri, board_uri, :add_node) end)
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp join_member(session_uri, member_uri, role_name, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    caps =
      MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller) | Enum.to_list(caps)])

    case Invocation.dispatch(%Invocation{
           origin: :trusted_internal,
           target: target,
           mode: :call,
           args: %{member: member_uri, role_name: role_name},
           ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> flunk("join failed: #{inspect(other)}")
    end
  end

  # cap-epoch:撤销 = 验签失效不删除,故删板后 cap 仍在 holder store(presence 恒 true),
  # 断言必须查**有效性**:该板 cap 是否仍能对板当前 authority generation 验签通过。
  # `verify_against_current(cap, presenter, target)` —— presenter = grantee(cap.grantee_uri),
  # target = 板 URI;板 destroy + generation bump 后 key_id 对不上 / 无 active row → false。
  defp board_cap_valid?(grantee, board_uri, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      cap.kind == :agent and cap.behavior == Ezagent.ActionSet.Kanban and
        cap.action == action and
        cap.instance == Ezagent.URI.instance(board_uri) and
        Ezagent.Cap.Authority.verify_against_current(cap, grantee, board_uri)
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
