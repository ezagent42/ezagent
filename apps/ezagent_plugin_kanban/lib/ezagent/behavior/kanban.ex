defmodule Ezagent.ActionSet.Kanban do
  @moduledoc """
  Kanban Behavior — 思维导图节点树的动作处理者（df-prd）。

  `use Ezagent.Lifecycle` + `action/3` 宏 + `create/1` + `handle_<action>/2`
  （返回 `{:ok, result, [effect]}`）。读用 `ctx[:read].(:key, default)`，写用
  `{:set, key, value}`（全文经唯一的 `commit/1` 收敛——arch.scan set_effect_sites 友好）。

  ## 增量3：全链路拓扑节点 + 认领/状态/挂载/指标 + per-node 授权
  节点处在产品链某一阶段（`stage`），可**认领**（`owner`）、记**状态**、**挂载**工具产物
  （`artifacts`）、挂**指标**（`metrics`）。

      node = %{
        parent_id, title, order,                       # 拓扑
        stage:     atom,                                # 接力链阶段(具体哪几棒见 recipe config 数据,非权限边界)
        owner:     user_uri | nil,                      # 认领人; 既问责又是权限闸
        status:    :unassigned|:claimed|:doing|:done,   # 粗4态(细状态归外部工具)
        artifacts: [%{tool,kind,ref,url}],              # 挂工具产物(github PR/飞书文档/xmind…)
        metrics:   [%{name,target,current,unit}]        # 挂指标(价值/运营节点)
      }

  ## stage 链 = LAYER-2 DATA（taxonomy §4.1）
  本 Behavior 是**通用看板机制**（列/卡/stage/认领/PR 动作 + 状态机），**不含**具体阶段名。
  具体的接力链（哪几棒、顺序）+ CI 评价触发棒 + markmap 导入默认棒 = 业务语义，住在
  `kanban-manager` recipe 的 `config` 数据里（`EzagentPluginKanban.Application.kanban_manager_recipe/0`），
  本 Behavior 在运行时经 `Shared.stages/1` / `Shared.config_get/3` 读回（read-through over
  `RecipeRegistry`）。这样业务语义不进 layer-1 代码（taxonomy 红线 1+2）。

  ## 权限 = admin + 节点 owner（per-node，在 handler 内查；data_owner 是 per-instance）
  改一个节点 = `ctx.caller == node.owner` 或 caller 持 wildcard cap(admin)；未认领节点
  任意成员可 `claim`。**不变式**：`owner==nil ⟺ status==:unassigned`。
  """

  use Ezagent.Lifecycle

  alias Ezagent.ActionSet.Kanban.Connectors
  alias Ezagent.ActionSet.Kanban.Shared
  alias EzagentPluginKanban.BoardConfig
  alias EzagentPluginKanban.Ci
  alias EzagentPluginKanban.Markmap
  alias EzagentPluginKanban.Miro

  # set_status 只在已认领后的三态间流转；:unassigned 经 claim/unclaim 切换。
  @settable_status [:claimed, :doing, :done]

  action(:add_node,
    args: %{parent_id: :string, title: :string},
    returns: %{id: :string},
    caps: [:add_node],
    modes: [:call],
    description: "新增节点；parent_id=\"\" 建根（建根=admin；加子=父节点owner或admin）"
  )

  action(:rename_node,
    args: %{id: :string, title: :string},
    returns: %{},
    caps: [:rename_node],
    modes: [:call],
    description: "改标题"
  )

  action(:move_node,
    args: %{id: :string, new_parent_id: :string},
    returns: %{},
    caps: [:move_node],
    modes: [:call],
    description: "移动(禁环)"
  )

  action(:remove_node,
    args: %{id: :string},
    returns: %{},
    caps: [:remove_node],
    modes: [:call],
    description: "删(级联)"
  )

  action(:set_stage,
    args: %{id: :string, stage: :string},
    returns: %{},
    caps: [:set_stage],
    modes: [:call],
    description: "改节点所属链条阶段"
  )

  action(:claim_node,
    args: %{id: :string},
    returns: %{},
    caps: [:claim_node],
    modes: [:call],
    description: "认领未分配节点(owner=caller,status→claimed)"
  )

  action(:unclaim_node,
    args: %{id: :string},
    returns: %{},
    caps: [:unclaim_node],
    modes: [:call],
    description: "退领(owner=nil,status→unassigned)"
  )

  action(:set_status,
    args: %{id: :string, status: :string},
    returns: %{},
    caps: [:set_status],
    modes: [:call],
    description: "状态流转(claimed/doing/done,需先认领)"
  )

  action(:attach_artifact,
    args: %{id: :string, artifact: :map},
    returns: %{},
    caps: [:attach_artifact],
    modes: [:call],
    description: "挂一个工具产物"
  )

  action(:detach_artifact,
    args: %{id: :string, ref: :string},
    returns: %{},
    caps: [:detach_artifact],
    modes: [:call],
    description: "按 ref 移除一个产物"
  )

  action(:set_metric,
    args: %{id: :string, metric: :map},
    returns: %{},
    caps: [:set_metric],
    modes: [:call],
    description: "按 name upsert 一个指标"
  )

  action(:drop_subtree,
    args: %{id: :string, reason: :string},
    returns: %{},
    caps: [:drop_subtree],
    modes: [:call],
    description: "砍子树(指标不达标 drop)+ 记进图级别 drop 历史(:drops, 全图属性)"
  )

  action(:get_tree,
    args: %{},
    returns: %{tree: :map},
    caps: [:get_tree],
    modes: [:call],
    description: "读整棵树"
  )

  action(:export_markmap,
    args: %{},
    returns: %{markdown: :string},
    caps: [:export_markmap],
    modes: [:call],
    description: "导出 markmap"
  )

  action(:import_markmap,
    args: %{markdown: :string},
    returns: %{count: :integer},
    caps: [:import_markmap],
    modes: [:call],
    description: "覆盖导入(admin)"
  )

  # ---------------------------------------------------------------
  # 节点 git 定位数据动作（纯数据：把 PR / commit 链接钉到节点 artifacts）。
  # GitHub 主动连接器（sync_github / push_pr / sync_prs / save_github_creds —— 调
  # GitHub API 建 issue / post 评论 / 轮询 PR）已删；这里留下的只把 git 引用
  # （PR 号、commit SHA + 路径）拼成链接挂到节点，不发任何出站 HTTP。repo 取本图
  # 配置（BoardConfig，纯数据），set_board_config 仍可记 github_repo。
  # ---------------------------------------------------------------

  action(:register_pr,
    args: %{id: :string, pr: :string},
    returns: %{},
    caps: [:register_pr],
    modes: [:call],
    description: "登记 PR 号→把 PR 链接挂到节点（不发评论）"
  )

  action(:attach_code_file,
    args: %{id: :string, sha: :string, path: :string},
    returns: %{url: :string},
    caps: [:attach_code_file],
    modes: [:call],
    description: "钉 commit SHA + 路径 → 拼 github blob 链接挂到节点"
  )

  action(:sync_miro,
    args: %{},
    returns: %{board_id: :string},
    caps: [:sync_miro],
    modes: [:call],
    description: "一键推 Miro（首次建板+绑定，之后复用同板同步）"
  )

  action(:set_board_config,
    args: %{github_repo: :string, miro_board: :string},
    returns: %{github_repo: :string, miro_board: :string},
    caps: [:set_board_config],
    modes: [:call],
    description: "写本图连接器配置（github_repo + miro 板名；token 在全局）"
  )

  action(:save_miro_creds,
    args: %{access_token: :string, board_id: :string},
    returns: %{},
    caps: [:save_miro_creds],
    modes: [:call],
    description: "保存全局 Miro 凭证（admin-gated）"
  )

  # kanban-as-role：本 Behavior 经 `kanban-manager` role 经 RF-1 per-instance 挂在
  # 通用 `Entity.Agent`（kind `:agent`）宿主上（K5 删了独立 `:kanban` 资源 Kind）。cap
  # 的 kind 轴声明 `:any`：运行时（`Kind.Runtime` §7 check 11b）按目标宿主 type_name
  # 替换 needed-cap 的 kind（Entity.Agent→`:agent`）后授权。硬写 `:kanban` 会让
  # role×native 路（recipe 铸出的 held cap 是 `:agent`）必拒。
  @doc false
  def required_caps do
    for a <- [
          :add_node,
          :rename_node,
          :move_node,
          :remove_node,
          :set_stage,
          :claim_node,
          :unclaim_node,
          :set_status,
          :attach_artifact,
          :detach_artifact,
          :set_metric,
          :drop_subtree,
          :get_tree,
          :export_markmap,
          :import_markmap,
          :register_pr,
          :attach_code_file,
          :sync_miro,
          :set_board_config,
          :save_miro_creds
        ],
        into: %{},
        do: {a, Ezagent.Capability.cap(:any, __MODULE__, a)}
  end

  # data_owner 是 per-INSTANCE（实例级 cap 收口）。per-NODE 授权在 handler 内做。
  @doc false
  def data_owner(instance), do: Ezagent.ActionSet.ApiKeys.data_owner(instance)

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{tree: empty_tree()}}

  # ---------------------------------------------------------------
  # 拓扑动作
  # ---------------------------------------------------------------

  @doc false
  def handle_add_node(args, ctx) do
    parent_id = nilify(Map.get(args, :parent_id))
    title = Map.fetch!(args, :title)
    %{nodes: nodes, root_id: root_id, seq: seq} = t = tree(ctx)

    cond do
      parent_id == nil and not admin?(ctx) ->
        {:error, :forbidden}

      parent_id != nil and not Map.has_key?(nodes, parent_id) ->
        {:error, :parent_not_found}

      parent_id != nil and not owner_or_admin?(ctx, nodes[parent_id]) ->
        {:error, :forbidden}

      true ->
        new_seq = seq + 1
        id = "n" <> Integer.to_string(new_seq)
        order = Enum.count(nodes, fn {_id, n} -> n.parent_id == parent_id end)

        # 根节点默认第一阶段（链首，来自 recipe config 数据）；子节点默认继承父阶段
        # （插入校验在 set_stage 收口）。
        stages = Shared.stages(ctx)
        stage = if parent_id, do: nodes[parent_id].stage, else: List.first(stages)
        node = new_node(parent_id, title, order, stage)
        new_root = root_id || if(parent_id == nil, do: id, else: nil)

        {:ok, %{id: id},
         [commit(%{t | nodes: Map.put(nodes, id, node), root_id: new_root, seq: new_seq})]}
    end
  end

  @doc false
  def handle_rename_node(%{id: id, title: title}, ctx),
    do: update_node(ctx, id, &%{&1 | title: title})

  @doc false
  def handle_move_node(%{id: id} = args, ctx) do
    new_parent_id = nilify(Map.get(args, :new_parent_id))
    t = tree(ctx)
    nodes = t.nodes
    stages = Shared.stages(ctx)

    cond do
      not Map.has_key?(nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, nodes[id]) ->
        {:error, :forbidden}

      new_parent_id != nil and not Map.has_key?(nodes, new_parent_id) ->
        {:error, :parent_not_found}

      new_parent_id != nil and descendant?(nodes, id, new_parent_id) ->
        {:error, :would_create_cycle}

      # R1：移动后 node.stage 必须 ≥ 新父 stage（子树各节点 stage 已 ≥ node，整链保持单调）。
      new_parent_id != nil and
          stage_index(stages, nodes[id].stage) < stage_index(stages, nodes[new_parent_id].stage) ->
        {:error, {:stage_order_violation, nodes[id].stage}}

      true ->
        order = Enum.count(nodes, fn {_i, n} -> n.parent_id == new_parent_id end)
        new_nodes = Map.put(nodes, id, %{nodes[id] | parent_id: new_parent_id, order: order})
        {:ok, %{}, [commit(%{t | nodes: new_nodes})]}
    end
  end

  @doc false
  def handle_remove_node(%{id: id}, ctx) do
    t = tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        new_nodes = Map.drop(t.nodes, subtree_ids(t.nodes, id))
        new_root = if id == t.root_id, do: nil, else: t.root_id
        {:ok, %{}, [commit(%{t | nodes: new_nodes, root_id: new_root})]}
    end
  end

  @doc false
  # drop 闭环（片8）：砍子树 + 反哺最近 pain 祖先记一笔（指标不达标→drop→回 pain 重选）。
  def handle_drop_subtree(%{id: id} = args, ctx) do
    reason = to_string(Map.get(args, :reason, ""))
    t = tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        node = t.nodes[id]
        dropped = subtree_ids(t.nodes, id)
        nodes1 = Map.drop(t.nodes, dropped)
        new_root = if id == t.root_id, do: nil, else: t.root_id

        # drop 历史 = **图级别属性**（不挂某个节点）：任何棒 drop 都追加一条到 tree.drops。
        # drops 归在 tree 里（跟 nodes/root_id 一样是 board 级数据），经唯一 commit/1 收敛——
        # 不另开 set-effect 站点（守 moduledoc「所有写动作经唯一 commit/1」约定）。
        drop_entry = %{
          title: node.title,
          stage: to_string(node.stage),
          reason: reason,
          count: length(dropped)
        }

        {:ok, %{dropped: length(dropped)},
         [
           commit(%{
             t
             | nodes: nodes1,
               root_id: new_root,
               drops: Map.get(t, :drops, []) ++ [drop_entry]
           })
         ]}
    end
  end

  @doc false
  def handle_set_stage(%{id: id, stage: stage}, ctx) do
    t = tree(ctx)
    stages = Shared.stages(ctx)

    case parse_enum(stage, stages) do
      {:ok, s} ->
        cond do
          not Map.has_key?(t.nodes, id) ->
            {:error, :node_not_found}

          # R1 插入规则：阶段顺序固定，深入只能往后——节点 stage 必须 ≥ 父、≤ 每个子。
          # 例："issue 后不能插 feature" = feature(5) < issue(6)，做 issue 子节点时拒。
          not stage_fits?(stages, t.nodes, id, s) ->
            {:error, {:stage_order_violation, stage}}

          true ->
            update_node(ctx, id, &%{&1 | stage: s})
        end

      :error ->
        {:error, {:invalid_stage, stage}}
    end
  end

  # 节点 stage 的链上索引（stages 顺序即固定链，来自 recipe config 数据；找不到当 0）。
  defp stage_index(stages, s), do: Enum.find_index(stages, &(&1 == s)) || 0

  # R1.1（固定接力链）：stage 是结构事实非自由属性，沿固定棒链推进——
  # 非根只能是"父棒"或"父棒+1"（不能跳棒、不能回退、不能乱设）；
  # 对称地，每个子只能是"本棒"或"本棒+1"。这把"随意改 stage"收死成相邻棒推进。
  # 根无父约束、只受子侧相邻棒约束（G4 拍板 2026-07-07：原"根钉死链首棒"
  # 把根永锁 positioning，改为根随子推进——全部子到位后根才进得了下一棒）。
  defp stage_fits?(stages, nodes, id, s) do
    node = nodes[id]
    si = stage_index(stages, s)

    parent_ok =
      case node.parent_id do
        nil ->
          true

        pid ->
          pi = stage_index(stages, nodes[pid].stage)
          si == pi or si == pi + 1
      end

    children_ok =
      nodes
      |> Enum.filter(fn {_i, n} -> n.parent_id == id end)
      |> Enum.all?(fn {_i, c} ->
        ci = stage_index(stages, c.stage)
        ci == si or ci == si + 1
      end)

    parent_ok and children_ok
  end

  # ---------------------------------------------------------------
  # 认领 / 状态
  # ---------------------------------------------------------------

  @doc false
  def handle_claim_node(%{id: id}, ctx) do
    t = tree(ctx)

    case Map.fetch(t.nodes, id) do
      :error ->
        {:error, :node_not_found}

      {:ok, %{owner: o}} when not is_nil(o) ->
        {:error, :already_claimed}

      {:ok, node} ->
        case caller_str(ctx) do
          nil ->
            {:error, :no_caller}

          caller ->
            new_nodes = Map.put(t.nodes, id, %{node | owner: caller, status: :claimed})
            {:ok, %{}, [commit(%{t | nodes: new_nodes})]}
        end
    end
  end

  @doc false
  def handle_unclaim_node(%{id: id}, ctx),
    do: update_node(ctx, id, &%{&1 | owner: nil, status: :unassigned})

  @doc false
  def handle_set_status(%{id: id, status: status}, ctx) do
    with {:ok, s} <- parse_enum(status, @settable_status) do
      update_node(ctx, id, fn node ->
        # 不变式：未认领不能进 claimed/doing/done
        if node.owner == nil, do: :invariant, else: %{node | status: s}
      end)
      |> case do
        {:ok, %{}, _} = ok -> ok
        {:error, :invariant} -> {:error, :must_claim_first}
        other -> other
      end
    else
      :error -> {:error, {:invalid_status, status}}
    end
  end

  # ---------------------------------------------------------------
  # 挂载: artifacts / metrics
  # ---------------------------------------------------------------

  @doc false
  def handle_attach_artifact(%{id: id, artifact: artifact}, ctx) when is_map(artifact),
    do: update_node(ctx, id, &%{&1 | artifacts: &1.artifacts ++ [normalize_artifact(artifact)]})

  @doc false
  def handle_detach_artifact(%{id: id, ref: ref}, ctx),
    do:
      update_node(
        ctx,
        id,
        &%{&1 | artifacts: Enum.reject(&1.artifacts, fn a -> a.ref == ref end)}
      )

  @doc false
  def handle_set_metric(%{id: id, metric: metric}, ctx) when is_map(metric) do
    m = normalize_metric(metric)

    update_node(ctx, id, fn node ->
      others = Enum.reject(node.metrics, fn x -> x.name == m.name end)
      %{node | metrics: others ++ [m]}
    end)
  end

  # ---------------------------------------------------------------
  # 读 / 导入导出
  # ---------------------------------------------------------------

  @doc false
  def handle_get_tree(_args, ctx) do
    t = tree(ctx)
    inner = %{nodes: t.nodes, root_id: t.root_id}
    stages = Shared.stages(ctx)
    ci_stage = Shared.config_atom(ctx, :ci_stage, List.last(stages))

    # drops = 图级别 drop 历史（全图属性，存在 tree 里，随 tree 一起读出）。
    # config/miro/ci = 只读投影（df-tech 下沉：world 不再直读 BoardConfig/Miro，
    # 全经此 dispatch 返回拿到）。config.github_repo 仍是纯数据（节点/板记 repo），
    # 但 GitHub 主动连接器已删，故不再返回 `github` 连接状态字段。
    # stages = 接力链（layer-2 recipe config 数据投影）：world 读模型 + 前端经此
    # dispatch 返回拿到棒链，不再 world 侧硬编码 @stages（taxonomy §4.1 de-bake）。
    {:ok,
     %{
       tree: inner,
       drops: Map.get(t, :drops, []),
       config: board_config(ctx),
       miro: miro_status(),
       stages: stages,
       # ci_stage 棒节点的 CI 评价摘要（前端 ci 徽章）：%{node_id => verdict}，纯函数算。
       ci: ci_summaries(inner, ci_stage)
     }, []}
  end

  # 本图连接器配置（github_repo + miro 板名）；self_uri = 本 kanban 实例 URI。
  defp board_config(ctx) do
    case ctx[:self_uri] do
      %URI{} = uri ->
        c = BoardConfig.read(uri)
        %{github_repo: c.github_repo, miro_board: c.miro_board}

      _ ->
        %{github_repo: nil, miro_board: nil}
    end
  end

  defp miro_status do
    case Miro.read_creds() do
      {:ok, %{token: t, board_id: b}} when is_binary(t) and t != "" ->
        %{configured: true, board_id: b}

      _ ->
        %{configured: false}
    end
  rescue
    _ -> %{configured: false}
  end

  # 给每个 stage==ci_stage 节点算 CI 评价（纯函数，无副作用）。前端 ci 徽章用。
  # ci_stage 来自 recipe config 数据（不再硬编码 :pr；taxonomy §4.1 de-bake）。
  defp ci_summaries(%{nodes: nodes} = tree, ci_stage) do
    for {id, n} <- nodes, Map.get(n, :stage) == ci_stage, into: %{} do
      {id, Ci.check_pr_gate(tree, id)}
    end
  end

  @doc false
  def handle_export_markmap(_args, ctx) do
    t = tree(ctx)

    case t.root_id do
      nil -> {:ok, %{markdown: ""}, []}
      _ -> {:ok, %{markdown: Markmap.render(%{nodes: t.nodes, root_id: t.root_id})}, []}
    end
  end

  @doc false
  def handle_import_markmap(%{markdown: markdown}, ctx) do
    cond do
      not admin?(ctx) ->
        {:error, :forbidden}

      true ->
        case Markmap.parse(markdown) do
          {:ok, %{nodes: parsed, root_id: root_id, seq: seq}} ->
            # markmap 只有拓扑——补默认 stage/owner/status/artifacts/metrics。
            # 导入默认棒来自 recipe config 数据（不再硬编码 :feature；taxonomy §4.1）。
            import_default =
              Shared.config_atom(ctx, :import_default_stage, List.first(Shared.stages(ctx)))

            nodes = Map.new(parsed, fn {id, n} -> {id, enrich_parsed(n, import_default)} end)

            # 导入覆盖拓扑，但保留图级别 drop 历史（drops 是 board 级，不随导入清空）。
            {:ok, %{count: map_size(nodes)},
             [
               commit(%{
                 nodes: nodes,
                 root_id: root_id,
                 seq: seq,
                 drops: Map.get(tree(ctx), :drops, [])
               })
             ]}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------
  # 出站连接器 handlers（df-tech 下沉）
  #
  # 实现体已搬到 `Ezagent.ActionSet.Kanban.Connectors`（压主模块 LOC）；这里只留
  # `action/3` 宏要求的 `handle_<action>/2` 薄转发（契约/宏不变）。授权 + effect
  # 契约见 Connectors moduledoc：节点级动作走 `Shared.owner_or_admin?`，图级动作 =
  # 任意持 cap 成员，凭证保存 admin-gated；树写入仍是全 Behavior 唯一的
  # `Shared.commit/1`（`tree set-effect（经 commit/1 收口）`）。
  # ---------------------------------------------------------------

  @doc false
  def handle_register_pr(args, ctx), do: Connectors.register_pr(args, ctx)

  @doc false
  def handle_attach_code_file(args, ctx), do: Connectors.attach_code_file(args, ctx)

  @doc false
  def handle_sync_miro(args, ctx), do: Connectors.sync_miro(args, ctx)

  @doc false
  def handle_set_board_config(args, ctx), do: Connectors.set_board_config(args, ctx)

  @doc false
  def handle_save_miro_creds(args, ctx), do: Connectors.save_miro_creds(args, ctx)

  # --- helpers --------------------------------------------------------

  defp empty_tree, do: Shared.empty_tree()

  defp new_node(parent_id, title, order, stage) do
    %{
      parent_id: parent_id,
      title: title,
      order: order,
      stage: stage,
      owner: nil,
      status: :unassigned,
      artifacts: [],
      metrics: []
    }
  end

  defp enrich_parsed(%{parent_id: p, title: t, order: o}, import_default_stage),
    do: new_node(p, t, o, import_default_stage)

  defp tree(ctx), do: Shared.tree(ctx)

  # 树写入唯一收口（`tree set-effect（经 commit/1 收口）` 字面在 `Shared.commit/1`，main + connectors 共用）。
  defp commit(tree), do: Shared.commit(tree)

  # 在一个节点上做带授权的更新；`fun.(node)` 返回新 node 或 `:invariant`。
  defp update_node(ctx, id, fun) do
    t = tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case fun.(t.nodes[id]) do
          :invariant -> {:error, :invariant}
          new_node -> {:ok, %{}, [commit(%{t | nodes: Map.put(t.nodes, id, new_node)})]}
        end
    end
  end

  # --- 授权（与 Connectors 共用 Shared 收口） -------------------------

  defp owner_or_admin?(ctx, node), do: Shared.owner_or_admin?(ctx, node)

  defp admin?(ctx), do: Shared.admin?(ctx)

  defp caller_str(ctx), do: Shared.caller_str(ctx)

  # --- 解析/归一 ------------------------------------------------------

  defp parse_enum(s, allowed) when is_binary(s) do
    a = String.to_existing_atom(s)
    if a in allowed, do: {:ok, a}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp parse_enum(a, allowed) when is_atom(a), do: if(a in allowed, do: {:ok, a}, else: :error)

  # artifact 归一（含 inline content 限长）与 Connectors 共用 `Shared.normalize_artifact/1`。
  defp normalize_artifact(a), do: Shared.normalize_artifact(a)

  defp normalize_metric(m) do
    %{
      name: sget(m, :name),
      target: sget(m, :target),
      current: sget(m, :current),
      unit: sget(m, :unit)
    }
  end

  # 兼容 atom / string 键（dispatch 边界过来的 map 可能是 string 键）。
  defp sget(m, k), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v), do: v

  defp descendant?(nodes, node_id, maybe_descendant),
    do: maybe_descendant == node_id or Enum.member?(ancestors(nodes, maybe_descendant), node_id)

  defp ancestors(nodes, id) do
    case nodes[id] do
      %{parent_id: nil} -> []
      %{parent_id: pid} -> [pid | ancestors(nodes, pid)]
      nil -> []
    end
  end

  defp subtree_ids(nodes, id) do
    children = for {cid, n} <- nodes, n.parent_id == id, do: cid
    [id | Enum.flat_map(children, fn cid -> subtree_ids(nodes, cid) end)]
  end
end
