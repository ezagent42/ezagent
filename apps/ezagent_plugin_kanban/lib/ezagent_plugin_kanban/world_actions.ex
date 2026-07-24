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
  alias EzagentPluginKanban.WorldShareActions

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

  # ㊵ 人本位接收(in-app 气泡点击):verify token → 只读钥匙发给点击者本人
  # (person-scope 挂载)→ 刷新 caps 快照 → 原地切 kanban tab,零整屏跳转。
  def handle_dispatch(socket, "kanban.receive_shared", %{"token" => token})
      when is_binary(token),
      do: receive_shared(socket, token)

  # ㉙ 分享二期:把板分享进某个 session(缺省当前会话)——服务端物化分享消息,
  # 不再前端 onSend 拼字符串。
  def handle_dispatch(socket, "kanban.share_to_session", %{"kanban_uri" => u} = a)
      when is_binary(u),
      do: share_to_session(socket, u, Map.get(a, "session_uri"))

  # 规则8:已持只读钥匙的人申请编辑(往当前会话物化申请气泡,板主人批准)。
  def handle_dispatch(socket, "kanban.request_edit", %{"kanban_uri" => u}) when is_binary(u),
    do: request_edit(socket, u)

  # 规则8:板主人批准 → person 挂载 read→operate 重挂升级。
  def handle_dispatch(socket, "kanban.approve_edit", %{"kanban_uri" => u, "grantee" => g})
      when is_binary(u) and is_binary(g),
      do: approve_edit(socket, u, g)

  # ⑲ 删板:板主人(建板人)删除自己的板(语义命令 manage.delete + 清挂载,授权在
  # BoardProvision.delete_board —— caller==data_owner + Manage cap 过 dispatch 校验)。
  def handle_dispatch(socket, "kanban.delete_board", %{"kanban_uri" => u}) when is_binary(u),
    do: delete_board(socket, u)

  def handle_dispatch(socket, _action, _args),
    do: {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}

  # 上传 grant 校验（同 ConversationActions 的 anti-laundering：Phoenix.Token + uri↔caller↔session）。
  @upload_grant_salt "world_attach"
  @upload_grant_max_age 86_400

  # 板的 behavior 模块（建板/删板传 BoardProvision）。分享 token 侧的字符串形态
  # (`"Ezagent.ActionSet.Kanban"`)住在 `WorldShareActions`,两处必须指同一模块。
  @kanban_behavior Ezagent.ActionSet.Kanban

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
        snapshot = WorldData.board_snapshot(uri, read_ctx(socket))

        if status == "ok" do
          materialize_op(
            socket,
            op_text(action, args, uri, snapshot),
            op_attachments(action, args)
          )
        end

        {:noreply, push_snapshot(socket, snapshot, status)}

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

        if status == "ok" do
          materialize_op(socket, op_text(action, args, uri, nil))
        end

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
            materialize_op(socket, "【看板·#{uri_label(uri)}】同步了看板到 Miro")

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

  # --- 分享面(T6.4/㊵/㉙/规则8):业务逻辑拆在 WorldShareActions ---------------
  #
  # oversized_modules_gt_1000 gate(2026-07-20)拆分:分享链接签发/接收、
  # share_to_session、request_edit/approve_edit 的业务结果都在
  # `EzagentPluginKanban.WorldShareActions`;这里只留 handle_dispatch 的
  # `{:noreply, socket}` 包装 + materialize_op 操作留痕。公开 API 经 defdelegate
  # 原位保留(share_link 等外部调用方/测试不感知拆分)。

  @doc "T6.4 分享链接(委派 `WorldShareActions.share_link/2`,契约见该函数 doc)。"
  defdelegate share_link(socket, uri_str), to: WorldShareActions

  @doc "㉙ 分享到会话业务结果(委派 `WorldShareActions.share_to_session_result/3`)。"
  defdelegate share_to_session_result(socket, uri_str, session_str), to: WorldShareActions

  @doc "规则8 申请编辑业务结果(委派 `WorldShareActions.request_edit_result/2`)。"
  defdelegate request_edit_result(socket, uri_str), to: WorldShareActions

  @doc "规则8 批准升级业务结果(委派 `WorldShareActions.approve_edit_result/3`)。"
  defdelegate approve_edit_result(socket, uri_str, grantee_str), to: WorldShareActions

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

  defp receive_shared(socket, token), do: WorldShareActions.receive_shared(socket, token)

  defp share_to_session(socket, uri_str, session_str) do
    case share_to_session_result(socket, uri_str, session_str) do
      {:ok, _session_uri} ->
        materialize_op(socket, "分享了看板「#{board_label(uri_str)}」到会话")

        {:noreply, assign(socket, :last_dispatch_status, "ok")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
    end
  end

  defp request_edit(socket, uri_str) do
    case request_edit_result(socket, uri_str) do
      {:ok, _} ->
        {:noreply, assign(socket, :last_dispatch_status, "ok")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
    end
  end

  defp approve_edit(socket, uri_str, grantee_str) do
    case approve_edit_result(socket, uri_str, grantee_str) do
      {:ok, grantee} ->
        materialize_op(
          socket,
          "批准了 #{uri_label(grantee)} 对看板「#{board_label(uri_str)}」的编辑申请(只读→可编辑)"
        )

        {:noreply, assign(socket, :last_dispatch_status, "ok")}

      {:error, reason} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
    end
  end

  defp board_label(uri_str) do
    case parse(uri_str) do
      %URI{} = uri -> uri_label(uri)
      _ -> uri_str
    end
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
  # 一次性 provision authority（#1457 后经 `{:admin, admin_uri}` 具名签发，只造 passive
  # native）+ 建完当场发两把钥匙（assistant + 建板人自己，落挂载表）。建板因此是
  # **session-scoped**（collab 模型：板挂在会话、assistant 收钥匙）——无当前会话则拒。
  # behavior 以字符串反解（token payload 字符串契约，照 @share_board_behavior 约定）。
  defp create_kanban(socket, name) do
    workspace_uri = socket.assigns.current_workspace_uri
    session_uri = socket.assigns[:current_session_uri]
    caller = socket.assigns.current_entity_uri
    caller_ctx = %{
      caller: caller,
      authenticated_principal: caller,
      caps: presenter_caps(socket)
    }
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
               @kanban_behavior,
               caller_ctx
             ) do
          {:ok, %{board_uri: board_uri}} ->
            # board_state 列出全量 instances（含新建的）+ 推该 agent 的空 board。
            # 建板后其他成员的界面刷新不在本 PR 范围（见模块 doc 的实时刷新说明）。
            materialize_op(socket, "新建了看板「#{uri_label(board_uri)}」")

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
               @kanban_behavior,
               ctx(socket)
             ) do
          {:ok, _report} ->
            # 板没了:清掉选中板,推刷新后的列表(前端回列表态);同会话其他成员靠广播刷新。
            materialize_op(socket, "删除了看板「#{uri_label(uri)}」（含全部挂载）")

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

  # --- 操作物化消息（2026-07-18 一等任务）-----------------------------------
  #
  # 所有 kanban 写操作成功后，以**操作者身份**往当前会话物化一条
  # `visibility: :internal, hops: 0` 消息（动作 + 节点摘要；attach 消息带附件引用）：
  #   * `:internal` —— 普通 chat 读面（`recent_visible_in_session`）过滤掉，不刷屏；
  #     留痕在 MessageStore，立「一切操作皆对话」心智模型；
  #   * `hops: 0` —— `session.send` 存完即 `:hop_exhausted`，零路由 fan-out
  #     （不惊动 assistant / relay / 外部 channel）；
  #   * attach 的附件引用 = uploads resource URI 进 `body.attachments`
  #     （㊲ 救济半件：同会话成员日后经消息参与面可下载——serve 侧归 infra-C）。
  # 无当前会话（/plugins/kanban 独立页）无处可记，静默跳过；发送 best-effort
  # （:cast），失败不回滚动作（留痕缺一条 vs 动作报错，取前者）。
  defp materialize_op(socket, text, attachments \\ []) do
    case socket.assigns[:current_session_uri] do
      %URI{} = session_uri ->
        caller = socket.assigns.current_entity_uri

        msg =
          Ezagent.Message.new(caller, %{text: text, attachments: attachments},
            visibility: :internal,
            hops: 0
          )

        _ =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(session_uri, :session, :send),
            mode: :cast,
            args: %{message: msg},
            ctx: %{
              caller: caller,
              authenticated_principal: caller,
              caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
              reply: :ignore
            },
            origin: :authenticated_external
          })

        :ok

      _ ->
        :ok
    end
  end

  # 动作 → 中文摘要（节点名从 post-action snapshot 取——rename 后是新名；remove 后
  # 节点已不在，退成通用句）。snapshot=nil（act_board 图级动作）只出图级句。
  defp op_text(action, args, board_uri, snapshot) do
    board = uri_label(board_uri)

    title = fn ->
      case snapshot && get_in(snapshot, ["tree", "nodes", args[:id], "title"]) do
        t when is_binary(t) and t != "" -> t
        _ -> to_string(args[:id] || "?")
      end
    end

    body =
      case action do
        :add_node -> "新增节点「#{args[:title]}」"
        :rename_node -> "把节点改名为「#{args[:title]}」"
        :move_node -> "移动了节点「#{title.()}」"
        :remove_node -> "删除了一个节点及其整棵子树"
        :set_stage -> "把节点「#{title.()}」的阶段设为 #{args[:stage]}"
        :claim_node -> "认领了节点「#{title.()}」"
        :unclaim_node -> "取消认领了节点「#{title.()}」"
        :set_status -> "把节点「#{title.()}」的状态设为 #{args[:status]}"
        :attach_artifact -> "在节点「#{title.()}」挂了产物「#{artifact_ref(args)}」"
        :detach_artifact -> "移除了节点「#{title.()}」的产物「#{args[:ref]}」"
        :set_metric -> "更新了节点「#{title.()}」的指标"
        :drop_subtree -> "drop 标记了节点「#{title.()}」（不达标跟踪，未删除）"
        :register_pr -> "在节点「#{title.()}」登记了 PR ##{args[:pr]}"
        :attach_code_file -> "在节点「#{title.()}」钉了代码文件 #{args[:path]}"
        :save_miro_creds -> "更新了 Miro 凭证"
        :set_board_config -> "更新了看板配置"
        other -> "执行了 #{other}"
      end

    "【看板·#{board}】" <> body
  end

  # attach 的附件引用：file 产物（attach_upload 路挂进来的）url 是 uploads resource
  # URI → 作为消息 attachments（%URI{} 列表，chat attachments 同形）。其余动作无附件。
  defp op_attachments(:attach_artifact, %{artifact: artifact}) when is_map(artifact) do
    with "file" <- artifact[:kind] || artifact["kind"],
         url when is_binary(url) <- artifact[:url] || artifact["url"],
         {:ok, %URI{} = uri} <- Ezagent.URI.parse(url),
         true <- Ezagent.URI.scheme?(uri, :resource) do
      [uri]
    else
      _ -> []
    end
  end

  defp op_attachments(_action, _args), do: []

  defp artifact_ref(%{artifact: artifact}) when is_map(artifact),
    do: artifact[:ref] || artifact["ref"] || artifact[:kind] || artifact["kind"] || "artifact"

  defp artifact_ref(_), do: "artifact"

  defp uri_label(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()

  # --- helpers --------------------------------------------------------

  # presenter 的 cap 快照——**只读 world 放进来的 assign，绝不反向调 world 模块**
  # （本模块住 plugin_kanban，world → plugin_kanban 是允许的箭头，反向会成环）。
  # 新鲜度策略是 world 的（`Ezagent.World.PresenterCaps.put/1` 在把 socket 交给
  # 插件前算好塞进 `:presenter_caps`，见该函数 doc）；这里只消费那份数据。
  # assign 缺失 → 空集 = fail-closed（CBAC 判定拒绝，不是放行）。
  defp presenter_caps(socket) do
    Map.get(socket.assigns, :presenter_caps) || MapSet.new()
  end

  defp ctx(socket) do
    %{
      caller: socket.assigns.current_entity_uri,
      authenticated_principal: socket.assigns.current_entity_uri,
      caps: presenter_caps(socket),
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
      caller_caps: presenter_caps(socket),
      workspace_uri: socket.assigns.current_workspace_uri
    }
  end

  # cred-saving 动作的目标 board：kanban-as-role 下 board = 一个 kanban-manager agent
  # （`entity://<ws>/agent/<id>`），凭证存在该 agent 的 state。无显式 `kanban_uri`
  # 时不再合成一个 `resource://<ws>/kanban/config`（那是已删的 resource Kind 路径）——
  # 返回 nil 让调用方报错（须先选一张 board）。
  defp kanban_uri(_socket, %{"kanban_uri" => u}) when is_binary(u) and u != "", do: u
  defp kanban_uri(_socket, _a), do: nil

  defp push_snapshot(socket, snapshot, status) do
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
