defmodule EzagentWeb.Socialware.KanbanShareControllerTest do
  @moduledoc """
  T6.4 acceptance —— 分享看板（生成链接 → 点击把板只读加进对方 session tab）。

  两块：
    * **分享侧** `Ezagent.World.KanbanActions.share_link/2`：板主人（对板有 access）→
      得到一个可 `Phoenix.Token.verify` 的只读 token 链接；无 access 的路人 → `{:error,
      :no_access}`。
    * **接收侧** `GET /socialware/kanban/receive?token=`（**只带 token**，session 服务端解析）
      （`EzagentWeb.Socialware.KanbanShareController`）：有效 token → 控制器从登录者身份解析
      其带 kanban-assistant 的 session → 板只读挂进该 session（`MountRow` 有 `access="read"`
      行）+ 点击者 kanban-assistant 自身份 dispatch `kanban.get_tree` 成、`kanban.add_node`
      被拒（只读）；成功 302 落到该 session 的 world 会话页；无效/篡改 token → 403、不挂载。

  端到端：接收侧用的 token 就是分享侧用板主人 socket 真签出来的（同 salt/endpoint）。
  """

  use EzagentWeb.ConnCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry, Invocation}
  alias Ezagent.Socialware.MountRow
  alias EzagentPluginKanban.WorldActions, as: KanbanActions
  alias EzagentPluginHello.PublishedBoardRef
  alias EzagentWeb.Socialware.KanbanPublishedReadAdapter
  alias EzagentPluginKanban.Application, as: KanbanApp

  @flavor "t64-native"
  @share_salt "world_kanban_share"
  @share_max_age 604_800
  @read_actions [:get_tree, :export_markmap]

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "t64-#{u()}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      authenticated_principal: User.admin_uri(),
      caps: MapSet.new()
    }

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

  # ── (a) 分享侧：share_link ────────────────────────────────────────────

  @tag :integration
  test "share_link: 板主人得到可 verify 的只读 token 链接;无 access 的路人被拒",
       %{ws_name: ws_name, workspace_uri: workspace_uri} do
    skip_if_no_entity_spawn(fn ->
      owner_ctx = user_with_create_cap(ws_name, workspace_uri, "owner")
      board_uri = create_board_owned_by(workspace_uri, "b-#{u()}", owner_ctx)

      # 板主人 socket → 得到接收链接，token 可 verify 回 board + 只读意图
      assert {:ok, link} = KanbanActions.share_link(share_socket(owner_ctx), s(board_uri))
      assert String.starts_with?(link, "/socialware/kanban/receive?token=")

      token = extract_token(link)

      assert {:ok, payload} =
               Phoenix.Token.verify(@endpoint, @share_salt, token, max_age: @share_max_age)

      assert payload["board"] == s(board_uri)
      assert payload["behavior"] == "Ezagent.ActionSet.Kanban"
      assert payload["access"] == "read"

      # 无 access 的路人（非板主人、无 cap）→ 拒
      stranger = spawn_user(ws_name, "stranger")

      stranger_ctx = %{
        caller: stranger,
        authenticated_principal: stranger,
        caps: MapSet.new()
      }

      assert {:error, :no_access} =
               KanbanActions.share_link(share_socket(stranger_ctx), s(board_uri))

      # 坏 URI → 拒
      assert {:error, :bad_kanban_uri} =
               KanbanActions.share_link(share_socket(owner_ctx), "not a uri")
    end)
  end

  # ── (b) 接收侧：GET /socialware/kanban/receive ───────────────────────

  @tag :integration
  test "receive: 有效 token → 只读挂进点击者 session(get_tree 成/add_node 拒);篡改 token → 403",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, conn: conn} do
    skip_if_no_entity_spawn(fn ->
      owner_ctx = user_with_create_cap(ws_name, workspace_uri, "owner")
      board_uri = create_board_owned_by(workspace_uri, "b-#{u()}", owner_ctx)

      # 在板上建个根（admin 身份，板主人不持板动作 cap），好让只读读到东西
      assert {:ok, %{id: "n1"}} =
               board_dispatch(board_uri, :add_node, %{parent_id: "", title: "根"}, admin_ctx)

      # 点击者 = 登录用户，在自己的 session（有 kanban-assistant 成员 + clicker 是成员）
      clicker = spawn_user(ws_name, "clicker")

      {clicker_session, clicker_assistant} =
        clicker_session(ws_name, workspace_uri, clicker, admin_ctx)

      # 官网 Session 1 显式发布；再次发布沿同一 board URI 递增 revision，
      # 只更新接收引用，不复制 Kanban tree。
      publish_ctx =
        owner_ctx
        |> Map.put(:workspace_uri, workspace_uri)
        |> Map.put(:endpoint, @endpoint)

      assert {:ok, %PublishedBoardRef{revision: 1} = published} =
               KanbanPublishedReadAdapter.publish_board_read(
                 publish_ctx,
                 URI.new!("session://#{ws_name}/default/author"),
                 board_uri
               )

      assert {:ok, %PublishedBoardRef{revision: 2} = republished} =
               KanbanPublishedReadAdapter.refresh_published_board(publish_ctx, published)

      assert PublishedBoardRef.identity_key(republished) ==
               PublishedBoardRef.identity_key(published)

      token = extract_token(republished.receive_ref)

      out =
        conn
        |> sign_in(ws_name, clicker)
        |> get(~p"/socialware/kanban/receive?#{[token: token]}")

      # 成功 → 302 重定向到接收者 session 的 world 会话页（服务端解析出的正是 clicker_session）
      assert redirected_to(out) =~ "/sessions?session="
      assert redirected_to(out) =~ URI.encode_www_form(s(clicker_session))

      # 挂载表有指向该板的 read 行
      row = MountRow.get(clicker_session, board_uri, clicker_assistant, Ezagent.ActionSet.Kanban)
      assert row != nil
      assert row.access == "read"

      assert Enum.map(row_actions(row), &to_string/1) |> Enum.sort() ==
               Enum.map(@read_actions, &to_string/1) |> Enum.sort()

      # 点击者 assistant 持只读钥匙：get_tree 成、add_node（写）拒
      assert eventually(fn -> holds_board_cap?(clicker_assistant, board_uri, :get_tree) end)
      refute holds_board_cap?(clicker_assistant, board_uri, :add_node)
      assert {:ok, %{tree: _}} = dispatch_as(clicker_assistant, board_uri, :get_tree, %{})

      assert {:error, :missing_cap} =
               dispatch_as(clicker_assistant, board_uri, :add_node, %{parent_id: "n1", title: "子"})

      # 同一发布链接重复接收按 mount 自然键幂等，不产生第二份板数据/挂载。
      again =
        conn
        |> sign_in(ws_name, clicker)
        |> get(~p"/socialware/kanban/receive?#{[token: token]}")

      assert redirected_to(again) =~ "/sessions?session="

      assert MountRow.list_for_session(clicker_session)
             |> Enum.count(&(&1.target_uri == s(board_uri))) == 1

      # 篡改 token → 403、不新增挂载
      bad =
        conn
        |> sign_in(ws_name, clicker)
        |> get(~p"/socialware/kanban/receive?#{[token: "garbage"]}")

      assert bad.status == 403
    end)
  end

  @tag :integration
  test "receive: 匿名(未登录)被 RequireEntity 挡在 /login",
       %{conn: conn} do
    out = get(conn, ~p"/socialware/kanban/receive?#{[token: "x"]}")

    assert redirected_to(out) == "/login"
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])
  defp s(%URI{} = uri), do: URI.to_string(uri)

  defp share_socket(%{caller: %URI{} = caller, caps: caps}) do
    socket =
      %Phoenix.LiveView.Socket{endpoint: @endpoint}
      |> Phoenix.Component.assign(:current_entity_uri, caller)
      |> Phoenix.Component.assign(:current_caps, caps)
      |> Phoenix.Component.assign(:current_workspace_uri, workspace_of(caller))

    # Mirror how world_live / KanbanPublishedReadAdapter inject the presenter's
    # caps before reaching `WorldActions.share_link/2` (#1476): the plugin reads
    # the `:presenter_caps` assign, never `Ezagent.World.PresenterCaps` directly.
    Phoenix.Component.assign(
      socket,
      :presenter_caps,
      Ezagent.World.PresenterCaps.load(socket)
    )
  end

  # entity://<ws>/user/... → workspace://<ws>（read_ctx 需要 current_workspace_uri）。
  defp workspace_of(%URI{host: ws}), do: URI.new!("workspace://#{ws}")

  defp sign_in(conn, ws, %URI{} = entity_uri) do
    case Ezagent.Users.get_by_uri(entity_uri) do
      nil -> {:ok, _user} = Ezagent.Users.create(URI.to_string(entity_uri), nil, [])
      _user -> :ok
    end

    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => "workspace://" <> ws
    })
  end

  defp extract_token(link) do
    %URI{query: query} = URI.parse(link)
    query |> URI.decode_query() |> Map.fetch!("token")
  end

  defp user_with_create_cap(ws_name, workspace_uri, label) do
    user_uri = URI.new!("entity://#{ws_name}/user/#{label}-#{u()}")

    requested =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :create_agent,
        workspace_uri,
        workspace_uri
      )

    {:ok, create_cap} =
      Ezagent.Cap.issue({:admin, User.admin_uri()}, user_uri, requested)

    {:ok, _row} = Ezagent.Users.create(user_uri, "test-password", [create_cap])
    :ok = Ezagent.Entity.spawn_principal(user_uri)

    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)

    %{
      caller: user_uri,
      authenticated_principal: user_uri,
      caps: Ezagent.Identity.list_caps_for(user_uri)
    }
  end

  defp spawn_user(ws_name, label) do
    user_uri = URI.new!("entity://#{ws_name}/user/#{label}-#{u()}")
    {:ok, _row} = Ezagent.Users.create_read_only(user_uri, [])
    :ok = Ezagent.Entity.spawn_principal(user_uri)
    # Read-plane PR-4 rework: the receive flow resolves the clicker's
    # sessions through `WorkspaceReads.sessions/2`, which requires the
    # caller to be a DECLARED workspace member (the workspace gate).
    # Direct store write — the full add_member dispatch chain needs the
    # admin Kind, which is not part of this fixture.
    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [user_uri])
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)
    user_uri
  end

  defp create_board_owned_by(workspace_uri, name, ctx) do
    assert {:ok, %{agent_uri: uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: @flavor, name: name, role: "kanban-manager", cwd: "", with_pty: false},
               ctx
             )

    uri
  end

  # 点击者自己的 session：clicker 是成员 + 一个 kanban-assistant 成员（收只读钥匙）。
  defp clicker_session(ws_name, workspace_uri, clicker_uri, admin_ctx) do
    assistant_uri = live_agent(ws_name, "kanban-assistant-#{u()}")
    session_uri = URI.new!("session://#{ws_name}/default/t64-#{u()}")

    {:ok, _sess_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.Kind.terminate(session_uri) end)

    :ok = join_member(session_uri, clicker_uri, "member", admin_ctx)
    :ok = join_member(session_uri, assistant_uri, "kanban-assistant", admin_ctx)

    {session_uri, assistant_uri}
  end

  defp live_agent(ws_name, name) do
    uri = Ezagent.URI.agent(ws_name, name)
    owner = User.admin_uri()

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors(),
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, URI.new!("workspace://#{ws_name}"))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp join_member(session_uri, member_uri, role_name, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    caps = caps_for_target(caller, caps, target)

    case Invocation.dispatch(%Invocation{
           origin: :trusted_internal,
           target: target,
           mode: :call,
           args: %{member: member_uri, role_name: role_name},
           ctx: %{
             caller: caller,
             authenticated_principal: caller,
             caps: caps,
             reply: {:caller_inbox, self()}
           }
         }) do
      :ok -> converge_member_projection(session_uri, member_uri, role_name)
      {:ok, _} -> converge_member_projection(session_uri, member_uri, role_name)
      other -> flunk("join failed: #{inspect(other)}")
    end
  end

  defp converge_member_projection(session_uri, member_uri, role_name) do
    assert eventually(fn ->
             held = Ezagent.EntityCaps.load_persisted(member_uri)
             Ezagent.Session.MemberReceive.holds_member_cap_over?(member_uri, held, session_uri)
           end)

    target = Ezagent.URI.with_action(session_uri, :session, :add_self)

    case Invocation.dispatch(%Invocation{
           origin: :trusted_internal,
           target: target,
           mode: :call,
           args: %{member: member_uri, facets: %{role_name: role_name}},
           ctx: %{
             caller: member_uri,
             authenticated_principal: member_uri,
             caps: MapSet.new(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{status: status}} when status in [:added, :already_member] -> :ok
      other -> flunk("member projection failed: #{inspect(other)}")
    end
  end

  defp board_dispatch(board_uri, action, args, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.with_action(board_uri, :kanban, action)
    caps = caps_for_target(caller, caps, target)

    Ezagent.Router.dispatch(
      Ezagent.Cmd.new(
        target,
        action,
        args,
        %{
          mode: :call,
          caller: caller,
          authenticated_principal: caller,
          caps: caps,
          reply: {:caller_inbox, self()}
        }
      )
    )
  end

  defp caps_for_target(caller, caps, target) do
    if caller == User.admin_uri() do
      {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, caller}, caller, target)
      MapSet.put(caps, cap)
    else
      caps
    end
  end

  defp dispatch_as(caller_uri, board_uri, action, args) do
    board_dispatch(board_uri, action, args, %{
      caller: caller_uri,
      authenticated_principal: caller_uri,
      caps: MapSet.new(Ezagent.Identity.list_caps_for(caller_uri))
    })
  end

  defp holds_board_cap?(grantee, board_uri, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      cap.kind == :agent and cap.behavior == Ezagent.ActionSet.Kanban and
        cap.action == action and
        cap.instance == Ezagent.URI.instance(board_uri)
    end)
  end

  defp row_actions(%MountRow{actions_json: json}) when is_binary(json) do
    {:ok, list} = Jason.decode(json)
    list
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
