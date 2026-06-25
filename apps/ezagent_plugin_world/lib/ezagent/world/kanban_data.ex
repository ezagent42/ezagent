defmodule Ezagent.World.KanbanData do
  @moduledoc """
  Read model for the world **kanban operating surface**（df-prd）。

  纯数据整形（对齐 `Ezagent.World.ConversationData` 的分工）：列出 kanban 实例、
  读某个 kanban 的节点树（经 `:get_tree` dispatch，**带登录者身份/caps**，让 per-node
  CapBAC 在 Behavior 内如实判）、把树整成 JSON-safe（atom→string）给前端。

  ## df-tech 下沉（kanban-clean）
  本模块**不再直引** kanban plugin 的连接器模块：连接器配置（github_repo/miro 板名）、
  Miro/GitHub 凭证连接状态、pr 节点的 CI 评价，全部由 `:get_tree` dispatch 一并返回
  （Behavior 内只读投影）。spawn 靠 `Ezagent.Invocation.dispatch` 在目标 Kind 没 live
  时自动起活（经注册的 Kind 类型 + ReadyGate），不再 `DynamicSupervisor.start_child`。

  写动作在 `Ezagent.World.KanbanActions`；本模块只读。
  """

  alias Ezagent.Invocation

  @stages ~w(positioning metric pain anchor ux feature issue test pr)
  @statuses ~w(claimed doing done)

  @doc "为 kanban 路由（列表页 entity_uri=nil / 详情页带 uri）构建前端 state。"
  @spec state_for(map(), map()) :: map()
  def state_for(%{component: "kanban"} = route, ctx) do
    uri = Map.get(route, :entity_uri)
    snapshot = uri && board_snapshot(uri, ctx)

    %{
      "component" => "kanban",
      "kanban_uri" => encode_uri(uri),
      "instances" => list_instances(),
      "tree" => snapshot && snapshot["tree"],
      "stages" => @stages,
      "statuses" => @statuses,
      "miro" => (snapshot && snapshot["miro"]) || %{"configured" => false},
      "github" => (snapshot && snapshot["github"]) || %{"configured" => false},
      "config" => snapshot && snapshot["config"],
      "last_dispatch_status" => nil
    }
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
  `resource://<ws>/kanban/sess-<hash>` board（每个 session 一张图），返回
  `{kanban_uri, tree, stages, statuses}` 给前端子视图（dispatch 自动起活）。
  """
  @spec session_board(URI.t(), map()) :: map()
  def session_board(%URI{} = session_uri, ctx) do
    uri = session_kanban_uri(session_uri)
    Map.merge(board_state(uri, ctx), %{"stages" => @stages, "statuses" => @statuses})
  end

  @doc "选中某个 kanban 的 state：`kanban_uri` + `tree` + 全量 `instances`（侧边栏切换用）。"
  @spec board_state(URI.t(), map()) :: map()
  def board_state(%URI{} = uri, ctx) do
    snapshot = board_snapshot(uri, ctx)

    %{
      "kanban_uri" => encode_uri(uri),
      "tree" => snapshot["tree"],
      "instances" => list_instances(),
      "config" => snapshot["config"],
      "miro" => snapshot["miro"],
      "github" => snapshot["github"],
      "last_dispatch_status" => "ok"
    }
  end

  @doc """
  确保某 kanban Kind 起活（fresh kanban 无快照不会被 dispatch 自动起）：经核心
  owner-gated chokepoint `Ezagent.LocalRuntime.ensure_started/1`（内部委托 kanban plugin
  注册的 `resource://*/kanban/*` 工厂），world 不直引 kanban 模块。已 live 幂等返回。
  """
  @spec ensure_spawned(URI.t()) :: :ok
  def ensure_spawned(%URI{} = uri) do
    _ = Ezagent.LocalRuntime.ensure_started(uri)
    :ok
  end

  @doc false
  def session_kanban_uri(%URI{} = session_uri) do
    ws = Ezagent.URI.workspace_name!(session_uri)
    name = "sess-" <> Integer.to_string(:erlang.phash2(URI.to_string(session_uri)))
    Ezagent.URI.resource(ws, "kanban", name)
  end

  @doc """
  读一个 kanban 的节点树（dispatch get_tree，身份=登录者），整成 JSON-safe。
  只返回 tree（nodes/root_id/drops，pr 节点附 ci）；连接器配置/状态走 `board_snapshot/2`。
  """
  @spec read_tree(URI.t(), map()) :: map()
  def read_tree(%URI{} = uri, ctx), do: board_snapshot(uri, ctx)["tree"]

  @doc """
  一次 `:get_tree` dispatch 拿全量看板快照：`tree`（JSON-safe 富树，pr 节点附 ci）+
  `config`（本图连接器配置）+ `miro`/`github`（凭证连接状态）。Behavior 内只读投影，
  world 不再直引 kanban plugin 的连接器模块。
  """
  @spec board_snapshot(URI.t(), map()) :: map()
  def board_snapshot(%URI{} = uri, ctx) do
    # fresh kanban（无快照）不会被 dispatch 自动起活 → 先确保起活（已 live 幂等返回）。
    :ok = ensure_spawned(uri)
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
        ci = Map.get(res, :ci, %{})

        %{
          "tree" => %{
            "nodes" => jsonable_nodes(nodes, t, ci),
            "root_id" => root,
            "drops" => Enum.map(Map.get(res, :drops, []), &jsonable_map/1)
          },
          "config" => jsonable_config(Map.get(res, :config)),
          "miro" => jsonable_status(Map.get(res, :miro)),
          "github" => jsonable_status(Map.get(res, :github))
        }

      _ ->
        %{
          "tree" => %{"nodes" => %{}, "root_id" => nil, "drops" => []},
          "config" => %{"github_repo" => nil, "miro_board" => nil},
          "miro" => %{"configured" => false},
          "github" => %{"configured" => false}
        }
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

  # 连接器配置（github_repo + miro 板名）：Behavior 返回 atom 键 map，转 string 键给前端。
  defp jsonable_config(%{github_repo: repo, miro_board: board}),
    do: %{"github_repo" => repo, "miro_board" => board}

  defp jsonable_config(_), do: %{"github_repo" => nil, "miro_board" => nil}

  # 凭证连接状态（configured + board_id/repo）：atom 键 → string 键。
  defp jsonable_status(%{configured: true} = s),
    do:
      %{"configured" => true}
      |> maybe_put("board_id", Map.get(s, :board_id))
      |> maybe_put("repo", Map.get(s, :repo))

  defp jsonable_status(_), do: %{"configured" => false}

  defp maybe_put(m, _k, nil), do: m
  defp maybe_put(m, k, v), do: Map.put(m, k, v)

  defp jsonable_nodes(nodes, tree, ci) when is_map(nodes) do
    Map.new(nodes, fn {id, n} -> {id, jsonable_node(n, id, tree, ci)} end)
  end

  defp jsonable_node(n, id, _tree, ci) do
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

    # 片5：pr 节点附 CI 评价摘要（Behavior 在 get_tree 里算好，按 node_id 索引）。
    case Map.get(n, :stage) == :pr && Map.get(ci, id) do
      %{} = v -> Map.put(base, "ci", jsonable_ci(v))
      _ -> base
    end
  end

  defp jsonable_ci(v) do
    %{
      "score" => Map.get(v, :score),
      "max" => Map.get(v, :max),
      "markdown" => Map.get(v, :markdown),
      "criteria" =>
        v |> Map.get(:criteria, []) |> Enum.map(fn c -> %{"name" => c.name, "ok" => c.ok} end)
    }
  end

  defp jsonable_map(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)

  # file 类 artifact：url 是 uploads URI(resource://<ws>/uploads/…)，签发一个下载 href
  # (DownloadToken，同 chat 附件)，让"打开"可下载；其余 artifact 原样。
  defp jsonable_artifact(a) do
    base = jsonable_map(a)
    url = base["url"]

    if base["kind"] == "file" and is_binary(url) do
      case mint_download(url) do
        {:ok, href} -> Map.put(base, "url", href)
        _ -> base
      end
    else
      base
    end
  end

  # 仅当 url 解析为 resource:// URI（uploads 附件）时签发下载 href；
  # 其余（非 URI / 别的 scheme）返回 :error，原样保留。scheme 判断走
  # `Ezagent.URI.scheme?/2`，不裸比 `"resource://"` 字面。
  defp mint_download(url) do
    with {:ok, %URI{} = uri} <- Ezagent.URI.parse(url),
         true <- Ezagent.URI.scheme?(uri, :resource) do
      {:ok, "/uploads/download?token=" <> Ezagent.Uploads.DownloadToken.mint!(uri)}
    else
      _ -> :error
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
