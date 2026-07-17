defmodule EzagentPluginKanban.WorldActions do
  @moduledoc """
  Socket-side dispatch handlers for the world **kanban operating surface**。

  对齐 `Ezagent.World.ConversationActions` 的分工：`WorldLive` 保持瘦 `handle_event`
  子句、经 `Ezagent.World.PluginPageRegistry` 条目的 `actions_module` 反射委派到这里
  （债②可搬半 2026-07-17：本模块从 world 搬进 kanban plugin，world 只留 @pages
  注册数据；dep 方向 world → plugin_kanban，本模块不得反向引 world 模块）。

  ## kanban-as-role（K4）
  看板 = 一个 agent（role `kanban-manager` × flavor `native`），board = 该 agent 的
  `:kanban` snapshot slice。所有节点动作经
  `Ezagent.URI.with_action(entity://<ws>/agent/<id>, :kanban, action)` =
  `entity://<ws>/agent/<id>?action=kanban.<action>` dispatch（不再 `resource://kanban`）。
  **ctx 带登录者 `current_entity_uri`/`current_caps`**（R3：caller=人类用户，不重写成
  agent）——per-node owner 授权在 Behavior 内如实判，world 层不放水。动作成功后 re-read
  树 + `push_event("world:state")` 刷前端。**新建看板** = `Ezagent.Workspace.create_agent`
  （role × native，RF-5a），不再合成 `resource://` URI。

  本模块退成**纯 dispatcher**：连接器逻辑（Miro / BoardConfig / Ci 等）全部住在
  `Ezagent.ActionSet.Kanban` 的动作里（register_pr / attach_code_file / sync_miro /
  set_board_config / save_miro_creds）。GitHub 主动连接器（sync_github / push_pr /
  sync_prs / save_github_creds）已整体退役——gh 连通现在是 agent 的 CLI 行为，不走
  world 派发；留下的 register_pr / attach_code_file 是纯数据（拼 git 链接挂节点）。
  本模块只 dispatch + 刷 UI，world 侧不再持有任何 kanban 数据/动作代码。dormant 的
  passive kanban-manager 经 `WorldData.ensure_spawned/1` 从快照 rehydrate 起活。
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.Invocation
  alias EzagentPluginKanban.WorldData

  # kanban-as-role：新建看板 = 创建 role `kanban-manager` × flavor `native` 的 agent。
  @kanban_role "kanban-manager"
  @native_flavor "native"

  @doc "把 `kanban.*` 动作路由到处理器。"
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "kanban.add_node", %{"kanban_uri" => u, "title" => t} = a)
      when is_binary(t),
      do: act(socket, u, :add_node, %{parent_id: Map.get(a, "parent_id", ""), title: t})

  def handle_dispatch(socket, "kanban.rename_node", %{
        "kanban_uri" => u,
        "id" => id,
        "title" => t
      }),
      do: act(socket, u, :rename_node, %{id: id, title: t})

  def handle_dispatch(socket, "kanban.move_node", %{"kanban_uri" => u, "id" => id} = a),
    do: act(socket, u, :move_node, %{id: id, new_parent_id: Map.get(a, "new_parent_id", "")})

  def handle_dispatch(socket, "kanban.remove_node", %{"kanban_uri" => u, "id" => id}),
    do: act(socket, u, :remove_node, %{id: id})

  def handle_dispatch(socket, "kanban.set_stage", %{"kanban_uri" => u, "id" => id, "stage" => s}),
    do: act(socket, u, :set_stage, %{id: id, stage: s})

  def handle_dispatch(socket, "kanban.claim_node", %{"kanban_uri" => u, "id" => id}),
    do: act(socket, u, :claim_node, %{id: id})

  def handle_dispatch(socket, "kanban.unclaim_node", %{"kanban_uri" => u, "id" => id}),
    do: act(socket, u, :unclaim_node, %{id: id})

  def handle_dispatch(socket, "kanban.set_status", %{
        "kanban_uri" => u,
        "id" => id,
        "status" => s
      }),
      do: act(socket, u, :set_status, %{id: id, status: s})

  def handle_dispatch(socket, "kanban.attach_artifact", %{
        "kanban_uri" => u,
        "id" => id,
        "artifact" => art
      })
      when is_map(art),
      do: act(socket, u, :attach_artifact, %{id: id, artifact: art})

  def handle_dispatch(socket, "kanban.detach_artifact", %{
        "kanban_uri" => u,
        "id" => id,
        "ref" => ref
      }),
      do: act(socket, u, :detach_artifact, %{id: id, ref: ref})

  def handle_dispatch(socket, "kanban.set_metric", %{
        "kanban_uri" => u,
        "id" => id,
        "metric" => m
      })
      when is_map(m),
      do: act(socket, u, :set_metric, %{id: id, metric: m})

  def handle_dispatch(socket, "kanban.drop_subtree", %{"kanban_uri" => u, "id" => id} = a),
    do: act(socket, u, :drop_subtree, %{id: id, reason: Map.get(a, "reason", "")})

  def handle_dispatch(socket, "kanban.create", %{"name" => name}) when is_binary(name),
    do: create_kanban(socket, name)

  def handle_dispatch(socket, "kanban.select_board", %{"kanban_uri" => u}),
    do: select_board(socket, u)

  # 一键推 Miro：dispatch → 拿 board_id → 推 miro_board_url（出站动作，结果带链接）。
  # name = 前端同步弹框填的 Miro 板名（去gh 决策），透传给 behavior（缺省用板配置/URI 名）。
  def handle_dispatch(socket, "kanban.sync_miro", %{"kanban_uri" => u} = a),
    do: sync_miro(socket, u, Map.get(a, "name"))

  def handle_dispatch(socket, "kanban.save_miro_creds", %{"access_token" => token} = a)
      when is_binary(token),
      do:
        act_board(socket, kanban_uri(socket, a), :save_miro_creds, %{
          access_token: token,
          board_id: Map.get(a, "board_id", "")
        })

  def handle_dispatch(socket, "kanban.set_board_config", %{"kanban_uri" => u} = a),
    do:
      act_board(socket, u, :set_board_config, %{
        github_repo: Map.get(a, "github_repo", ""),
        miro_board: Map.get(a, "miro_board", "")
      })

  def handle_dispatch(
        socket,
        "kanban.attach_upload",
        %{"kanban_uri" => u, "id" => id, "grant" => grant} = a
      )
      when is_binary(grant),
      do: attach_upload(socket, u, id, grant, Map.get(a, "name", "file"))

  def handle_dispatch(socket, "kanban.register_pr", %{"kanban_uri" => u, "id" => id, "pr" => pr}),
    do: act(socket, u, :register_pr, %{id: id, pr: to_string(pr)})

  def handle_dispatch(socket, "kanban.attach_code_file", %{
        "kanban_uri" => u,
        "id" => id,
        "sha" => sha,
        "path" => path
      })
      when is_binary(sha) and is_binary(path),
      do: act(socket, u, :attach_code_file, %{id: id, sha: sha, path: path})

  def handle_dispatch(socket, "kanban.share_board", %{"kanban_uri" => u}) when is_binary(u),
    do: share_board(socket, u)

  # ⑲ 删板:板主人(建板人)删除自己的板(语义命令 manage.delete + 清挂载,授权在
  # BoardProvision.delete_board —— caller==data_owner + Manage cap 过 dispatch 校验)。
  def handle_dispatch(socket, "kanban.delete_board", %{"kanban_uri" => u}) when is_binary(u),
    do: delete_board(socket, u)

  def handle_dispatch(socket, _action, _args),
    do: {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}

  # 上传 grant 校验（同 ConversationActions 的 anti-laundering：Phoenix.Token + uri↔caller↔session）。
  @upload_grant_salt "world_attach"
  @upload_grant_max_age 86_400

  # 分享看板 token（T6.4）：照本模块 upload-grant 的 Phoenix.Token 模式（sign/verify +
  # salt + max_age）。分享时校验发起人 access → 把 board + 只读意图签进 token → 拼接收链接；
  # 接收侧（ezagent_web `KanbanShareController`）用同 salt/max_age verify + 直接
  # `Mount.mount` 只读挂进点击者 session。
  # salt/max_age 必须与接收侧常量逐一对齐；max_age（7 天）在接收侧 verify 时校验。
  @share_board_salt "world_kanban_share"
  # behavior 以字符串入 token（token payload 是 JSON-safe 字符串契约；接收侧
  # `Module.concat` 反解，同 `Mount.decode_behavior` 约定）。
  @share_board_behavior "Ezagent.ActionSet.Kanban"
  @share_board_receive_path "/socialware/kanban/receive"

  # --- 动作：dispatch（登录者身份）→ re-read 树 → push tree --------------

  defp act(socket, uri_str, action, args) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = WorldData.ensure_spawned(uri)
        target = Ezagent.URI.with_action(uri, :kanban, action)

        result =
          Invocation.dispatch(%Invocation{
            target: target,
            mode: :call,
            args: args,
            ctx: ctx(socket),
            origin: :authenticated_external
          })

        status = status_of(result)
        if status == "ok", do: broadcast_kanban_changed(socket, uri)

        {:noreply, push_tree(socket, uri, status)}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # 图级动作（set_board_config / save_miro_creds）：dispatch → 推全量 board 快照（含
  # 刷新的 config / miro 状态），让前端连接器面同步。
  defp act_board(socket, uri_str, action, args) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = WorldData.ensure_spawned(uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(uri, :kanban, action),
            mode: :call,
            args: args,
            ctx: ctx(socket),
            origin: :authenticated_external
          })

        status = status_of(result)
        if status == "ok", do: broadcast_kanban_changed(socket, uri)

        {:noreply,
         socket
         |> assign(:last_dispatch_status, status)
         |> push_event(
           "world:state",
           Map.put(WorldData.board_state(uri, read_ctx(socket)), "last_dispatch_status", status)
         )}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- 一键推 Miro：dispatch → board_id → 推 miro_board_url -----------------

  defp sync_miro(socket, uri_str, name) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = WorldData.ensure_spawned(uri)

        args = if is_binary(name) and name != "", do: %{name: name}, else: %{}

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(uri, :kanban, :sync_miro),
            mode: :call,
            args: args,
            ctx: ctx(socket),
            origin: :authenticated_external
          })

        case result do
          {:ok, %{board_id: board}} ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", %{
               "miro_board_url" => "https://miro.com/app/board/#{board}",
               "last_dispatch_status" => "ok"
             })}

          _ ->
            {:noreply, assign(socket, :last_dispatch_status, status_of(result))}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- 分享看板（T6.4）：校验 access → 签只读 token → 拼接收链接 -----------------

  @doc """
  分享看板 = 生成一个只读接收链接。

  ① 校验发起人对这块板有 access —— 以自身份（登录者）dispatch `kanban.get_tree` 探针，
     cap 校验落 dispatch chokepoint（不直读 cap 列表，同
     `Ezagent.Socialware.BoardProvision.session_holds_board_cap?` 思路）；
  ② `Phoenix.Token.sign` 把 board_uri + behavior + 只读意图签成 token（照本模块
     upload-grant 的 sign/verify + salt + max_age 模式）；
  ③ 拼成接收链接（接收 route 见 `EzagentWeb.Socialware.KanbanShareController`）。

  授权只在**分享时**查（token 携带凭证），接收侧只管挂。返回 `{:ok, link}`（发起人有
  access）或 `{:error, :no_access | :bad_kanban_uri}`。
  """
  @spec share_link(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, String.t()} | {:error, :no_access | :bad_kanban_uri}
  def share_link(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        if share_access?(socket, uri),
          do: {:ok, build_share_link(socket, uri)},
          else: {:error, :no_access}

      :error ->
        {:error, :bad_kanban_uri}
    end
  end

  defp share_board(socket, uri_str) do
    case share_link(socket, uri_str) do
      {:ok, link} ->
        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_event("world:state", %{"share_link" => link, "last_dispatch_status" => "ok"})}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason}")}
    end
  end

  # 发起人对板是否有 access：复用 world 的发现可见性谓词（admin / 板主人 data_owner / 持指向
  # 该板的 cap）—— 能看见即可分享。**不**用 dispatch 探针：kanban 板动作的 cap 由 session 的
  # kanban-assistant（agent）持有，登录者（人）自身通常不持板动作 cap（他是 data_owner），
  # 故以「登录者 own / 持 cap」判 access（同 `WorldData.visible?` 的发现口径）。
  defp share_access?(socket, %URI{} = uri) do
    WorldData.can_share?(uri, read_ctx(socket))
  end

  defp build_share_link(socket, %URI{} = uri) do
    payload = %{
      "board" => URI.to_string(uri),
      "behavior" => @share_board_behavior,
      "access" => "read"
    }

    # max_age 在接收侧 `Phoenix.Token.verify` 时校验（sign 不带 max_age）。
    token = Phoenix.Token.sign(socket, @share_board_salt, payload)
    @share_board_receive_path <> "?" <> URI.encode_query(token: token)
  end

  # --- 上传文件挂到节点（v1.5）：验 upload grant 取 uploads URI → attach_artifact ----

  defp attach_upload(socket, uri_str, node_id, grant, name) do
    caller = socket.assigns.current_entity_uri

    case {parse(uri_str), verify_upload_grant(socket, grant, caller)} do
      {%URI{}, {:ok, %URI{} = upload_uri}} ->
        # url = uploads URI；jsonable_artifact(kind=file) 会签发下载 href
        upload_url = URI.to_string(upload_uri)

        act(socket, uri_str, :attach_artifact, %{
          id: node_id,
          artifact: %{tool: "upload", kind: "file", ref: name, url: upload_url}
        })

      {:error, _} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}

      {_, _} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_upload_grant")}
    end
  end

  # 反洗：校验 grant.caller == 当前登录者（上传者=挂载者）。kanban 节点是资源、非会话绑定，
  # 故不强求 grant.session 匹配（会话绑定是 chat 语境，对资源节点无意义）。
  defp verify_upload_grant(socket, grant, %URI{} = caller) do
    caller_str = URI.to_string(caller)

    case Phoenix.Token.verify(socket, @upload_grant_salt, grant, max_age: @upload_grant_max_age) do
      {:ok, %{"uri" => u, "caller" => ^caller_str}} -> Ezagent.URI.parse(u)
      _ -> {:error, :bad_grant}
    end
  end

  defp verify_upload_grant(_socket, _grant, _caller), do: {:error, :no_caller}

  # --- 新建 kanban = 建板走 BoardProvision（⑥ 会诊 2026-07-16）---
  #
  # kanban-as-role：看板 = 一个 passive native agent（role `kanban-manager`）。此前这里
  # 直调 `Workspace.create_agent`——普通成员无 create_agent cap 必拒（分层债 ⑥）。现改走
  # `Ezagent.Socialware.BoardProvision.create_board/5`（runtime 建板 glue）：成员守卫 +
  # 一次性 rule-authority（{:rule, :socialware_runtime_provision, creator}，只造 passive
  # native）+ 建完当场发两把钥匙（assistant + 建板人自己，落挂载表）。建板因此是
  # **session-scoped**（collab 模型：板挂在会话、assistant 收钥匙）——无当前会话则拒。
  # behavior 以字符串反解（token payload 字符串契约，照 @share_board_behavior 约定）。
  defp create_kanban(socket, name) do
    workspace_uri = socket.assigns.current_workspace_uri
    session_uri = socket.assigns[:current_session_uri]
    caller = socket.assigns.current_entity_uri
    caller_ctx = %{caller: caller, caps: Map.get(socket.assigns, :current_caps, MapSet.new())}
    clean = sanitize(name)

    cond do
      clean == "" ->
        {:noreply, assign(socket, :last_dispatch_status, "error:name_required")}

      not match?(%URI{scheme: "workspace"}, workspace_uri) ->
        {:noreply, assign(socket, :last_dispatch_status, "error:invalid_workspace")}

      not match?(%URI{scheme: "session"}, session_uri) ->
        {:noreply, assign(socket, :last_dispatch_status, "error:no_session_context")}

      true ->
        case Ezagent.Socialware.BoardProvision.create_board(
               workspace_uri,
               session_uri,
               %{
                 name: clean,
                 board_role: @kanban_role,
                 flavor: @native_flavor,
                 assistant_role: "kanban-assistant"
               },
               Module.concat([@share_board_behavior]),
               caller_ctx
             ) do
          {:ok, %{board_uri: board_uri}} ->
            # board_state 列出全量 instances（含新建的）+ 推该 agent 的空 board。
            # 建板也广播 {:kanban_changed}（e2e r08 残留：专用路径漏接任务6的广播，
            # 本人列表与同会话其他成员都靠它刷新）。
            broadcast_kanban_changed(socket, board_uri)

            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", WorldData.board_state(board_uri, read_ctx(socket)))}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end
    end
  end

  # --- ⑲ 删板：BoardProvision.delete_board → 推刷新后的 boards 列表 -----------

  defp delete_board(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        # 板可能 dormant(BEAM 重启后休眠)——manage.delete 要 dispatch 进它自己的
        # Kind 进程,先照其它动作的口径起活(已 live 幂等)。
        :ok = WorldData.ensure_spawned(uri)

        case Ezagent.Socialware.BoardProvision.delete_board(
               uri,
               Module.concat([@share_board_behavior]),
               ctx(socket)
             ) do
          {:ok, _report} ->
            # 板没了:清掉选中板,推刷新后的列表(前端回列表态);同会话其他成员靠广播刷新。
            broadcast_kanban_changed(socket, uri)

            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", %{
               "kanban_uri" => nil,
               "tree" => nil,
               "instances" => WorldData.list_instances(read_ctx(socket)),
               "last_dispatch_status" => "ok"
             })}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- 侧边栏选另一张导图：推该 board 的快照（dispatch 自动起活）-----------

  defp select_board(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_event("world:state", WorldData.board_state(uri, read_ctx(socket)))}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- X1 推送环发布侧(㉘/㉒-① 的 kanban 半) ---------------------------------
  #
  # kanban 写动作成功后向**当前会话的 UI events topic**(`esr:session:<uri>:events`,
  # chat_message / member_presence 同族的 view fan-out 面)广播一条轻事件
  # `{:kanban_changed, board_uri}` —— 同会话其他在线成员的 WorldLive 已经经
  # `ensure_session_subscribed` 订着这个 topic,收到后按自己的 `read_ctx` 重拉
  # `board_state` 刷画布(操作方此前只 push 自己的 socket,别人的界面永远不动,㉘)。
  #
  # **不是 inbound dispatch 路**(P14 红线,事故 2.1):inbound 永远走
  # `Ezagent.Invocation.dispatch/1`;这里是 §5.7.6 的 :events 观察者 fan-out,
  # 与 presence_fanout / read_marker 同一类(invariant #1 allowlist 同步登记)。
  # 无当前会话(如 /plugins/kanban 独立页操作)则无处可播,静默跳过。
  defp broadcast_kanban_changed(socket, %URI{} = board_uri) do
    case socket.assigns[:current_session_uri] do
      %URI{} = session_uri ->
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          Ezagent.ActionSet.Session.session_events_topic(session_uri),
          {:kanban_changed, board_uri}
        )

        :ok

      _ ->
        :ok
    end
  end

  # --- helpers --------------------------------------------------------

  defp ctx(socket) do
    %{
      caller: socket.assigns.current_entity_uri,
      caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      reply: {:caller_inbox, self()}
    }
  end

  # read-side ctx（caller_uri/caller_caps/workspace_uri）给 WorldData.read_tree/
  # board_state/list_instances。workspace_uri 让 list-by-role 限定在本 tenant（RF-7）。
  @doc """
  WorldData 读侧 ctx（caller 身份 + cap 快照 + workspace 域）——从 world socket assigns
  取。`ConversationActions.switch_view`（切 kanban tab 载板）也复用此函数，故公开。
  """
  def read_ctx(socket) do
    %{
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      workspace_uri: socket.assigns.current_workspace_uri
    }
  end

  # cred-saving 动作的目标 board：kanban-as-role 下 board = 一个 kanban-manager agent
  # （`entity://<ws>/agent/<id>`），凭证存在该 agent 的 state。无显式 `kanban_uri`
  # 时不再合成一个 `resource://<ws>/kanban/config`（那是已删的 resource Kind 路径）——
  # 返回 nil 让调用方报错（须先选一张 board）。
  defp kanban_uri(_socket, %{"kanban_uri" => u}) when is_binary(u) and u != "", do: u
  defp kanban_uri(_socket, _a), do: nil

  defp push_tree(socket, uri, status) do
    snapshot = WorldData.board_snapshot(uri, read_ctx(socket))

    socket
    |> assign(:last_dispatch_status, status)
    |> push_event(
      "world:state",
      Map.merge(snapshot, %{"last_dispatch_status" => status})
    )
  end

  defp status_of(:ok), do: "ok"
  defp status_of({:ok, _}), do: "ok"
  defp status_of({:error, reason}), do: "error:#{reason(reason)}"
  defp status_of(_), do: "error:unknown"

  defp parse(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, %URI{} = uri} -> uri
      _ -> :error
    end
  end

  defp parse(_), do: :error

  defp sanitize(name),
    do: name |> to_string() |> String.trim() |> String.replace(~r/[^\w\-]/u, "-")

  defp reason(r) when is_atom(r), do: Atom.to_string(r)
  defp reason(r), do: inspect(r)
end
