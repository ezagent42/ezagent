defmodule Ezagent.World.KanbanActions do
  @moduledoc """
  Socket-side dispatch handlers for the world **kanban operating surface**。

  对齐 `Ezagent.World.ConversationActions`：`WorldLive` 保持瘦 `handle_event` 子句、
  委派到这里。

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
  world 只 dispatch + 刷 UI，不直引任何 kanban plugin 模块。dormant 的
  passive kanban-manager 经 `KanbanData.ensure_spawned/1` 从快照 rehydrate 起活。
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.Invocation
  alias Ezagent.World.KanbanData

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
  def handle_dispatch(socket, "kanban.sync_miro", %{"kanban_uri" => u}),
    do: sync_miro(socket, u)

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
  # behavior 以字符串入 token（world 无 kanban plugin dep，不静态引模块；接收侧
  # `Module.concat` 反解，同 `Mount.decode_behavior` 约定）。
  @share_board_behavior "Ezagent.ActionSet.Kanban"
  @share_board_receive_path "/socialware/kanban/receive"

  # --- 动作：dispatch（登录者身份）→ re-read 树 → push tree --------------

  defp act(socket, uri_str, action, args) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = KanbanData.ensure_spawned(uri)
        target = Ezagent.URI.with_action(uri, :kanban, action)

        result =
          Invocation.dispatch(%Invocation{
            target: target,
            mode: :call,
            args: args,
            ctx: ctx(socket),
            origin: :authenticated_external
          })

        {:noreply, push_tree(socket, uri, status_of(result))}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # 图级动作（set_board_config / save_miro_creds）：dispatch → 推全量 board 快照（含
  # 刷新的 config / miro 状态），让前端连接器面同步。
  defp act_board(socket, uri_str, action, args) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = KanbanData.ensure_spawned(uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(uri, :kanban, action),
            mode: :call,
            args: args,
            ctx: ctx(socket),
            origin: :authenticated_external
          })

        status = status_of(result)

        {:noreply,
         socket
         |> assign(:last_dispatch_status, status)
         |> push_event(
           "world:state",
           Map.put(KanbanData.board_state(uri, read_ctx(socket)), "last_dispatch_status", status)
         )}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- 一键推 Miro：dispatch → board_id → 推 miro_board_url -----------------

  defp sync_miro(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = KanbanData.ensure_spawned(uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(uri, :kanban, :sync_miro),
            mode: :call,
            args: %{},
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
  # 故以「登录者 own / 持 cap」判 access（同 `KanbanData.visible?` 的发现口径）。
  defp share_access?(socket, %URI{} = uri) do
    KanbanData.can_share?(uri, read_ctx(socket))
  end

  defp build_share_link(socket, %URI{} = uri) do
    board_uri = encode_uri(uri)

    payload = %{
      "board" => board_uri,
      "behavior" => @share_board_behavior,
      "access" => "read"
    }

    # max_age 在接收侧 `Phoenix.Token.verify` 时校验（sign 不带 max_age）。
    token = Phoenix.Token.sign(socket, @share_board_salt, payload)
    @share_board_receive_path <> "?" <> URI.encode_query(token: token)
  end

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)

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

  # --- 新建 kanban = 创建一个 kanban-manager agent（role × flavor native）---
  #
  # kanban-as-role：看板不再是 `resource://<ws>/kanban/<name>` 独立 Kind，而是一个
  # agent。新建 = `Ezagent.Workspace.create_agent`（RF-5a role-create 路径），flavor
  # `native`（boot 注册的通用宿主，RF-8）× role `kanban-manager`（kanban plugin
  # `roles/0` boot 注册的 recipe，含 24 个 behaviors + caps + passive:true）。创建后
  # 该 agent 的 `entity://<ws>/agent/<name>` 即 board 的寻址 + dispatch 目标。
  defp create_kanban(socket, name) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caller_ctx = %{caller: caller, caps: Ezagent.World.PresenterCaps.load(socket)}
    clean = sanitize(name)

    cond do
      clean == "" ->
        {:noreply, assign(socket, :last_dispatch_status, "error:name_required")}

      not match?(%URI{scheme: "workspace"}, workspace_uri) ->
        {:noreply, assign(socket, :last_dispatch_status, "error:invalid_workspace")}

      true ->
        case Ezagent.Workspace.create_agent(
               workspace_uri,
               %{
                 flavor: @native_flavor,
                 name: clean,
                 role: @kanban_role,
                 cwd: "",
                 with_pty: false
               },
               caller_ctx
             ) do
          {:ok, %{agent_uri: agent_uri}} ->
            # board_state 列出全量 instances（含新建的）+ 推该 agent 的空 board。
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", KanbanData.board_state(agent_uri, read_ctx(socket)))}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end
    end
  end

  # --- 侧边栏选另一张导图：推该 board 的快照（dispatch 自动起活）-----------

  defp select_board(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_event("world:state", KanbanData.board_state(uri, read_ctx(socket)))}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- helpers --------------------------------------------------------

  defp ctx(socket) do
    %{
      caller: socket.assigns.current_entity_uri,
      caps: Ezagent.World.PresenterCaps.load(socket),
      reply: {:caller_inbox, self()}
    }
  end

  # read-side ctx（caller_uri/caller_caps/workspace_uri）给 KanbanData.read_tree/
  # board_state/list_instances。workspace_uri 让 list-by-role 限定在本 tenant（RF-7）。
  @doc """
  KanbanData 读侧 ctx（caller 身份 + cap 快照 + workspace 域）——从 world socket assigns
  取。`ConversationActions.switch_view`（切 kanban tab 载板）也复用此函数，故公开。
  """
  def read_ctx(socket) do
    %{
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Ezagent.World.PresenterCaps.load(socket),
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
    snapshot = KanbanData.board_snapshot(uri, read_ctx(socket))

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
