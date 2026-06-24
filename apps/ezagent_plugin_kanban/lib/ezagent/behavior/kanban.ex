defmodule Ezagent.Behavior.Kanban do
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
        stage:     :positioning|:metric|:pain|:anchor|:ux|:feature|:issue|:test|:pr,  # 9阶段固定链(非权限边界)
        owner:     user_uri | nil,                      # 认领人; 既问责又是权限闸
        status:    :unassigned|:claimed|:doing|:done,   # 粗4态(细状态归外部工具)
        artifacts: [%{tool,kind,ref,url}],              # 挂工具产物(github PR/飞书文档/xmind…)
        metrics:   [%{name,target,current,unit}]        # 挂指标(价值/运营节点)
      }

  ## 权限 = admin + 节点 owner（per-node，在 handler 内查；data_owner 是 per-instance）
  改一个节点 = `ctx.caller == node.owner` 或 caller 持 wildcard cap(admin)；未认领节点
  任意成员可 `claim`。**不变式**：`owner==nil ⟺ status==:unassigned`。
  """

  use Ezagent.Lifecycle

  alias EzagentPluginKanban.BoardConfig
  alias EzagentPluginKanban.Ci
  alias EzagentPluginKanban.Github
  alias EzagentPluginKanban.Markmap
  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.MiroSync

  # 产品自举开发流程的 9 个固定阶段（真相源接力链；顺序即 list 顺序，索引用于插入校验）。
  @stages [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr]
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
  # 出站连接器动作（df-tech 下沉：原在 world kanban_actions.ex，搬进 Behavior
  # 收口——world 退成纯 dispatcher，不再直引 EzagentPluginKanban.*）。
  # 出站 HTTP 副作用走 :effect_returning（绑结果回 dispatch 结果）；状态变更
  # （挂 artifact / set done）继续经唯一 commit/1。
  # ---------------------------------------------------------------

  action(:sync_github,
    args: %{id: :string},
    returns: %{number: :integer, url: :string},
    caps: [:sync_github],
    modes: [:call],
    description: "把节点出站成 GitHub issue + 回挂 issue 产物到节点"
  )

  action(:push_pr,
    args: %{id: :string},
    returns: %{url: :string},
    caps: [:push_pr],
    modes: [:call],
    description: "把产品需求摘要 post 到节点已登记的 PR（纯出站，不改树）"
  )

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

  action(:sync_prs,
    args: %{},
    returns: %{advanced: :integer},
    caps: [:sync_prs],
    modes: [:call],
    description: "轮询已登记 PR 的节点；merged/closed → set_status done"
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

  action(:save_github_creds,
    args: %{access_token: :string, repo: :string},
    returns: %{},
    caps: [:save_github_creds],
    modes: [:call],
    description: "保存全局 GitHub 凭证（admin-gated）"
  )

  action(:save_miro_creds,
    args: %{access_token: :string, board_id: :string},
    returns: %{},
    caps: [:save_miro_creds],
    modes: [:call],
    description: "保存全局 Miro 凭证（admin-gated）"
  )

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
          :sync_github,
          :push_pr,
          :register_pr,
          :attach_code_file,
          :sync_prs,
          :sync_miro,
          :set_board_config,
          :save_github_creds,
          :save_miro_creds
        ],
        into: %{},
        do: {a, Ezagent.Capability.cap(:kanban, __MODULE__, a)}
  end

  # data_owner 是 per-INSTANCE（实例级 cap 收口）。per-NODE 授权在 handler 内做。
  @doc false
  def data_owner(_), do: :no_owner

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

        # 根节点默认第一阶段 :positioning；子节点默认继承父阶段（插入校验在 set_stage 收口）。
        stage = if parent_id, do: nodes[parent_id].stage, else: :positioning
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
          stage_index(nodes[id].stage) < stage_index(nodes[new_parent_id].stage) ->
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

    case parse_enum(stage, @stages) do
      {:ok, s} ->
        cond do
          not Map.has_key?(t.nodes, id) ->
            {:error, :node_not_found}

          # R1 插入规则：阶段顺序固定，深入只能往后——节点 stage 必须 ≥ 父、≤ 每个子。
          # 例："issue 后不能插 feature" = feature(5) < issue(6)，做 issue 子节点时拒。
          not stage_fits?(t.nodes, id, s) ->
            {:error, {:stage_order_violation, stage}}

          true ->
            update_node(ctx, id, &%{&1 | stage: s})
        end

      :error ->
        {:error, {:invalid_stage, stage}}
    end
  end

  # 节点 stage 的链上索引（@stages 顺序即固定链；找不到当 0）。
  defp stage_index(s), do: Enum.find_index(@stages, &(&1 == s)) || 0

  # R1.1（07 固定接力链）：stage 是结构事实非自由属性，沿固定 9 棒链推进——
  # 根固定第一棒 :positioning；非根只能是"父棒"或"父棒+1"（不能跳棒、不能回退、不能乱设）；
  # 对称地，每个子只能是"本棒"或"本棒+1"。这把"随意改 stage"收死成相邻棒推进。
  defp stage_fits?(nodes, id, s) do
    node = nodes[id]
    si = stage_index(s)

    parent_ok =
      case node.parent_id do
        nil ->
          s == :positioning

        pid ->
          pi = stage_index(nodes[pid].stage)
          si == pi or si == pi + 1
      end

    children_ok =
      nodes
      |> Enum.filter(fn {_i, n} -> n.parent_id == id end)
      |> Enum.all?(fn {_i, c} ->
        ci = stage_index(c.stage)
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

    # drops = 图级别 drop 历史（全图属性，存在 tree 里，随 tree 一起读出）。
    # config/miro/github/ci = 出站连接器只读投影（df-tech 下沉：world 不再直读
    # BoardConfig/Miro/Github，全经此 dispatch 返回拿到）。
    {:ok,
     %{
       tree: inner,
       drops: Map.get(t, :drops, []),
       config: board_config(ctx),
       miro: miro_status(),
       github: github_status(),
       # pr 节点的 CI 评价摘要（前端 ci 徽章）：%{node_id => verdict}，纯函数算。
       ci: ci_summaries(inner)
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

  defp github_status do
    case Github.read_creds() do
      {:ok, %{token: t, repo: r}} when is_binary(t) and t != "" ->
        %{configured: true, repo: r}

      _ ->
        %{configured: false}
    end
  rescue
    _ -> %{configured: false}
  end

  # 给每个 stage==:pr 节点算 CI 评价（纯函数，无副作用）。前端 ci 徽章用。
  defp ci_summaries(%{nodes: nodes} = tree) do
    for {id, n} <- nodes, Map.get(n, :stage) == :pr, into: %{} do
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
            nodes = Map.new(parsed, fn {id, n} -> {id, enrich_parsed(n)} end)

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
  # 授权：节点级动作（sync_github/push_pr/register_pr/attach_code_file）沿用
  # `owner_or_admin?` 闸——同 attach_artifact 一样要节点 owner 或 admin。图级动作
  # （sync_prs/sync_miro/set_board_config）= 任意持 cap 的成员（cap gate 已收口）。
  # 凭证保存（save_*_creds）= admin-gated（全局配置）。
  # 出站 HTTP 副作用走 :effect_returning（绑结果，不算 set-effect 站点）；只有真改
  # 树（挂 artifact / set done）才 commit/1。
  # ---------------------------------------------------------------

  @doc false
  # 出站到 GitHub：建 issue + 回挂 issue 产物到节点（同节点 = 折进一次 commit，不自分发）。
  # 出站 HTTP 在 Kind 进程内同步调（对齐 UserTokens handler 内联 Token.list 的先例）——
  # 要拿结果决定是否 commit + 拼回返回值，纯 {:ref} 替换表达不了这层逻辑。
  def handle_sync_github(%{id: id}, ctx) do
    t = tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case board_creds(ctx) do
          {:ok, %{token: token, repo: repo}} when is_binary(repo) ->
            n = t.nodes[id]

            case Github.create_issue(token, repo, n.title || "(untitled)", github_issue_body(n)) do
              {:ok, %{number: num, url: url}} ->
                art =
                  normalize_artifact(%{tool: "github", kind: "issue", ref: "##{num}", url: url})

                new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
                {:ok, %{number: num, url: url}, [commit(%{t | nodes: new_nodes})]}

              {:error, reason} ->
                {:error, gh_reason(reason)}
            end

          {:ok, %{repo: nil}} ->
            {:error, :github_repo_missing}

          {:error, _} ->
            {:error, :github_token_missing}
        end
    end
  end

  @doc false
  # 出站 PR 留言：把产品需求摘要 post 到节点已登记的 PR（纯出站，不改树）。
  def handle_push_pr(%{id: id}, ctx) do
    t = tree(ctx)

    with node when is_map(node) <- Map.get(t.nodes, id),
         true <- owner_or_admin?(ctx, node) or :forbidden,
         {:ok, %{token: token, repo: repo}} when is_binary(repo) <- board_creds(ctx),
         pr when is_integer(pr) <- node_pr(node),
         digest <- Ci.requirement_digest(t, id),
         {:ok, url} <- Github.post_comment(token, repo, pr, digest) do
      {:ok, %{url: url}, []}
    else
      nil -> {:error, :node_not_found}
      :forbidden -> {:error, :forbidden}
      {:ok, %{repo: nil}} -> {:error, :github_repo_missing}
      {:error, :github_token_missing} -> {:error, :github_token_missing}
      {:error, reason} -> {:error, gh_reason(reason)}
      false -> {:error, :no_pr_registered}
      _ -> {:error, :no_pr_registered}
    end
  end

  @doc false
  # 登记 PR：把 PR 链接挂到节点（不发评论；出站留言在 push_pr）。
  def handle_register_pr(%{id: id, pr: pr_in}, ctx) do
    t = tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case {to_pr_number(pr_in), board_creds(ctx)} do
          {pr, {:ok, %{repo: repo}}} when is_integer(pr) and is_binary(repo) ->
            url = "https://github.com/#{repo}/pull/#{pr}"
            art = normalize_artifact(%{tool: "github", kind: "pr", ref: "##{pr}", url: url})
            n = t.nodes[id]
            new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
            {:ok, %{}, [commit(%{t | nodes: new_nodes})]}

          {:error, _} ->
            {:error, :bad_pr_number}

          {_, {:ok, %{repo: nil}}} ->
            {:error, :github_repo_missing}

          _ ->
            {:error, :github_token_missing}
        end
    end
  end

  @doc false
  # 挂代码文件：钉 commit SHA + 路径 → 拼 github blob 链接（永久可点）。repo 取本图配置。
  def handle_attach_code_file(%{id: id, sha: sha, path: path}, ctx)
      when is_binary(sha) and is_binary(path) do
    t = tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case board_creds(ctx) do
          {:ok, %{repo: repo}} when is_binary(repo) ->
            clean = String.trim_leading(path, "/")
            url = "https://github.com/#{repo}/blob/#{sha}/#{clean}"
            name = clean |> String.split("/") |> List.last()
            art = normalize_artifact(%{tool: "github", kind: "github_file", ref: name, url: url})
            n = t.nodes[id]
            new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
            {:ok, %{url: url}, [commit(%{t | nodes: new_nodes})]}

          {:ok, %{repo: nil}} ->
            {:error, :github_repo_missing}

          _ ->
            {:error, :github_token_missing}
        end
    end
  end

  @doc false
  # 轮询已登记 PR 的节点；merged/closed → set_status done（折进一次 commit）。
  def handle_sync_prs(_args, ctx) do
    t = tree(ctx)

    case board_creds(ctx) do
      {:ok, %{token: token, repo: repo}} when is_binary(repo) ->
        {new_nodes, advanced, unreachable?} = advance_merged_prs(t.nodes, token, repo)

        cond do
          unreachable? -> {:error, :github_unreachable}
          advanced == 0 -> {:ok, %{advanced: 0}, []}
          true -> {:ok, %{advanced: advanced}, [commit(%{t | nodes: new_nodes})]}
        end

      {:ok, %{repo: nil}} ->
        {:error, :github_repo_missing}

      _ ->
        {:error, :github_token_missing}
    end
  end

  # 遍历登记过 PR 的节点查状态；merged/closed 的 set status=done。返回 {新nodes,推进数,连不上?}。
  defp advance_merged_prs(nodes, token, repo) do
    Enum.reduce(nodes, {nodes, 0, false}, fn {id, node}, {acc_nodes, n, unreachable?} ->
      case node_pr(node) do
        nil ->
          {acc_nodes, n, unreachable?}

        pr ->
          case Github.get_pull(token, repo, pr) do
            {:ok, %{merged: true}} -> {done_node(acc_nodes, id), n + 1, unreachable?}
            {:ok, %{state: "closed"}} -> {done_node(acc_nodes, id), n + 1, unreachable?}
            {:error, {:http_error, _}} -> {acc_nodes, n, true}
            _ -> {acc_nodes, n, unreachable?}
          end
      end
    end)
  end

  defp done_node(nodes, id) do
    case nodes[id] do
      %{owner: o} = node when not is_nil(o) -> Map.put(nodes, id, %{node | status: :done})
      _ -> nodes
    end
  end

  @doc false
  # 一键推 Miro：已绑定则 sync；未绑定则建板+绑定+sync。板名取本图配置或默认。
  def handle_sync_miro(_args, ctx) do
    uri = ctx[:self_uri]

    miro_name =
      case BoardConfig.read(uri).miro_board do
        name when is_binary(name) and name != "" -> name
        _ -> "ezagent: " <> uri_name(uri)
      end

    case MiroSync.sync_or_bind(uri, miro_name) do
      {:ok, %{board_id: board}} -> {:ok, %{board_id: board}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # 写本图连接器配置（github_repo + miro 板名）。任意持 cap 的成员（cap gate 收口）。
  def handle_set_board_config(%{github_repo: github_repo, miro_board: miro_board}, ctx) do
    uri = ctx[:self_uri]

    case BoardConfig.write(uri, %{github_repo: github_repo, miro_board: miro_board}) do
      :ok ->
        c = BoardConfig.read(uri)
        {:ok, %{github_repo: c.github_repo, miro_board: c.miro_board}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # 保存全局 GitHub 凭证（admin-gated）。
  def handle_save_github_creds(%{access_token: token} = args, ctx) when is_binary(token) do
    if admin?(ctx) do
      case Github.write_creds(%{access_token: token, repo: Map.get(args, :repo, "")}) do
        :ok -> {:ok, %{}, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  # 保存全局 Miro 凭证（admin-gated）。
  def handle_save_miro_creds(%{access_token: token} = args, ctx) when is_binary(token) do
    if admin?(ctx) do
      case Miro.write_creds(%{access_token: token, board_id: Map.get(args, :board_id, "")}) do
        :ok -> {:ok, %{}, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  # --- 出站 helpers ---------------------------------------------------

  # 每图独立配置：token 取全局（github.yaml），repo 取本图配置。返回 {:ok,%{token,repo}}|{:error,_}。
  defp board_creds(ctx) do
    case Github.read_creds() do
      {:ok, %{token: token}} ->
        repo =
          case ctx[:self_uri] do
            %URI{} = uri -> BoardConfig.read(uri).github_repo
            _ -> nil
          end

        {:ok, %{token: token, repo: repo}}

      err ->
        err
    end
  end

  # 拼 github issue body：节点 stage/status + inline content 产物。
  defp github_issue_body(n) do
    content =
      (Map.get(n, :artifacts) || [])
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    "**stage**: #{n.stage} · **status**: #{n.status}\n\n" <>
      content <> "\n\n_由 ezagent kanban 节点出站_"
  end

  # 从节点 pr 产物里抠出 PR 号（"#42"→42）。artifacts 用 atom 键（已 normalize）。
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

  # kanban 实例 URI 的末段名（建 Miro 板默认名用）。
  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()
  defp uri_name(_), do: "kanban"

  # GitHub 失败 → 干净错误 atom（前端 dispatchError 映射成中文提示）。
  defp gh_reason({:http_status, code, _}) when code in [401, 403], do: :github_unauthorized
  defp gh_reason({:http_status, 404, _}), do: :github_not_found
  defp gh_reason({:http_status, code, _}), do: String.to_atom("github_http_#{code}")
  defp gh_reason({:http_error, _}), do: :github_unreachable
  defp gh_reason(other) when is_atom(other), do: other
  defp gh_reason(other), do: {:github_error, other}

  # --- helpers --------------------------------------------------------

  defp empty_tree, do: %{nodes: %{}, root_id: nil, seq: 0, drops: []}

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

  defp enrich_parsed(%{parent_id: p, title: t, order: o}),
    do: new_node(p, t, o, :feature)

  defp tree(ctx), do: ctx[:read].(:tree, empty_tree())

  # 全文唯一的 `{:set` 字面。tree 含 nodes/root_id/seq/drops(图级别 drop 历史)，全经此收敛。
  # put_new 归一化 drops——旧树/字面量缺 drops 时补 []，保证后续 `%{t | drops: ...}` 安全。
  defp commit(tree), do: {:set, :tree, Map.put_new(tree, :drops, [])}

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

  # --- 授权 -----------------------------------------------------------

  defp owner_or_admin?(ctx, node),
    do: admin?(ctx) or (node.owner != nil and node.owner == caller_str(ctx))

  defp admin?(ctx) do
    ctx
    |> Map.get(:caps, MapSet.new())
    |> Enum.any?(fn
      %Ezagent.Capability{kind: :any} -> true
      _ -> false
    end)
  end

  defp caller_str(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  # --- 解析/归一 ------------------------------------------------------

  defp parse_enum(s, allowed) when is_binary(s) do
    a = String.to_existing_atom(s)
    if a in allowed, do: {:ok, a}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp parse_enum(a, allowed) when is_atom(a), do: if(a in allowed, do: {:ok, a}, else: :error)

  # inline 内容上限——artifact 进节点快照(真相源)，CI 关键内容(Gherkin/spec)走 inline
  # 而非外部 ref(feishu 死链/权限墙)；设上限防快照膨胀。64KB 够装一般 excalidraw 线框 JSON
  # /Gherkin/spec 卡；不无限大是因为整棵树存成一个 blob，超大图走上传文件。
  @artifact_content_limit 65_536

  defp normalize_artifact(a) do
    %{
      tool: sget(a, :tool),
      kind: sget(a, :kind),
      ref: sget(a, :ref),
      url: sget(a, :url),
      content: cap_content(sget(a, :content))
    }
  end

  defp cap_content(c) when is_binary(c), do: String.slice(c, 0, @artifact_content_limit)
  defp cap_content(_), do: nil

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
