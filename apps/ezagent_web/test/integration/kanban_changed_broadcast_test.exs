defmodule EzagentWeb.Integration.KanbanChangedBroadcastTest do
  @moduledoc """
  X1 推送环**发布侧**(㉘/㉒-① 的 kanban 半)acceptance ——
  `EzagentPluginKanban.WorldActions` 的写动作成功后,向当前会话的 UI events topic
  (`esr:session:<uri>:events`)广播 `{:kanban_changed, board_uri}`:

    (a) 写动作成功(add_node)→ 订着该 session topic 的进程(= 同会话其他成员的
        WorldLive)收到 `{:kanban_changed, board_uri}`;
    (b) 写动作失败(rename 不存在的节点)→ **不**广播(只有真变更才叫别人重拉);
    (c) socket 无当前会话(如 /plugins/kanban 独立页)→ 不广播、不炸。

  放在 ezagent_web(同 kanban_share_controller_test):它同时依赖 world 操作面
  与 kanban plugin(recipe/behavior),web 是唯一两边都在依赖箭头内的壳。
  消费半(WorldLive `handle_info({:kanban_changed, _})` 重拉 board_state)
  是 LiveView 内部推流,由真 UI e2e 回归覆盖。
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias EzagentPluginKanban.WorldActions
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "x1-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "x1-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: fn _requested -> fn _needed -> true end end
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  @tag :integration
  test "写动作成功广播 {:kanban_changed, board};失败/无会话不广播",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      board_uri =
        create_board(workspace_uri, "b-#{System.unique_integer([:positive])}", admin_ctx)

      session_uri =
        URI.new!("session://#{ws_name}/default/x1-#{System.unique_integer([:positive])}")

      {:ok, _sess_pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors(),
          owner_uri: User.admin_uri()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
      on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)

      # 本进程扮演「同会话另一个在线成员的 WorldLive」:订本会话的 UI events topic
      # (ensure_session_subscribed 用的同一 topic 形)。
      :ok =
        Phoenix.PubSub.subscribe(
          EzagentCore.PubSub,
          Ezagent.ActionSet.Session.session_events_topic(session_uri)
        )

      socket = socket_for(workspace_uri, admin_ctx, session_uri)

      # (a) 写动作成功 → 收到轻事件(payload = board URI,订阅者按自己 read_ctx 重拉)。
      {:noreply, _socket} =
        WorldActions.handle_dispatch(socket, "kanban.add_node", %{
          "kanban_uri" => URI.to_string(board_uri),
          "parent_id" => "",
          "title" => "根"
        })

      assert_receive {:kanban_changed, ^board_uri}, 2_000

      # (b) 写动作失败(节点不存在)→ 不广播。
      {:noreply, _socket} =
        WorldActions.handle_dispatch(socket, "kanban.rename_node", %{
          "kanban_uri" => URI.to_string(board_uri),
          "id" => "no-such-node",
          "title" => "x"
        })

      refute_receive {:kanban_changed, _}, 300

      # (c) 无当前会话(/plugins/kanban 独立页)→ 成功也不广播、不炸。
      no_session_socket = socket_for(workspace_uri, admin_ctx, nil)

      {:noreply, _socket} =
        WorldActions.handle_dispatch(no_session_socket, "kanban.add_node", %{
          "kanban_uri" => URI.to_string(board_uri),
          "parent_id" => "n1",
          "title" => "子"
        })

      refute_receive {:kanban_changed, _}, 300
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp socket_for(workspace_uri, %{caller: caller, caps: caps}, session_uri) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:current_entity_uri, caller)
    |> assign(:current_caps, caps)
    |> assign(:current_session_uri, session_uri)
    |> assign(:last_dispatch_status, "idle")
  end

  defp create_board(workspace_uri, name, admin_ctx) do
    {:ok, %{agent_uri: uri}} =
      Workspace.create_agent(
        workspace_uri,
        %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
        admin_ctx
      )

    uri
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
