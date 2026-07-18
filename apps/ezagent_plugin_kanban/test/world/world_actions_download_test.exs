defmodule EzagentPluginKanban.WorldActionsDownloadTest do
  @moduledoc """
  ㊲ 附件点击现签（kanban 半）acceptance：

    (a) 渲染读模型（`WorldData.board_snapshot`）**不再预签**下载 href——file 附件的
        url 原样是 uploads resource URI（预签 TTL 300s 打开即过期是 r3 ㊲ 的根因半）；
    (b) `kanban.download_artifact` dispatch 点击现签：回推 world:state
        `download.href`（fresh DownloadToken，verify 回原 uploads URI）+ `ts`；
    (c) ref 不存在（或 kind 非 file）→ `error:artifact_not_found`，不回推 download。
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias EzagentPluginKanban.{WorldActions, WorldData}
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "dl-native"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "dl-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: fn _requested -> fn _needed -> true end end
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KanbanApp.kanban_manager_recipe())

    # #1457 per-Kind signing:ambient genesis wildcard 不再过验签,ctx 走
    # signed_workspace_ctx!(canonical admin 经 workspace Kind 目标签名)。
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  @tag :integration
  test "㊲ 渲染不预签 + 点击现签 fresh token + 找不到附件报错",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      board_uri =
        create_board(workspace_uri, "b-#{System.unique_integer([:positive])}", admin_ctx)

      socket = socket_for(workspace_uri, with_board_caps(admin_ctx, board_uri))
      upload_uri = "resource://#{ws_name}/uploads/#{Ecto.UUID.generate()}-report.pdf"

      {:noreply, _} =
        WorldActions.handle_dispatch(socket, "kanban.add_node", %{
          "kanban_uri" => URI.to_string(board_uri),
          "parent_id" => "",
          "title" => "根"
        })

      {:noreply, _} =
        WorldActions.handle_dispatch(socket, "kanban.attach_artifact", %{
          "kanban_uri" => URI.to_string(board_uri),
          "id" => "n1",
          "artifact" => %{
            "tool" => "upload",
            "kind" => "file",
            "ref" => "报告",
            "url" => upload_uri
          }
        })

      # (a) 读模型不预签：file 附件 url 原样是 uploads resource URI。
      snapshot =
        WorldData.board_snapshot(
          board_uri,
          read_ctx(workspace_uri, with_board_caps(admin_ctx, board_uri))
        )
      [art] = get_in(snapshot, ["tree", "nodes", "n1", "artifacts"])
      assert art["url"] == upload_uri

      # (b) 点击现签：download_artifact 回推 fresh href，token verify 回原 uploads URI。
      {:noreply, pushed} =
        WorldActions.handle_dispatch(socket, "kanban.download_artifact", %{
          "kanban_uri" => URI.to_string(board_uri),
          "id" => "n1",
          "ref" => "报告"
        })

      assert pushed.assigns.last_dispatch_status == "ok"

      assert [["world:state", %{"download" => download}] | _] =
               pushed.private.live_temp[:push_events]

      assert download["ref"] == "报告"
      assert is_integer(download["ts"])
      assert "/uploads/download?token=" <> token = download["href"]
      assert {:ok, verified} = Ezagent.Uploads.DownloadToken.verify(token)
      assert URI.to_string(verified) == upload_uri

      # (c) ref 不存在 → artifact_not_found，不回推 download。
      {:noreply, missed} =
        WorldActions.handle_dispatch(socket, "kanban.download_artifact", %{
          "kanban_uri" => URI.to_string(board_uri),
          "id" => "n1",
          "ref" => "没有这个"
        })

      assert missed.assigns.last_dispatch_status == "error:artifact_not_found"

      refute Enum.any?(missed.private.live_temp[:push_events] || [], fn [_, p] ->
               p["download"]
             end)
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp socket_for(workspace_uri, %{caller: caller, caps: caps}) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:current_entity_uri, caller)
    |> assign(:current_caps, caps)
    |> assign(:current_session_uri, nil)
    |> assign(:last_dispatch_status, "idle")
  end

  # #1457 per-Kind signing:workspace ctx 的 :any/:any cap 不再覆盖 agent-kind 的
  # kanban 动作——按板逐动作现签(经板 Kind 的 grant verifier),并进 socket caps。
  defp with_board_caps(%{caller: caller, caps: caps} = ctx, board_uri) do
    board_caps =
      for action <- Ezagent.ActionSet.action_names(Ezagent.ActionSet.Kanban) do
        target = Ezagent.URI.with_action(board_uri, :kanban, action)
        Ezagent.Test.CapHelper.signed_action_cap!(target, caller)
      end

    %{ctx | caps: MapSet.union(MapSet.new(caps), MapSet.new(board_caps))}
  end

  defp read_ctx(workspace_uri, %{caller: caller, caps: caps}),
    do: %{caller_uri: caller, caller_caps: caps, workspace_uri: workspace_uri}

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
