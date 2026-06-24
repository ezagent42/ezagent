defmodule Ezagent.World.KanbanData do
  @moduledoc """
  Read model for the world **kanban operating surface**（df-prd）。

  纯数据整形（对齐 `Ezagent.World.ConversationData` 的分工）：列出 kanban 实例、
  读某个 kanban 的节点树（经 `:get_tree` dispatch，**带登录者身份/caps**，让 per-node
  CapBAC 在 Behavior 内如实判）、把树整成 JSON-safe（atom→string）给前端。

  写动作在 `Ezagent.World.KanbanActions`；本模块只读。
  """

  alias Ezagent.Invocation

  @stages ~w(positioning metric pain anchor ux feature issue test pr)
  @statuses ~w(claimed doing done)

  @doc "为 kanban 路由（列表页 entity_uri=nil / 详情页带 uri）构建前端 state。"
  @spec state_for(map(), map()) :: map()
  def state_for(%{component: "kanban"} = route, ctx) do
    uri = Map.get(route, :entity_uri)

    %{
      "component" => "kanban",
      "kanban_uri" => encode_uri(uri),
      "instances" => list_instances(),
      "tree" => uri && read_tree(uri, ctx),
      "stages" => @stages,
      "statuses" => @statuses,
      "miro" => miro_status(),
      "github" => github_status(),
      "last_dispatch_status" => nil
    }
  end

  @doc "Miro 凭证连接状态（只读；凭证填 `system://credentials/miro.yaml`，同 feishu app 凭证）。"
  @spec miro_status() :: map()
  def miro_status do
    case EzagentPluginKanban.Miro.read_creds() do
      {:ok, %{token: t, board_id: b}} when is_binary(t) and t != "" ->
        %{"configured" => true, "board_id" => b}

      _ ->
        %{"configured" => false}
    end
  rescue
    _ -> %{"configured" => false}
  end

  @doc "GitHub 凭证连接状态（只读；凭证填 `system://credentials/github.yaml`，同 Miro）。"
  @spec github_status() :: map()
  def github_status do
    case EzagentPluginKanban.Github.read_creds() do
      {:ok, %{token: t, repo: r}} when is_binary(t) and t != "" ->
        %{"configured" => true, "repo" => r}

      _ ->
        %{"configured" => false}
    end
  rescue
    _ -> %{"configured" => false}
  end

  @doc "列出当前活着的 kanban 实例。"
  @spec list_instances() :: [map()]
  def list_instances do
    Module.concat([EzagentDomainUi, AutoDerive])
    |> apply(:list_instances, [:kanban])
    |> Enum.map(fn %{uri: uri} ->
      %{"uri" => encode_uri(uri), "name" => uri_name(uri), "path" => detail_path(uri)}
    end)
  rescue
    _ -> []
  end

  @doc """
  session 内 kanban 子视图的数据：按 session URI 派生一个稳定的
  `resource://<ws>/kanban/sess-<hash>` board（每个 session 一张图），确保起活，返回
  `{kanban_uri, tree, stages, statuses}` 给前端子视图。
  """
  @spec session_board(URI.t(), map()) :: map()
  def session_board(%URI{} = session_uri, ctx) do
    uri = session_kanban_uri(session_uri)
    ensure_spawned(uri)
    Map.merge(board_state(uri, ctx), %{"stages" => @stages, "statuses" => @statuses})
  end

  @doc "选中某个 kanban 的 state：`kanban_uri` + `tree` + 全量 `instances`（侧边栏切换用）。"
  @spec board_state(URI.t(), map()) :: map()
  def board_state(%URI{} = uri, ctx) do
    %{
      "kanban_uri" => encode_uri(uri),
      "tree" => read_tree(uri, ctx),
      "instances" => list_instances(),
      "config" => board_config(uri),
      "last_dispatch_status" => "ok"
    }
  end

  @doc "本图的连接器配置（github_repo + miro 板名；token 在全局，不在这）。"
  @spec board_config(URI.t()) :: map()
  def board_config(%URI{} = uri) do
    c = EzagentPluginKanban.BoardConfig.read(uri)
    %{"github_repo" => c.github_repo, "miro_board" => c.miro_board}
  end

  @doc "确保某 kanban Kind 起活（侧边栏选已有导图时用）。"
  @spec ensure_board(URI.t()) :: :ok
  def ensure_board(%URI{} = uri) do
    ensure_spawned(uri)
    :ok
  end

  @doc false
  def session_kanban_uri(%URI{} = session_uri) do
    ws = Ezagent.URI.workspace_name!(session_uri)
    name = "sess-" <> Integer.to_string(:erlang.phash2(URI.to_string(session_uri)))
    Ezagent.URI.resource(ws, "kanban", name)
  end

  # 起活（若该 kanban Kind 没在跑就经 InstanceSupervisor 直起；已在跑则忽略）。
  defp ensure_spawned(%URI{} = uri) do
    spec = %{
      id: {:kanban, URI.to_string(uri)},
      start: {Ezagent.Kind.Server, :start_link, [{EzagentPluginKanban.Kanban, %{uri: uri}}]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(EzagentPluginKanban.InstanceSupervisor, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end

  @doc "读一个 kanban 的节点树（dispatch get_tree，身份=登录者），整成 JSON-safe。"
  @spec read_tree(URI.t(), map()) :: map()
  def read_tree(%URI{} = uri, ctx) do
    target = Ezagent.URI.with_action(uri, :kanban, :get_tree)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{},
        ctx: dispatch_ctx(ctx)
      })

    case result do
      {:ok, %{tree: %{nodes: nodes, root_id: root} = t} = res} ->
        %{
          "nodes" => jsonable_nodes(nodes, t),
          "root_id" => root,
          "drops" => Enum.map(Map.get(res, :drops, []), &jsonable_map/1)
        }

      _ ->
        %{"nodes" => %{}, "root_id" => nil, "drops" => []}
    end
  end

  @doc false
  def dispatch_ctx(ctx) do
    %{
      caller: Map.get(ctx, :caller_uri),
      caps: Map.get(ctx, :caller_caps, MapSet.new()),
      reply: {:caller_inbox, self()}
    }
  end

  # --- helpers --------------------------------------------------------

  defp jsonable_nodes(nodes, tree) when is_map(nodes) do
    Map.new(nodes, fn {id, n} -> {id, jsonable_node(n, id, tree)} end)
  end

  defp jsonable_node(n, id, tree) do
    base = %{
      "parent_id" => Map.get(n, :parent_id),
      "title" => Map.get(n, :title),
      "order" => Map.get(n, :order),
      "stage" => to_str(Map.get(n, :stage)),
      "owner" => Map.get(n, :owner),
      "status" => to_str(Map.get(n, :status)),
      "artifacts" => Enum.map(Map.get(n, :artifacts, []), &jsonable_artifact/1),
      "metrics" => Enum.map(Map.get(n, :metrics, []), &jsonable_map/1)
    }

    # 片5：pr 节点附 CI 评价摘要（纯读，前端 ci 徽章 + 片6 出 PR 评论用）
    if Map.get(n, :stage) == :pr do
      Map.put(base, "ci", ci_summary(tree, id))
    else
      base
    end
  end

  defp ci_summary(tree, id) do
    v = EzagentPluginKanban.Ci.check_pr_gate(tree, id)

    %{
      "score" => v.score,
      "max" => v.max,
      "markdown" => v.markdown,
      "criteria" => Enum.map(v.criteria, fn c -> %{"name" => c.name, "ok" => c.ok} end)
    }
  end

  defp jsonable_map(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)

  # file 类 artifact：url 是 uploads URI(resource://<ws>/uploads/…)，签发一个下载 href
  # (DownloadToken，同 chat 附件)，让"打开"可下载；其余 artifact 原样。
  defp jsonable_artifact(a) do
    base = jsonable_map(a)
    url = base["url"]

    if base["kind"] == "file" and is_binary(url) and String.starts_with?(url, "resource://") do
      case mint_download(url) do
        {:ok, href} -> Map.put(base, "url", href)
        _ -> base
      end
    else
      base
    end
  end

  defp mint_download(url) do
    with {:ok, %URI{} = uri} <- Ezagent.URI.parse(url) do
      {:ok, "/uploads/download?token=" <> Ezagent.Uploads.DownloadToken.mint!(uri)}
    end
  rescue
    _ -> :error
  end

  defp to_str(nil), do: nil
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(s), do: s

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil

  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()

  defp detail_path(%URI{} = uri),
    do: "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(uri))
end
