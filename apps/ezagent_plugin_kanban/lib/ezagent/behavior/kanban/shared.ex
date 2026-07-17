defmodule Ezagent.ActionSet.Kanban.Shared do
  @moduledoc """
  Kanban Behavior 的共享原语——`Ezagent.ActionSet.Kanban`（拓扑/认领/读写动作）与
  `Ezagent.ActionSet.Kanban.Connectors`（出站连接器动作）共用的小函数集。

  抽出来纯粹是为了让两个 handler 模块复用同一套读/写/授权/归一逻辑，**不引入新语义**：
  - 读：`tree/1`（经 `ctx[:read]`）；
  - 写：`commit/1`——**全 Behavior 唯一的 `tree set-effect（经 commit/1 收口）` 字面**（main + connectors
    所有树变更都经此收敛，守 moduledoc「所有写动作经唯一 commit/1」约定）；
  - 授权：`owner_or_admin?/2` / `admin?/1`（per-node owner 或 canonical admin）；
  - 归一：`normalize_artifact/1`（artifact 进节点快照前归一 + content 限长）。
  """

  alias Ezagent.Agent.RecipeRegistry

  # inline 内容上限——artifact 进节点快照(真相源)，CI 关键内容(Gherkin/spec)走 inline
  # 而非外部 ref(feishu 死链/权限墙)；设上限防快照膨胀。64KB 够装一般 excalidraw 线框 JSON
  # /Gherkin/spec 卡；不无限大是因为整棵树存成一个 blob，超大图走上传文件。
  @artifact_content_limit 65_536

  @doc "空树（nodes/root_id/seq/drops）。"
  def empty_tree, do: %{nodes: %{}, root_id: nil, seq: 0, drops: []}

  # ------------------------------------------------------------------
  # stage 链 = LAYER-2 DATA（taxonomy §4.1 de-bake）
  #
  # 具体 9 棒产品开发链 + CI/import 默认棒 = 业务语义，住在 `kanban-manager`
  # recipe 的 `config` 数据里（`EzagentPluginKanban.Application.kanban_manager_recipe/0`），
  # 本模块在运行时 read-through 经 `RecipeRegistry.lookup/1` 读回——Behavior 不硬编码
  # 任何具体棒名。两条路径：
  #
  #   * 生产：dispatch ctx 带 `:self_uri`（agent URI）→ `Agent.RecipeAttributes.fetch/1`
  #     （ETS 快径，spawn 时由 role_step 写入）拿 role 名 → `RecipeRegistry.lookup/1`
  #     拿 `%Recipe{config: %{stages: [...], ci_stage:, import_default_stage:}}`。
  #   * 测试：单元测试用桩 ctx 直接注入 `:stages` / `:import_default_stage` /
  #     `:ci_stage`（绕过 recipe/DB，仍是"数据"——测试夹具数据，非代码硬编码）。
  #
  # 无 recipe / 无注入时退 `[]`：退化成"无固定链"的通用看板（stage 自由、不校验
  # 顺序），保持 Behavior 机制通用。kanban-manager recipe 始终带 9 棒，故生产行为不变。
  # ------------------------------------------------------------------

  @doc """
  本 kanban 实例的接力棒链（atom list），来自 recipe `config.stages` 数据。
  无 recipe / 无注入时返回 `[]`（通用无链模式）。
  """
  @spec stages(map()) :: [atom()]
  def stages(ctx) do
    case ctx[:stages] do
      [_ | _] = stages -> normalize_stages(stages)
      _ -> stages_from_recipe(ctx)
    end
  end

  @doc """
  从 recipe `config` 取一个业务配置值（`:ci_stage` / `:import_default_stage` 等），
  atom/string 键兼容；找不到回 `default`。优先 ctx 注入（测试），次选 recipe 数据。
  """
  @spec config_get(map(), atom(), term()) :: term()
  def config_get(ctx, key, default) do
    # ctx 直注（测试夹具）优先：原子键或字符串键。
    case sget(ctx, key) do
      nil ->
        case recipe_config(ctx) do
          nil -> default
          %{} = config -> sget(config, key) || default
        end

      v ->
        v
    end
  end

  @doc """
  同 `config_get/3`，但把值归一成现有 atom（棒名经 ConfigStore JSON 往返后是字符串，
  而节点 `stage` 是 atom——不归一会导致 `:pr == "pr"` 失配，CI 永不命中）。
  未知字符串保留为字符串（下游比对自然失败，fail-safe）。
  """
  @spec config_atom(map(), atom(), atom()) :: atom()
  def config_atom(ctx, key, default) do
    case config_get(ctx, key, default) do
      a when is_atom(a) -> a
      s when is_binary(s) -> to_existing_atom(s, default)
      other -> other
    end
  end

  defp to_existing_atom(s, default) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> default
  end

  # recipe 的 config map（read-through over RecipeRegistry），或 nil。
  # 仅在有 `:self_uri` 且能解析 role 名时查；否则 nil（让 ctx 直注 / default 兜底）。
  defp recipe_config(ctx) do
    with %URI{} = uri <- ctx[:self_uri],
         {:ok, role_name} <- role_of(uri),
         {:ok, recipe} <- RecipeRegistry.lookup(role_name) do
      Map.get(recipe, :config)
    else
      _ -> nil
    end
  end

  # 棒链优先从 recipe `config.stages` 取；无则退 []。
  defp stages_from_recipe(ctx) do
    case recipe_config(ctx) do
      %{} = config ->
        case sget(config, :stages) do
          [_ | _] = stages -> normalize_stages(stages)
          _ -> []
        end

      _ ->
        []
    end
  end

  # role 名：ETS 快径（spawn 时 role_step.grant_recipe_marker 写入）→ durable 快照兜底。
  # 两者都无（无 self_uri / 未起活）→ :none，调用方退 default。
  defp role_of(%URI{} = uri) do
    case Ezagent.Agent.RecipeAttributes.fetch(uri) do
      {:ok, role_name} -> {:ok, role_name}
      :none -> Ezagent.Agent.RecipeResolver.recipe_from_durable_snapshot(uri)
    end
  end

  # config 经 JSON 往返后棒名是字符串；统一转成现有 atom（不增长 atom 表）。
  # atom 直通；未知字符串保留为字符串（parse_enum 的 String.to_existing_atom 会拒）。
  defp normalize_stages(stages) do
    Enum.map(stages, fn
      a when is_atom(a) -> a
      s when is_binary(s) -> String.to_existing_atom(s)
      other -> other
    end)
  rescue
    ArgumentError -> stages
  end

  @doc "经 `ctx[:read]` 读当前树（缺省空树）。"
  def tree(ctx), do: ctx[:read].(:tree, empty_tree())

  @doc """
  全 Behavior 唯一的 `{:set` 字面。tree 含 nodes/root_id/seq/drops(图级别 drop 历史)，
  全经此收敛。put_new 归一化 drops——旧树/字面量缺 drops 时补 []，保证后续
  `%{t | drops: ...}` 安全。
  """
  def commit(tree), do: {:set, :tree, Map.put_new(tree, :drops, [])}

  @doc "节点级授权：caller 是 canonical admin，或 node.owner == caller。"
  def owner_or_admin?(ctx, node),
    do: admin?(ctx) or (node.owner != nil and node.owner == caller_str(ctx))

  @doc "已认证 presenter 是否为唯一 canonical admin root。"
  def admin?(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = caller ->
        Ezagent.URI.stable_key(caller) ==
          Ezagent.URI.stable_key(Ezagent.Entity.User.admin_uri())

      _ ->
        false
    end
  end

  @doc "caller URI 的字符串形式（per-node owner 比对用）。"
  def caller_str(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  @doc "归一一个 artifact（atom/string 键兼容；content 限长）。"
  def normalize_artifact(a) do
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

  # 兼容 atom / string 键（dispatch 边界过来的 map 可能是 string 键）。
  defp sget(m, k), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))
end
