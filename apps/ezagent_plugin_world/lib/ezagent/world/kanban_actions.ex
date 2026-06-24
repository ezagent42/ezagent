defmodule Ezagent.World.KanbanActions do
  @moduledoc """
  Socket-side dispatch handlers for the world **kanban operating surface**。

  对齐 `Ezagent.World.ConversationActions`：`WorldLive` 保持瘦 `handle_event` 子句、
  委派到这里。每个动作经 `Ezagent.Invocation.dispatch/1` 打到 kanban Kind（P14），
  **ctx 带登录者 `current_entity_uri`/`current_caps`**——per-node CapBAC 在 Behavior 内
  如实判，world 层不放水。动作成功后 re-read 树 + `push_event("world:state")` 刷前端。

  ## df-tech 下沉（kanban-clean）
  本模块退成**纯 dispatcher**：原先直引 kanban plugin 出站连接器（Github / Miro / MiroSync /
  BoardConfig / Ci / InstanceSupervisor / Kanban）的逻辑全部下沉进 `Ezagent.Behavior.Kanban`
  的新动作（sync_github / push_pr / register_pr / attach_code_file / sync_prs / sync_miro /
  set_board_config / save_github_creds / save_miro_creds）。world 只 dispatch + 刷 UI，不再
  直引任何 kanban plugin 模块。spawn 靠 dispatch 自动起活（ReadyGate），不再
  `DynamicSupervisor.start_child`。
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.Invocation
  alias Ezagent.World.KanbanData

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

  def handle_dispatch(socket, "kanban.sync_github", %{"kanban_uri" => u, "id" => id}),
    do: act(socket, u, :sync_github, %{id: id})

  def handle_dispatch(socket, "kanban.save_github_creds", %{"access_token" => token} = a)
      when is_binary(token),
      do:
        act_board(socket, kanban_uri(socket, a), :save_github_creds, %{
          access_token: token,
          repo: Map.get(a, "repo", "")
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

  def handle_dispatch(socket, "kanban.sync_prs", %{"kanban_uri" => u}),
    do: act(socket, u, :sync_prs, %{})

  def handle_dispatch(socket, "kanban.push_pr", %{"kanban_uri" => u, "id" => id}),
    do: act(socket, u, :push_pr, %{id: id})

  def handle_dispatch(socket, "kanban.attach_code_file", %{
        "kanban_uri" => u,
        "id" => id,
        "sha" => sha,
        "path" => path
      })
      when is_binary(sha) and is_binary(path),
      do: act(socket, u, :attach_code_file, %{id: id, sha: sha, path: path})

  def handle_dispatch(socket, _action, _args),
    do: {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}

  # 上传 grant 校验（同 ConversationActions 的 anti-laundering：Phoenix.Token + uri↔caller↔session）。
  @upload_grant_salt "world_attach"
  @upload_grant_max_age 86_400

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
            ctx: ctx(socket)
          })

        {:noreply, push_tree(socket, uri, status_of(result))}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # 图级动作（set_board_config / save_*_creds）：dispatch → 推全量 board 快照（含
  # 刷新的 config / miro / github 状态），让前端连接器面同步。
  defp act_board(socket, uri_str, action, args) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = KanbanData.ensure_spawned(uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(uri, :kanban, action),
            mode: :call,
            args: args,
            ctx: ctx(socket)
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
            ctx: ctx(socket)
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

  # --- 上传文件挂到节点（v1.5）：验 upload grant 取 uploads URI → attach_artifact ----

  defp attach_upload(socket, uri_str, node_id, grant, name) do
    caller = socket.assigns.current_entity_uri

    case {parse(uri_str), verify_upload_grant(socket, grant, caller)} do
      {%URI{}, {:ok, %URI{} = upload_uri}} ->
        # url = uploads URI；jsonable_artifact(kind=file) 会签发下载 href
        act(socket, uri_str, :attach_artifact, %{
          id: node_id,
          artifact: %{tool: "upload", kind: "file", ref: name, url: URI.to_string(upload_uri)}
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

  # --- 新建 kanban（dispatch 自动起活：get_tree 打到没 live 的 Kind → ReadyGate 起）---

  defp create_kanban(socket, name) do
    ws_host = workspace_host(socket.assigns.current_workspace_uri)
    clean = sanitize(name)

    cond do
      clean == "" ->
        {:noreply, assign(socket, :last_dispatch_status, "error:name_required")}

      ws_host == nil ->
        {:noreply, assign(socket, :last_dispatch_status, "error:invalid_workspace")}

      true ->
        # kanban 是数据资源 Kind（`pattern: :resource`）→ `resource://<ws>/kanban/<name>`，
        # 经 sanctioned `URI.resource/3`（type 段任意，过 uri_query.scan）。dispatch 自动起活。
        uri = Ezagent.URI.resource(ws_host, "kanban", clean)

        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_event("world:state", KanbanData.board_state(uri, read_ctx(socket)))}
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
      caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
      reply: {:caller_inbox, self()}
    }
  end

  # read-side ctx（caller_uri/caller_caps）给 KanbanData.read_tree/board_state。
  defp read_ctx(socket) do
    %{
      caller_uri: socket.assigns.current_entity_uri,
      caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new())
    }
  end

  # cred-saving 动作无 kanban_uri 时，挂到一个稳定的系统配置图（凭证是全局的，
  # dispatch target 只用于路由到 kanban Kind；admin 校验在 Behavior 内做）。
  defp kanban_uri(_socket, %{"kanban_uri" => u}) when is_binary(u) and u != "", do: u

  defp kanban_uri(socket, _a) do
    ws = workspace_host(socket.assigns.current_workspace_uri) || "system"
    URI.to_string(Ezagent.URI.resource(ws, "kanban", "config"))
  end

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

  # sanctioned 读 workspace 名（`workspace_name/1` 返 `{:ok, name}` | `:error`）。
  defp workspace_host(%URI{} = uri) do
    case Ezagent.URI.workspace_name(uri) do
      {:ok, name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp workspace_host(_), do: nil

  defp sanitize(name),
    do: name |> to_string() |> String.trim() |> String.replace(~r/[^\w\-]/u, "-")

  defp reason(r) when is_atom(r), do: Atom.to_string(r)
  defp reason(r), do: inspect(r)
end
