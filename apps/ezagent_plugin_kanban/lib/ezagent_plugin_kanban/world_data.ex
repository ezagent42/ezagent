defmodule EzagentPluginKanban.WorldData do
  @moduledoc """
  Read model for the world **kanban operating surface**（df-prd）。

  纯数据整形（对齐 `Ezagent.World.ConversationData` 的分工）：列出 kanban 实例、
  读某个 kanban 的节点树（经 `:get_tree` dispatch，**带登录者身份/caps**，让 per-node
  CapBAC 在 Behavior 内如实判）、把树整成 JSON-safe（atom→string）给前端。

  ## kanban-as-role（K4 — read-model 重接）
  看板不再是 `resource://<ws>/kanban/<name>` 的独立 Kind，而是一个 **agent**
  （role `kanban-manager` × flavor `native`）。board = 该 agent 的 `:kanban` snapshot
  slice。本读模型据此重接两处（spec §3.5 / plan K4）：

    * **list_instances** ——`Ezagent.Agent.RecipeResolver.list_by_recipe("kanban-manager",
      workspace_uri)`（RF-7，**快照来源**，覆盖 live + dormant，冷启动仍枚举），
      不再 `EzagentDomainUi.AutoDerive.list_instances(:kanban)`（按 Kind 类型，
      kanban-manager 的 Kind 是 `Entity.Agent` → 类型匹配为假）。返回的 URI 即
      `entity://<ws>/agent/<id>` ——既是列表项、也是前端 dispatch 目标。
    * **dispatch 目标** ——`Ezagent.URI.with_action(entity://agent, :kanban, action)`
      = `entity://<ws>/agent/<id>?action=kanban.<action>`，**带登录者身份/caps**
      （R3：caller=人类用户，per-node owner 授权在 Behavior 内如实判）。

  连接器配置（github_repo/miro 板名）、Miro 凭证连接状态、pr 节点的 CI 评价，
  全部由 `:get_tree` dispatch 一并返回（Behavior 内只读投影），world 侧不再持有 kanban
  数据代码（债②可搬半 2026-07-17 搬进本 plugin）。GitHub 主动连接器已退役（gh 连通是 agent 的 CLI 行为），
  `github` 连接状态字段随之退役；`config.github_repo` 仍是纯数据（拼 git 链接用）。dormant 的 passive kanban-manager 经 `ensure_spawned/1`
  （`SpawnRegistry.spawn` 从快照 rehydrate）先起活，再 dispatch（HIGH-3 liveness）。

  写动作在 `EzagentPluginKanban.WorldActions`；本模块只读。
  """

  alias Ezagent.{Agent.RecipeRegistry, Invocation}

  @statuses ~w(claimed doing done)

  # kanban-manager role 名（world 已在 list_instances 用此名经 list_by_recipe 枚举；
  # 此处复用同一 role 名 read-through 取 recipe config 数据——棒链 = layer-2 数据，
  # world 不硬编码 9 棒。taxonomy §4.1 de-bake）。
  @kanban_role "kanban-manager"

  @doc "为 kanban 路由（列表页 entity_uri=nil / 详情页带 uri）构建前端 state。"
  @spec state_for(map(), map()) :: map()
  def state_for(%{component: "kanban"} = route, ctx) do
    uri = Map.get(route, :entity_uri)
    snapshot = uri && board_snapshot(uri, ctx)

    %{
      "component" => "kanban",
      # 与 WorkspacePluginData / IdentityData 对齐：React 外壳用 "title" 渲染 H1、
      # 用 "path" 算导航高亮。缺这两个字段会让 H1 退回 pageTitle 默认 "Sessions"、
      # 且 path=undefined 触发 navClass 把 Overview 误判为 active（FP5 S9）。
      # 用 Map.get 防御式取（与上面 :entity_uri 一致）：生产路由总带 title/path,
      # 但测试可能传精简 route,避免 KeyError。
      "title" => Map.get(route, :title),
      "path" => Map.get(route, :path),
      "kanban_uri" => encode_uri(uri),
      "instances" => list_instances(ctx),
      "tree" => snapshot && snapshot["tree"],
      # 棒链来自 recipe config 数据（layer-2），不再 world 侧 @stages 硬编码。
      "stages" => stages_from_recipe(),
      "statuses" => @statuses,
      "miro" => (snapshot && snapshot["miro"]) || %{"configured" => false},
      "config" => snapshot && snapshot["config"],
      "last_dispatch_status" => nil
    }
  end

  @doc """
  列出本 workspace 的 kanban-manager agents（role `kanban-manager`）。

  RF-7 `Ezagent.Agent.RecipeResolver.list_by_recipe/2` ——**快照来源**，覆盖 live +
  dormant：一个 passive 的 kanban-manager 在 BEAM 重启后即便没 live 仍枚举得到
  （否则 board 会从 UI 静默消失，HIGH-3）。`workspace_uri`（ctx 携带）把扫描限定
  在本 tenant，不跨租户泄漏。返回的 URI 即 `entity://<ws>/agent/<id>` ——既是列表项
  也是前端 dispatch 目标。
  """
  @spec list_instances(map()) :: [map()]
  def list_instances(ctx) do
    "kanban-manager"
    |> Ezagent.Agent.RecipeResolver.list_by_recipe(workspace_scope(ctx))
    |> Enum.filter(&visible?(&1, ctx))
    |> Enum.map(&board_row(&1, ctx))
  rescue
    _ -> []
  end

  # board URI → 前端行（列表项 + dispatch 目标 + 详情路径）。list_instances 与
  # session_boards 同形复用。⑲ 删板 UI：`owned` = caller 是板主人（`data_owner`，
  # 复用发现口径的 owns_board?/2）——前端只对自己是版主的板出删除入口
  # （真授权仍在后端 `BoardProvision.delete_board` 的 caller==data_owner 校验）。
  defp board_row(%URI{} = uri, ctx) do
    %{
      "uri" => encode_uri(uri),
      "name" => uri_name(uri),
      "path" => detail_path(uri),
      "owned" => owns_board?(Map.get(ctx, :caller_uri), uri)
    }
  end

  @doc """
  某个 session 所属 workspace 的 kanban-manager boards，按 CBAC 权属对 caller 收敛。

  与 `list_instances/1` 的区别只在 workspace 来源：这里从 **session URI** 解析
  （`Ezagent.URI.workspace_of/1`，board 是 workspace 级 actor、不经 session 成员表，
  参照 `EzagentPluginKanban.ActionSet.KanbanRender.boards_for/1` 的解析方式），
  而非 ctx 的 `workspace_uri`。枚举经 `list_by_recipe`（快照来源，覆盖 dormant），
  复用同一 `visible?/2`（admin 全见 / own / 持 board-cap）。返回与 `list_instances/1`
  同形的 board 行。session 无法解析出 workspace（`:any`）→ `[]`。
  """
  @spec session_boards(URI.t(), map()) :: [map()]
  def session_boards(%URI{} = session_uri, ctx) do
    case Ezagent.URI.workspace_of(session_uri) do
      %URI{} = ws ->
        "kanban-manager"
        |> Ezagent.Agent.RecipeResolver.list_by_recipe(ws)
        |> Enum.filter(&visible?(&1, ctx))
        |> Enum.map(&board_row(&1, ctx))

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  def session_boards(_, _), do: []

  # --- 发现按 CBAC 权属收敛（Task 2） ------------------------------------
  # fail-open（谁都看到全 workspace 的板）→ 权属过滤：
  #   * workspace admin（`Ezagent.Identity.AdminAuthority.admin?/2`）看全部；
  #   * 普通用户只看到 own（板的 `data_owner` 是自己）或持有指向该板 cap 的板。
  # ctx 的 caller 身份字段 = `:caller_uri` / `:caller_caps`（world `WorldActions.read_ctx`
  # 注入；`caller_caps` 是 mount 期注入的 caller 身份 cap 快照，即触发这次读的 caller 当时
  # 持有的全量 cap 集）。
  @doc """
  发起人对某块板是否有 access（可见即可分享）—— admin / 板主人（`data_owner`）/ 持指向该板
  的 cap。ctx 用 `WorldActions.read_ctx` 形状（`:caller_uri` / `:caller_caps`）。

  分享看板（T6.4，`EzagentPluginKanban.WorldActions.share_link/2`）的 access gate 复用这同一条
  发现可见性谓词（`visible?/2`），不新发明授权：能看见（own / 持 cap / admin）即可分享。
  """
  @spec can_share?(URI.t(), map()) :: boolean()
  def can_share?(%URI{} = board_uri, ctx), do: visible?(board_uri, ctx)

  defp visible?(%URI{} = board_uri, ctx) do
    caller = Map.get(ctx, :caller_uri)
    caps = Map.get(ctx, :caller_caps) || MapSet.new()

    Ezagent.Identity.AdminAuthority.admin?(caller, caps) or
      owns_or_holds_cap?(caller, caps, board_uri)
  end

  defp visible?(_, _), do: false

  defp owns_or_holds_cap?(caller, caps, board_uri),
    do: owns_board?(caller, board_uri) or holds_board_cap?(caps, board_uri)

  # own：板（kanban-manager agent）的 `data_owner`（经 creator / lineage）== caller。
  # 与核心 dispatch chokepoint（`CapabilityRegistry.authorize_cap_shape` 的
  # `caller == owner`）同款结构比对。ensure_loaded 保守保留（历史上本模块住 world、无 plugin dep）→
  # 先 ensure_loaded；解析不出 owner（`:no_owner`/`:any`）保守判不可见。
  defp owns_board?(%URI{} = caller, %URI{} = board_uri) do
    _ = Code.ensure_loaded(Ezagent.ActionSet.Kanban)

    case Ezagent.CapabilityRegistry.data_owner_of(
           Ezagent.ActionSet.Kanban,
           Ezagent.URI.instance(board_uri)
         ) do
      %URI{} = owner -> owner == caller
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp owns_board?(_, _), do: false

  # holds：caller 持有一张 instance 精确指向该板的 cap（Task 3/4/5 发钥匙的形状，
  # 以及建板时的 creator-manage cap）。instance 经 `URI.instance/1` 归一化后结构比对。
  defp holds_board_cap?(caps, %URI{} = board_uri) do
    target = Ezagent.URI.instance(board_uri)

    Enum.any?(caps, fn
      %Ezagent.Capability{instance: %URI{} = inst} -> Ezagent.URI.instance(inst) == target
      _ -> false
    end)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp holds_board_cap?(_, _), do: false

  @doc "选中某个 kanban 的 state：`kanban_uri` + `tree` + 全量 `instances`（侧边栏切换用）。"
  @spec board_state(URI.t(), map()) :: map()
  def board_state(%URI{} = uri, ctx) do
    snapshot = board_snapshot(uri, ctx)

    %{
      "kanban_uri" => encode_uri(uri),
      "tree" => snapshot["tree"],
      "instances" => list_instances(ctx),
      "config" => snapshot["config"],
      "miro" => snapshot["miro"],
      "last_dispatch_status" => "ok"
    }
  end

  @doc """
  确保一个 kanban-manager agent 起活：dormant 的 passive agent 无 chat 流量保温，
  BEAM 重启后处于休眠。`get_tree` dispatch 打到没 live 的 agent 前先经核心 owner-gated
  chokepoint `Ezagent.LocalRuntime.ensure_started/1`（委托 `SpawnRegistry.spawn`，从
  `entity://<ws>/agent/<id>` 的快照 rehydrate）起活（HIGH-3 liveness）。已 live 幂等返回。
  """
  @spec ensure_spawned(URI.t()) :: :ok
  def ensure_spawned(%URI{} = uri) do
    _ = Ezagent.LocalRuntime.ensure_started(uri)
    :ok
  end

  @doc """
  读一个 kanban 的节点树（dispatch get_tree，身份=登录者），整成 JSON-safe。
  只返回 tree（nodes/root_id/drops，pr 节点附 ci）；连接器配置/状态走 `board_snapshot/2`。
  """
  @spec read_tree(URI.t(), map()) :: map()
  def read_tree(%URI{} = uri, ctx), do: board_snapshot(uri, ctx)["tree"]

  @doc """
  一次 `:get_tree` dispatch 拿全量看板快照：`tree`（JSON-safe 富树，pr 节点附 ci）+
  `config`（本图连接器配置）+ `miro`（凭证连接状态）。Behavior 内只读投影，
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
        ctx: dispatch_ctx(ctx),
        origin: :authenticated_external
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
          # 棒链从 get_tree 响应读（Behavior 从 recipe config 投影；layer-2 数据），
          # 找不到回 recipe 直读（详情页冷启动场景）。
          "stages" => stages_from_res(res) || stages_from_recipe(),
          "config" => jsonable_config(Map.get(res, :config)),
          "miro" => jsonable_status(Map.get(res, :miro))
        }

      _ ->
        %{
          "tree" => %{"nodes" => %{}, "root_id" => nil, "drops" => []},
          "stages" => stages_from_recipe(),
          "config" => %{"github_repo" => nil, "miro_board" => nil},
          "miro" => %{"configured" => false}
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

  # 棒链来自 kanban-manager recipe 的 config.stages（layer-2 数据，read-through over
  # RecipeRegistry）。世界侧不硬编码 9 棒——棒链是业务语义，住在 recipe config 里
  # （taxonomy §4.1 / 红线 1+2）。返回 string list（前端要 JSON-safe 字符串）。
  # 无 recipe（未 seed / 冷启动前）→ []，前端渲染退化（与原 @stages 缺省等价的最小退路）。
  defp stages_from_recipe do
    case RecipeRegistry.lookup(@kanban_role) do
      {:ok, %{config: %{} = config}} ->
        case config[:stages] || config["stages"] do
          [_ | _] = stages -> Enum.map(stages, &to_string/1)
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # get_tree 响应里的棒链（Behavior 从 recipe config 投影出来的 atom list）→ string list。
  defp stages_from_res(res) do
    case Map.get(res, :stages) do
      [_ | _] = stages -> Enum.map(stages, &to_string/1)
      _ -> nil
    end
  end

  # list-by-role 的 workspace 边界（RF-7 scoping）：ctx 携带 `workspace_uri`
  # （world_live `state_for_route` 注入）→ 限定快照扫描在本 tenant。缺省 `:all`
  # 仅 system-scope 才走得到（world 永远带 workspace_uri）。
  defp workspace_scope(ctx) do
    case Map.get(ctx, :workspace_uri) do
      %URI{} = ws -> ws
      ws when is_binary(ws) and ws != "" -> ws
      _ -> :all
    end
  end

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
      "metrics" => Enum.map(Map.get(n, :metrics, []), &jsonable_map/1),
      # ㉕ 非破坏 drop 标（前端红框渲染）；旧快照节点无该键 → false。
      "dropped" => Map.get(n, :dropped, false)
    }

    # 片5：ci_stage 棒节点附 CI 评价摘要（Behavior 在 get_tree 里按 ci_stage 算好、
    # 按 node_id 索引；world 不再硬编码 :pr——只看 ci map 有无此节点）。
    case Map.get(ci, id) do
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
