defmodule Ezagent.World.KanbanActions do
  @moduledoc """
  Socket-side dispatch handlers for the world **kanban operating surface**。

  对齐 `Ezagent.World.ConversationActions`：`WorldLive` 保持瘦 `handle_event` 子句、
  委派到这里。每个动作经 `Ezagent.Invocation.dispatch/1` 打到 kanban Kind（P14），
  **ctx 带登录者 `current_entity_uri`/`current_caps`**——per-node CapBAC 在 Behavior 内
  如实判，world 层不放水。动作成功后 re-read 树 + `push_event("world:state")` 刷前端。
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

  def handle_dispatch(socket, "kanban.sync_miro", %{"kanban_uri" => u}),
    do: sync_miro(socket, u)

  def handle_dispatch(socket, "kanban.save_miro_creds", %{"access_token" => token} = a)
      when is_binary(token),
      do: save_miro_creds(socket, token, Map.get(a, "board_id", ""))

  def handle_dispatch(socket, "kanban.sync_github", %{"kanban_uri" => u, "id" => id}),
    do: sync_github(socket, u, id)

  def handle_dispatch(socket, "kanban.save_github_creds", %{"access_token" => token} = a)
      when is_binary(token),
      do: save_github_creds(socket, token, Map.get(a, "repo", ""))

  def handle_dispatch(socket, "kanban.set_board_config", %{"kanban_uri" => u} = a),
    do: set_board_config(socket, u, Map.get(a, "github_repo", ""), Map.get(a, "miro_board", ""))

  def handle_dispatch(
        socket,
        "kanban.attach_upload",
        %{"kanban_uri" => u, "id" => id, "grant" => grant} = a
      )
      when is_binary(grant),
      do: attach_upload(socket, u, id, grant, Map.get(a, "name", "file"))

  def handle_dispatch(socket, "kanban.register_pr", %{"kanban_uri" => u, "id" => id, "pr" => pr}),
    do: register_pr(socket, u, id, pr)

  def handle_dispatch(socket, "kanban.sync_prs", %{"kanban_uri" => u}),
    do: sync_prs(socket, u)

  def handle_dispatch(socket, "kanban.push_pr", %{"kanban_uri" => u, "id" => id}),
    do: push_pr(socket, u, id)

  def handle_dispatch(socket, "kanban.attach_code_file", %{
        "kanban_uri" => u,
        "id" => id,
        "sha" => sha,
        "path" => path
      })
      when is_binary(sha) and is_binary(path),
      do: attach_code_file(socket, u, id, sha, path)

  def handle_dispatch(socket, _action, _args),
    do: {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}

  # 上传 grant 校验（同 ConversationActions 的 anti-laundering：Phoenix.Token + uri↔caller↔session）。
  @upload_grant_salt "world_attach"
  @upload_grant_max_age 86_400

  # --- 节点动作：dispatch（登录者身份）→ re-read 树 → push ----------------

  defp act(socket, uri_str, action, args) do
    case parse(uri_str) do
      %URI{} = uri ->
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

  # --- 一键推 Miro（首次建板+绑定，之后复用）----------------------------

  defp sync_miro(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        # 板名取本图配置(用户填的,按名不按id)；没配就默认 "ezagent: 图名"
        miro_name =
          EzagentPluginKanban.BoardConfig.read(uri).miro_board || "ezagent: " <> uri_name(uri)

        case EzagentPluginKanban.MiroSync.sync_or_bind(uri, miro_name) do
          {:ok, %{board_id: board}} ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", %{
               "miro_board_url" => "https://miro.com/app/board/#{board}",
               "last_dispatch_status" => "ok"
             })}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  # --- 保存 Miro 凭证（配置页，admin-gated）------------------------------

  defp save_miro_creds(socket, token, board) do
    cond do
      not Ezagent.Identity.admin?(socket.assigns.current_entity_uri) ->
        {:noreply, assign(socket, :last_dispatch_status, "error:unauthorized")}

      true ->
        case EzagentPluginKanban.Miro.write_creds(%{access_token: token, board_id: board}) do
          :ok ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", %{
               "miro" => Ezagent.World.KanbanData.miro_status(),
               "last_dispatch_status" => "ok"
             })}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end
    end
  end

  # --- 出站到 GitHub（片6，纯出站）：把节点出站成 issue + 回挂 issue 到节点 -----

  defp sync_github(socket, uri_str, node_id) do
    case parse(uri_str) do
      %URI{} = uri ->
        tree = KanbanData.read_tree(uri, read_ctx(socket))
        node = get_in(tree, ["nodes", node_id])

        case {board_creds(uri), node} do
          {{:ok, %{token: token, repo: repo}}, %{} = n} when is_binary(repo) ->
            case EzagentPluginKanban.Github.create_issue(
                   token,
                   repo,
                   n["title"] || "(untitled)",
                   github_body(n)
                 ) do
              {:ok, %{number: num, url: url}} ->
                # issue 回挂到节点（走已注册的 attach_artifact 动作）
                _ =
                  Invocation.dispatch(%Invocation{
                    target: Ezagent.URI.with_action(uri, :kanban, :attach_artifact),
                    mode: :call,
                    args: %{
                      id: node_id,
                      artifact: %{tool: "github", kind: "issue", ref: "##{num}", url: url}
                    },
                    ctx: ctx(socket)
                  })

                {:noreply, push_tree(socket, uri, "ok")}

              {:error, reason} ->
                {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
            end

          {{:ok, %{repo: nil}}, _} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:github_repo_missing")}

          {{:error, _}, _} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:github_token_missing")}

          {_, nil} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:node_not_found")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  defp github_body(n) do
    content =
      (n["artifacts"] || [])
      |> Enum.map(& &1["content"])
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    "**stage**: #{n["stage"]} · **status**: #{n["status"]}\n\n" <>
      content <> "\n\n_由 ezagent kanban 节点出站_"
  end

  # --- 保存 GitHub 凭证（配置页，admin-gated；同 Miro 不写死）-------------

  defp save_github_creds(socket, token, repo) do
    cond do
      not Ezagent.Identity.admin?(socket.assigns.current_entity_uri) ->
        {:noreply, assign(socket, :last_dispatch_status, "error:unauthorized")}

      true ->
        case EzagentPluginKanban.Github.write_creds(%{access_token: token, repo: repo}) do
          :ok ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", %{
               "github" => Ezagent.World.KanbanData.github_status(),
               "last_dispatch_status" => "ok"
             })}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end
    end
  end

  # --- GitHub PR 闭环（确定性 worker）：登记 PR→出站产品需求摘要；轮询 PR→merged/closed→done -

  # 登记 PR：先有配置页的仓库(定位仓库)，这里填 PR 号(定位 PR)→ 出站「产品需求摘要」留言到该 PR
  # + 把 PR 回挂到节点。失败(无凭证/无仓库/401/404/连不上)都给干净错误码 → 前端中文提示。
  defp register_pr(socket, uri_str, node_id, pr_in) do
    case {parse(uri_str), to_pr_number(pr_in)} do
      {%URI{} = uri, pr} when is_integer(pr) -> do_register_pr(socket, uri, node_id, pr)
      {:error, _} -> gerr(socket, "bad_kanban_uri")
      {_, :error} -> gerr(socket, "bad_pr_number")
    end
  end

  # 登记 PR = 只把 PR 链接挂到节点（不发 github 评论）。出站留言在 push_pr。
  defp do_register_pr(socket, uri, node_id, pr) do
    case board_creds(uri) do
      {:ok, %{repo: repo}} when is_binary(repo) ->
        _ =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(uri, :kanban, :attach_artifact),
            mode: :call,
            args: %{
              id: node_id,
              artifact: %{
                tool: "github",
                kind: "pr",
                ref: "##{pr}",
                url: "https://github.com/#{repo}/pull/#{pr}"
              }
            },
            ctx: ctx(socket)
          })

        {:noreply, push_tree(socket, uri, "ok")}

      {:ok, %{repo: nil}} ->
        gerr(socket, "github_repo_missing")

      _ ->
        gerr(socket, "github_token_missing")
    end
  end

  # 出站 GitHub = 把产品需求摘要留言推到节点上**已登记的 PR**（没登记报错，这是验证）。
  defp push_pr(socket, uri_str, node_id) do
    case parse(uri_str) do
      %URI{} = uri ->
        with {:ok, %{token: token, repo: repo}} when is_binary(repo) <- board_creds(uri),
             {:ok, %{tree: %{nodes: nodes} = tree}} <- get_internal_tree(socket, uri),
             node when is_map(node) <- Map.get(nodes, node_id),
             pr when is_integer(pr) <- node_pr(node),
             digest = EzagentPluginKanban.Ci.requirement_digest(tree, node_id),
             {:ok, _url} <- EzagentPluginKanban.Github.post_comment(token, repo, pr, digest) do
          {:noreply, push_tree(socket, uri, "ok")}
        else
          nil -> gerr(socket, "no_pr_registered")
          {:ok, %{repo: nil}} -> gerr(socket, "github_repo_missing")
          {:error, :github_token_missing} -> gerr(socket, "github_token_missing")
          {:error, reason} -> gerr(socket, gh_error(reason))
          _ -> gerr(socket, "no_pr_registered")
        end

      :error ->
        gerr(socket, "bad_kanban_uri")
    end
  end

  # 挂 PR 文件 = 读节点已登记的 PR → 取 PR head 分支 → 构造该文件的 github blob 链接(可点跳转)。
  # 挂代码文件 = 直接给 commit SHA + 文件路径 → 拼 github blob 链接（钉 SHA=永久,merge/删分支后也能开）。
  # 不绕 PR 登记,每阶段都能用。repo 取自配置;token 不需要(blob 链接公开可拼)。
  defp attach_code_file(socket, uri_str, node_id, sha, path) do
    case parse(uri_str) do
      %URI{} = uri ->
        case board_creds(uri) do
          {:ok, %{repo: repo}} when is_binary(repo) ->
            clean = String.trim_leading(path, "/")
            url = "https://github.com/#{repo}/blob/#{sha}/#{clean}"
            name = clean |> String.split("/") |> List.last()

            _ =
              Invocation.dispatch(%Invocation{
                target: Ezagent.URI.with_action(uri, :kanban, :attach_artifact),
                mode: :call,
                args: %{
                  id: node_id,
                  artifact: %{tool: "github", kind: "github_file", ref: name, url: url}
                },
                ctx: ctx(socket)
              })

            {:noreply, push_tree(socket, uri, "ok")}

          {:ok, %{repo: nil}} ->
            gerr(socket, "github_repo_missing")

          _ ->
            gerr(socket, "github_token_missing")
        end

      :error ->
        gerr(socket, "bad_kanban_uri")
    end
  end

  # 轮询：遍历"登记过 PR 的节点"(不遍历全仓)，查 PR 状态；merged/closed → set_status done。
  defp sync_prs(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        case board_creds(uri) do
          {:ok, %{token: token, repo: repo}} when is_binary(repo) ->
            case get_internal_tree(socket, uri) do
              {:ok, %{tree: %{nodes: nodes}}} ->
                n = sync_pr_nodes(socket, uri, token, repo, nodes)

                {:noreply,
                 push_tree(
                   socket,
                   uri,
                   if(n == :unreachable, do: "error:github_unreachable", else: "ok")
                 )}

              _ ->
                gerr(socket, "github_error")
            end

          {:ok, %{repo: nil}} ->
            gerr(socket, "github_repo_missing")

          _ ->
            gerr(socket, "github_token_missing")
        end

      :error ->
        gerr(socket, "bad_kanban_uri")
    end
  end

  defp sync_pr_nodes(socket, uri, token, repo, nodes) do
    Enum.reduce(nodes, :ok, fn {id, node}, acc ->
      case node_pr(node) do
        nil ->
          acc

        pr ->
          case EzagentPluginKanban.Github.get_pull(token, repo, pr) do
            {:ok, %{merged: true}} -> advance_done(socket, uri, id)
            {:ok, %{state: "closed"}} -> advance_done(socket, uri, id)
            {:error, {:http_error, _}} -> :unreachable
            _ -> acc
          end
      end
    end)
  end

  defp advance_done(socket, uri, id) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(uri, :kanban, :set_status),
      mode: :call,
      args: %{id: id, status: "done"},
      ctx: ctx(socket)
    })

    :ok
  end

  # 从节点的 pr 产物里抠出 PR 号（"#42"→42）。
  defp node_pr(node) do
    node
    |> Map.get(:artifacts, [])
    |> Enum.find_value(fn a ->
      if to_string(Map.get(a, :kind)) == "pr" do
        case to_pr_number(to_string(Map.get(a, :ref))) do
          n when is_integer(n) -> n
          _ -> nil
        end
      end
    end)
  end

  defp to_pr_number(pr) when is_integer(pr), do: pr

  defp to_pr_number(pr) when is_binary(pr) do
    case pr |> String.trim() |> String.trim_leading("#") |> Integer.parse() do
      {n, _} -> n
      :error -> :error
    end
  end

  defp to_pr_number(_), do: :error

  defp get_internal_tree(socket, %URI{} = uri) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(uri, :kanban, :get_tree),
      mode: :call,
      args: %{},
      ctx: ctx(socket)
    })
  end

  # GitHub 失败 → 干净错误码（前端 dispatchError 映射成中文提示）。注：用 REST API(httpc)，不依赖 gh CLI。
  defp gh_error({:http_status, code, _}) when code in [401, 403], do: "github_unauthorized"
  defp gh_error({:http_status, 404, _}), do: "github_not_found"
  defp gh_error({:http_status, code, _}), do: "github_http_#{code}"
  defp gh_error({:http_error, _}), do: "github_unreachable"
  defp gh_error(other), do: reason(other)

  defp gerr(socket, code), do: {:noreply, assign(socket, :last_dispatch_status, "error:#{code}")}

  # 每图独立配置：token 取**全局**(github.yaml,以后每用户配),repo 取**本图**配置。
  # 返回跟 Github.read_creds 同形状({:ok,%{token,repo}}|{:error,_}),repo=本图 repo 或 nil。
  defp board_creds(%URI{} = uri) do
    case EzagentPluginKanban.Github.read_creds() do
      {:ok, %{token: token}} ->
        {:ok, %{token: token, repo: EzagentPluginKanban.BoardConfig.read(uri).github_repo}}

      err ->
        err
    end
  end

  # 保存本图配置（github_repo + miro 板名）。token 不在这,在全局配置页。
  defp set_board_config(socket, uri_str, github_repo, miro_board) do
    case parse(uri_str) do
      %URI{} = uri ->
        case EzagentPluginKanban.BoardConfig.write(uri, %{
               github_repo: github_repo,
               miro_board: miro_board
             }) do
          :ok ->
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", %{
               "config" => Ezagent.World.KanbanData.board_config(uri),
               "last_dispatch_status" => "ok"
             })}

          {:error, reason} ->
            gerr(socket, reason(reason))
        end

      :error ->
        gerr(socket, "bad_kanban_uri")
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

  # --- 新建 kanban（在 plugin InstanceSupervisor 下 spawn）---------------

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
        # 经 sanctioned `URI.resource/3`（type 段任意，过 uri_query.scan）。经
        # InstanceSupervisor 直起（对齐 e2e/测试的 spawn 路径）。
        uri = Ezagent.URI.resource(ws_host, "kanban", clean)
        spawn_result = spawn_kanban(uri)

        case spawn_result do
          ok when ok in [:ok, :already] ->
            # 留在 session 子视图：把新建的导图作为选中 board 推回（不再 push_patch 离开）。
            {:noreply,
             socket
             |> assign(:last_dispatch_status, "ok")
             |> push_event("world:state", KanbanData.board_state(uri, read_ctx(socket)))}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end
    end
  end

  # --- 侧边栏选另一张导图：起活 + 推该 board 的 tree -----------------------

  defp select_board(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        :ok = KanbanData.ensure_board(uri)

        {:noreply,
         socket
         |> assign(:last_dispatch_status, "ok")
         |> push_event("world:state", KanbanData.board_state(uri, read_ctx(socket)))}

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_kanban_uri")}
    end
  end

  defp spawn_kanban(%URI{} = uri) do
    spec = %{
      id: {:kanban, URI.to_string(uri)},
      start: {Ezagent.Kind.Server, :start_link, [{EzagentPluginKanban.Kanban, %{uri: uri}}]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(EzagentPluginKanban.InstanceSupervisor, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :already
      {:error, _} = err -> err
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

  defp push_tree(socket, uri, status) do
    tree =
      KanbanData.read_tree(uri, %{
        caller_uri: socket.assigns.current_entity_uri,
        caller_caps: Map.get(socket.assigns, :current_caps, MapSet.new())
      })

    socket
    |> assign(:last_dispatch_status, status)
    |> push_event("world:state", %{"tree" => tree, "last_dispatch_status" => status})
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

  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()

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
