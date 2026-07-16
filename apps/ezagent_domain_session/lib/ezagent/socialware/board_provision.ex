defmodule Ezagent.Socialware.BoardProvision do
  @moduledoc """
  运行时 kanban "建板 / 拉板 / 转发" 入口 —— **通用挂载 infra 的瘦 kanban 消费者**。

  挂载机制(发钥匙 + 落挂载表)全交给 `Ezagent.Socialware.Mount`;本模块只留 **kanban 策略**:
  谁能建 / 拉 / 转发的授权守卫、目标 session 的 assistant 解析、以及把 kanban 参数
  (behavior=`Ezagent.ActionSet.Kanban`、role="kanban-assistant"、只读动作)喂给 `Mount`。

    1. **建板**(`create_board/5`)—— 归属 = 触发建板的 owner。经 `Mount.provision/6`:
       `Workspace.create_agent`(cap-gated,`data_owner` = `owner_ctx` 的 caller,即板主人,#154)
       + 当场给本 session 的 assistant 挂 `access: :operate` 全动作钥匙。**建板是 cap-gated 的**
       (`{:workspace, create_agent}`),故 owner_ctx 的 caller 须持建 agent 的权(session owner /
       admin);assistant 自己通常无此权,由 owner 建、再挂给 assistant。
    2. **拉板**(`pull_board/4`)—— 只有板主人能;经 `Mount.mount/6` 挂 `access: :operate` 全动作。
    3. **转发**(`forward_board/5`)—— 群成员(在 from_session 且该 session 对板有 access)能;
       经 `Mount.mount/6` 挂 `access: :read` 只读动作。

  `Mount` 内部走唯一 mint chokepoint(granter 永远 = 板主人 #154)+ `MountRow` 落表(挂载现在
  有 durable SoT、session 重启存活)。`behavior` 由调用方传入(如 `Ezagent.ActionSet.Kanban`),
  本模块不静态依赖任何 plugin。

  ## 参数

    * `workspace_uri` —— 新板所属 workspace。
    * `session_uri` —— 触发建板的 session;assistant 从它的成员边解析。
    * `spec` —— `%{name, board_role, flavor, assistant_role, actions}`:
      `:name`(必填,新板实例名)、`:board_role`(必填,建板 recipe 名,如 `"kanban-manager"`)、
      `:flavor`(必填,如 `"native"`)、`:assistant_role`(必填,收钥匙的成员 role_name,如
      `"kanban-assistant"`)、`:actions`(选填,默认 `action_names(behavior)`)。
    * `behavior` —— 操作 cap 的 ActionSet 模块(如 `Ezagent.ActionSet.Kanban`)。
    * `owner_ctx` —— `%{caller, caps}`:建板者(= 板主人),须持 `create_agent` 权。

  返回 `{:ok, %{board_uri, assistant_uri, minted}}` 或 `{:error, reason}`。建板失败或 assistant
  解析不出(本 session 无该 role 成员)则不发钥匙、整体失败(fail-closed)。
  """

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Socialware.Mount

  @type result :: %{
          board_uri: URI.t(),
          assistant_uri: URI.t(),
          minted: [Ezagent.Capability.t()],
          creator_minted: [Ezagent.Capability.t()]
        }

  @doc """
  建板(归属 = `owner_ctx` 的 caller)+ 当场发两把钥匙:

    1. 本 session 的 `assistant_role` 成员挂指向新板的 `behavior` 操作钥匙
       (`access: :operate`,经 `Mount.provision/6` 建宿主 + 当场挂 + 落挂载表);
    2. **建板人自己**(`owner_ctx.caller` = 板主人)也挂一把同款全动作 operate 钥匙
       (分层债 ⑧:此前建板人只拿到 `Manage` cap —— 管 agent 生命周期,behavior 轴对不上
       `behavior` 的操作 required_caps,读写自己的板全 unauthorized。经 `Mount.mount/6`
       → `CompositionCaps.mint_cap/4` 唯一 mint chokepoint,granter = 板主人 =
       建板人自己,`Cap.issue` 走 `{:held_by, owner}` 自路径,per-grantee 签名)。

  见模块文档的参数/返回契约;返回增加 `:creator_minted`(发给建板人的钥匙)。
  """
  @spec create_board(URI.t(), URI.t(), map(), module(), map()) ::
          {:ok, result()} | {:error, term()}
  def create_board(%URI{} = workspace_uri, %URI{} = session_uri, spec, behavior, owner_ctx)
      when is_map(spec) and is_atom(behavior) and is_map(owner_ctx) do
    with {:ok, name} <- fetch(spec, :name),
         {:ok, board_role} <- fetch(spec, :board_role),
         {:ok, flavor} <- fetch(spec, :flavor),
         {:ok, assistant_role} <- fetch(spec, :assistant_role),
         {:ok, assistant_uri} <- resolve_assistant(session_uri, assistant_role),
         {:ok, %URI{} = creator_uri} <- fetch_creator(owner_ctx),
         # ⑥ 建板授权(过渡,skill-1 会诊 2026-07-16;rule 名进 Decision Log 待 Allen):
         # collab 模型要「任何编辑 session 成员」能建板(建板人=版主);普通成员全链无
         # create_agent 授点。走产品规则 rule-tag(照 :socialware_install_views 同款家族)
         # 铸一把**一次性** scoped create_agent cap,只并进本次 provision 的 dispatch ctx
         # (不 absorb 不落库)——`Workspace.create_agent` 仍是唯一创建门。规则边界:
         # ① caller 必须是本 session 成员(下方守卫);② 只造 recipe 声明 `passive: true`
         # 的 data-host——不给任意算力 agent 开口。
         :ok <- assert_creator_member(session_uri, creator_uri),
         :ok <- assert_passive_recipe(board_role),
         {:ok, provision_ctx} <- runtime_provision_ctx(workspace_uri, owner_ctx, creator_uri),
         actions = Map.get(spec, :actions) || Ezagent.ActionSet.action_names(behavior),
         provision_spec = %{
           name: name,
           flavor: flavor,
           role: board_role,
           actions: actions
         },
         {:ok, %{target: board_uri, caps: minted}} <-
           Mount.provision(
             session_uri,
             workspace_uri,
             provision_spec,
             assistant_uri,
             behavior,
             provision_ctx
           ),
         # ⑧ 发给建板人的钥匙:同一条 mount 路(mint + 落挂载表,session 重启可 reconcile)。
         {:ok, %{caps: creator_minted}} <-
           Mount.mount(session_uri, board_uri, creator_uri, behavior, actions, access: :operate) do
      {:ok,
       %{
         board_uri: board_uri,
         assistant_uri: assistant_uri,
         minted: minted,
         creator_minted: creator_minted
       }}
    end
  end

  defp fetch_creator(%{caller: %URI{} = caller}), do: {:ok, caller}
  defp fetch_creator(_owner_ctx), do: {:error, :board_creator_unresolved}

  # ⑥ 规则边界①:建板人必须是触发建板 session 的成员(复用转发守卫的成员边检查)。
  defp assert_creator_member(session_uri, %URI{} = creator_uri) do
    members =
      case Ezagent.Kind.get_slice(session_uri, :session) do
        {:ok, slice} when is_map(slice) -> Map.get(slice, :members, %{})
        _ -> %{}
      end

    if caller_member?(members, creator_uri),
      do: :ok,
      else: {:error, :creator_not_session_member}
  end

  # ⑥ 规则边界②:只造 **passive data-host**(数据宿主,不进聊天不占算力)。判定按
  # recipe 声明的 `passive: true`(RF-6 三闸的被动数据 actor,同 definition_agents 的
  # `passive_recipe?`),不按 flavor 字符串——语义在 recipe 不在 flavor。任意算力 recipe
  # (cc/cc-headless/py/codex 的脑)不走本规则——那是 orchestrator/权限持有者的事。
  defp assert_passive_recipe(board_role) do
    case Ezagent.Agent.RecipeRegistry.lookup(board_role) do
      {:ok, recipe} ->
        if Map.get(recipe, :passive, Map.get(recipe, "passive", false)) == true,
          do: :ok,
          else: {:error, {:recipe_not_passive, board_role}}

      _ ->
        {:error, {:board_recipe_unknown, board_role}}
    end
  end

  # ⑥ 一次性 provision authority:经 `Cap.issue` 唯一 chokepoint,tag =
  # `{:rule, :socialware_runtime_provision, creator}`(规则:「编辑 session 成员可在本
  # workspace 造 passive data-host」,configurer = 建板人 = granted_by 真实实体 #154)。
  # concrete instance + concrete action 过 `rule_cap_bounded?`。铸出的签名 artifact
  # **只并进本次 dispatch ctx**(transient,不 absorb 不落库)——建板人不留任何 durable
  # create_agent 权,下次建板重走本规则(含成员/flavor 守卫)。
  defp runtime_provision_ctx(%URI{} = workspace_uri, owner_ctx, %URI{} = creator_uri) do
    bare =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :create_agent,
        Ezagent.URI.instance(workspace_uri),
        workspace_uri
      )

    case Ezagent.Cap.issue(
           {:rule, :socialware_runtime_provision, creator_uri},
           creator_uri,
           bare
         ) do
      {:ok, artifact} ->
        caps =
          owner_ctx
          |> Map.get(:caps, MapSet.new())
          |> MapSet.new()
          |> MapSet.put(artifact)

        {:ok, Map.put(owner_ctx, :caps, caps)}

      {:error, reason} ->
        {:error, {:runtime_provision_authority, reason}}
    end
  end

  @default_assistant_role "kanban-assistant"
  # 只读动作:转发发的钥匙只含这些(能看不能改)。kanban 读动作 = get_tree / export_markmap。
  @default_read_actions [:get_tree, :export_markmap]

  @doc """
  拉板 —— 把一块**已存在**的板拉进 `target_session_uri`,给该 session 的 assistant 挂指向
  这块板的操作钥匙(`access: :operate`,数据跨 session 共享、板不进群、URI 寻址)。

  **拉板 = 只有板主人能做**。授权检查在 call-site(这里):`caller_ctx.caller` 必须是这块板
  的 `data_owner`(经 `CapabilityRegistry.data_owner_of/2`),否则 `{:error, :not_board_owner}`。
  这一步必须在本层做 —— `Mount.mount/6`(经 `CompositionCaps.mint_cap/4`)是用板主人权铸的、
  不自检触发者,所以"只有主人能拉别人拉不了"的守卫落在这里(发现按 cap 收敛只保证看不到,
  不保证拉不了)。

  步骤:① 授权(caller == 板主人)→ ② 拿 target session 的 `assistant_role` 成员 URI(照
  建板同款读成员边;target 无该成员 → `{:error, :no_assistant_in_target}`)→ ③ 经
  `Mount.mount/6`(`access: :operate`)挂**全部操作动作**(`Ezagent.ActionSet.action_names(behavior)`)
  的实例精确钥匙 + 落挂载表。

    * `board_uri` —— 已存在的板(数据宿主)。
    * `target_session_uri` —— 拉进的目标 session;assistant 从它的成员边解析。
    * `behavior` —— 操作 cap 的 ActionSet 模块(如 `Ezagent.ActionSet.Kanban`)。
    * `caller_ctx` —— `%{caller, ...}`:发起拉板者,须 == 板主人;可选 `:assistant_role`
      覆盖收钥匙成员的 role_name(默认 `"kanban-assistant"`)。

  返回 `{:ok, %{assistant_uri, minted}}` 或 `{:error, :not_board_owner | :no_assistant_in_target | term()}`。
  """
  @spec pull_board(URI.t(), URI.t(), module(), map()) ::
          {:ok, %{assistant_uri: URI.t(), minted: [Ezagent.Capability.t()]}} | {:error, term()}
  def pull_board(%URI{} = board_uri, %URI{} = target_session_uri, behavior, caller_ctx)
      when is_atom(behavior) and is_map(caller_ctx) do
    assistant_role = Map.get(caller_ctx, :assistant_role, @default_assistant_role)

    with :ok <- assert_board_owner(board_uri, behavior, caller_ctx),
         {:ok, assistant_uri} <- resolve_target_assistant(target_session_uri, assistant_role),
         actions = Ezagent.ActionSet.action_names(behavior),
         {:ok, %{caps: minted}} <-
           Mount.mount(
             target_session_uri,
             board_uri,
             assistant_uri,
             behavior,
             actions,
             access: :operate
           ) do
      {:ok, %{assistant_uri: assistant_uri, minted: minted}}
    end
  end

  @doc """
  转发只读 —— 群里**任何成员**能做:把一块板从 `from_session_uri` 转发给 `to_session_uri`,
  给 to_session 的 assistant 挂指向这块板的**只读**钥匙(默认 `[:get_tree, :export_markmap]`,
  `access: :read`),只能看不能改(数据跨 session 共享、板不进群、URI 寻址)。

  **对比拉板(`pull_board`)**:同一条 `Mount.mount/6`,只是 (1) 授权检查不同、(2) actions /
  access 不同。拉板只有板主人能、`access: :operate` 发全部操作动作;转发**任何在 from_session
  且 from_session 对板有 access 的成员**能、`access: :read` 发只读动作。granter 仍 = 板主人
  (读的还是他的数据,`Mount` 内部用板主人权铸),转发成员只是"传递了他的 access"。

  **授权检查(call-site,fail-closed)**:`caller_ctx.caller` 必须
    ① **在 from_session 里**(是 from_session 的成员),且
    ② **from_session 对这块板有 access** —— 即 from_session 的 `assistant_role` 成员持有一把
       指向这块板(instance 精确)的 `behavior` cap(这块板被 pull/create 进了 from_session)。
  任一不满足 → `{:error, :no_forward_access}`。此外 board、来源 session、目标 session
  必须属于同一 workspace；跨 workspace 在解析接收者和 mint/Mount 之前返回
  `{:error, :cross_workspace_denied}`(#1435;分享业务=同 workspace 跨会话)。
  **不要求 caller 是板主人**(那是拉板)。

    * `board_uri` —— 已存在的板(数据宿主)。
    * `from_session_uri` —— caller 所在、且对板有 access 的来源 session。
    * `to_session_uri` —— 收只读钥匙的目标 session;assistant 从它的成员边解析。
    * `behavior` —— 操作/读 cap 的 ActionSet 模块(如 `Ezagent.ActionSet.Kanban`)。
    * `caller_ctx` —— `%{caller, ...}`:发起转发者;可选 `:assistant_role` 覆盖两侧收/查钥匙成员
      的 role_name(默认 `"kanban-assistant"`)、`:read_actions` 覆盖只读动作集。

  返回 `{:ok, %{assistant_uri, minted}}` 或
  `{:error, :cross_workspace_denied | :no_forward_access | :no_assistant_in_target | term()}`。
  """
  @spec forward_board(URI.t(), URI.t(), URI.t(), module(), map()) ::
          {:ok, %{assistant_uri: URI.t(), minted: [Ezagent.Capability.t()]}} | {:error, term()}
  def forward_board(
        %URI{} = board_uri,
        %URI{} = from_session_uri,
        %URI{} = to_session_uri,
        behavior,
        caller_ctx
      )
      when is_atom(behavior) and is_map(caller_ctx) do
    assistant_role = Map.get(caller_ctx, :assistant_role, @default_assistant_role)
    read_actions = Map.get(caller_ctx, :read_actions, @default_read_actions)

    with :ok <- same_workspace(board_uri, from_session_uri, to_session_uri),
         :ok <-
           assert_forward_access(
             board_uri,
             from_session_uri,
             behavior,
             assistant_role,
             caller_ctx
           ),
         {:ok, assistant_uri} <- resolve_target_assistant(to_session_uri, assistant_role),
         {:ok, %{caps: minted}} <-
           Mount.mount(
             to_session_uri,
             board_uri,
             assistant_uri,
             behavior,
             read_actions,
             access: :read
           ) do
      {:ok, %{assistant_uri: assistant_uri, minted: minted}}
    end
  end

  # 分享业务 = 同 workspace 跨会话(#1435/⑯):board、来源、目标三方 workspace 必须一致,
  # 在解析接收者和 mint/Mount 之前 fail-closed。
  defp same_workspace(board_uri, from_session_uri, to_session_uri) do
    workspaces =
      [board_uri, from_session_uri, to_session_uri]
      |> Enum.map(&Ezagent.Capability.workspace_of/1)
      |> Enum.map(&URI.to_string/1)
      |> Enum.uniq()

    if length(workspaces) == 1, do: :ok, else: {:error, :cross_workspace_denied}
  end

  # 转发守卫:caller 必须 ① 在 from_session 里 ② from_session 的 assistant 持指向该板的 cap
  # (= from_session 对板有 access)。mint 内部用板主人权铸、不自检触发者,故这两道把关落这里。
  defp assert_forward_access(
         board_uri,
         from_session_uri,
         behavior,
         assistant_role,
         %{caller: %URI{} = caller}
       ) do
    members =
      case Ezagent.Kind.get_slice(from_session_uri, :session) do
        {:ok, slice} when is_map(slice) -> Map.get(slice, :members, %{})
        _ -> %{}
      end

    cond do
      not caller_member?(members, caller) ->
        {:error, :no_forward_access}

      true ->
        case Members.role_name_to_uri(members, assistant_role) do
          %URI{} = from_assistant ->
            if session_holds_board_cap?(from_assistant, behavior, board_uri),
              do: :ok,
              else: {:error, :no_forward_access}

          _ ->
            {:error, :no_forward_access}
        end
    end
  end

  defp assert_forward_access(_board_uri, _from, _behavior, _role, _ctx),
    do: {:error, :no_forward_access}

  # caller 是否 from_session 的成员(成员边 key = 成员 URI,normalize 后比 instance)。
  defp caller_member?(members, %URI{} = caller) do
    key = Ezagent.URI.stable_key(Ezagent.URI.instance(caller))

    Enum.any?(members, fn
      {%URI{} = uri, _meta} -> Ezagent.URI.stable_key(Ezagent.URI.instance(uri)) == key
      _ -> false
    end)
  end

  # from_session 的 assistant 对这块板是否有 access —— **不直读 cap 列表**(那会绕过 dispatch
  # chokepoint、把 cap 校验挪出许可路)。改让 assistant 以自身份对这块板 dispatch 一个只读动作
  # (`:get_tree`, mode `:call`),cap 校验落在 dispatch 许可路上:`{:ok, _}` = 有钥匙(有权),
  # 任何 `{:error, _}`(如 `:unauthorized`) = 没钥匙(无权)。严格 presenter 绑定要求把
  # assistant 自持的 born-signed artifacts 明确装入 envelope；无 stamp 的 ambient fallback
  # 已被删除。
  # 目标动作 URI 的 slice 由 behavior 自身派生(`behavior.state_slice/0`,如 Kanban → `:kanban`),
  # 不硬编码。
  defp session_holds_board_cap?(assistant_uri, behavior, board_uri) do
    target = Ezagent.URI.with_action(board_uri, behavior.state_slice(), :get_tree)

    caps = assistant_uri |> Ezagent.EntityCaps.load() |> MapSet.new()

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: assistant_uri, caps: caps, reply: {:caller_inbox, self()}},
           origin: :trusted_internal
         }) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # 拉板守卫:caller 必须是这块板的 data_owner(mint 内部不自检触发者,故这里把关)。
  defp assert_board_owner(board_uri, behavior, %{caller: %URI{} = caller}) do
    case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(board_uri)) do
      %URI{} = owner ->
        if URI.to_string(owner) == URI.to_string(caller),
          do: :ok,
          else: {:error, :not_board_owner}

      _ ->
        {:error, :not_board_owner}
    end
  end

  defp assert_board_owner(_board_uri, _behavior, _ctx), do: {:error, :not_board_owner}

  # target session 无该 role 成员 → 优雅报 :no_assistant_in_target(别硬凑)。
  defp resolve_target_assistant(session_uri, assistant_role) do
    case resolve_assistant(session_uri, assistant_role) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _} -> {:error, :no_assistant_in_target}
    end
  end

  # 本 session 的成员边(与 CompositionCaps.read_role_members 同源:`:session` 状态切片的
  # `:members` map,key = 成员 URI,meta 带 `:role_name`),`role_name == assistant_role` 即目标。
  defp resolve_assistant(session_uri, assistant_role) do
    members =
      case Ezagent.Kind.get_slice(session_uri, :session) do
        {:ok, slice} when is_map(slice) -> Map.get(slice, :members, %{})
        _ -> %{}
      end

    case Members.role_name_to_uri(members, assistant_role) do
      %URI{} = uri -> {:ok, uri}
      _ -> {:error, {:board_assistant_unresolved, session_uri, assistant_role}}
    end
  end

  defp fetch(spec, key) do
    case Map.get(spec, key) do
      nil -> {:error, {:board_spec_missing, key}}
      "" -> {:error, {:board_spec_missing, key}}
      v -> {:ok, v}
    end
  end
end
