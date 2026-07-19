defmodule EzagentPluginKanban.ShareReceive do
  @moduledoc """
  接收「分享的看板」的**业务归宿**(债③,X6 分享闭环的第一块)。

  历史上这段业务(接收者落点 session 解析 + `Mount.mount` 只读挂载 + kanban 字面
  `"kanban-assistant"`)住在 `EzagentWeb.Socialware.KanbanShareController` 里 ——
  P13 违反(Phoenix 是 transport 不是业务层)。现在 controller 瘦成:verify token
  (`Phoenix.Token` 属 web 层,留在 controller)→ 调本模块 → redirect;分享接收的
  业务整体归 kanban plugin(plugin 向下调 domain `Mount` 是允许的依赖箭头,
  见 mix.exs 注释)。

  ## 流程(`receive_shared_board/3`)

    1. token payload(已 verify)→ board URI + behavior(behavior 以字符串入 token,
       `Module.concat` 反解,同 `Mount.decode_behavior` 约定;已签名,安全);
    2. **落点 session 解析**:显式传入 `target_session` 用之;`nil` 沿用现口径 ——
       从点击者身份反推 workspace(`Ezagent.URI.workspace_of/1`),
       `EzagentDomainInstanceMessage.list_sessions/2`(点击者是成员的 session,
       按 URI 串排序取确定性首个)里挑**第一个带 `kanban-assistant` 成员**的 session;
    3. `Ezagent.Socialware.Mount.mount/6` 给该 session 的 kanban-assistant 挂
       `access: :read` 只读钥匙(`[:get_tree, :export_markmap]`)。授权只在**分享时**
       查(发起人有 access 才签得出 token),token 即凭证,接收侧只管挂;granter 仍 =
       板主人(`Mount` 内部用板主人权铸,#154 mint chokepoint 不变)。

  ## TODO(㉜,等 Allen D3/D1)——点击者的 `kanban_render` view cap 不在这里发

  fix-plan 曾计划接收时顺发 `{Session, :kanban_render}` render cap 给点击者
  (㉜ 过渡:点开的人见看板 tab)。实做时撞 I12 paradigm-lock 铁闸
  (cap_self_store_paradigm_lock_test / cap_check_only_at_chokepoint_test p6):
  grant 驱动点与 absorb 生产者是 shrink-only 锁定名单,**任何新文件加 grant 点都
  算 widen** —— 这正是 fix-plan X2 的病(「第 N 个 grant 点 = 第 N 个不同步的真相
  源」)、且视图 cap 补发属 join-补发 ambient rule 家族(#154 review 面,Allen D1/D3
  拍板后随 join hook 一并落)。故本模块只做挂载,tab 可见性留给 install /
  join-补发路补齐。

  ## 为什么走 `Mount.mount` 直挂而不是 `BoardProvision.forward_board/5`

  后者的 `assert_forward_access` 要求 caller 在 *from_session*(是来源群成员且群对板
  有 access),而接收场景点击者**不在** from_session —— 设计上授权在分享时已查,
  接收侧只管挂(与 controller 时代的口径一致)。
  """

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Socialware.Mount
  alias Ezagent.Socialware.SessionReads

  # kanban 业务字面(从 share controller 搬入,归位 plugin):收只读钥匙的「手」的
  # role 名 + 只读动作集(能看不能改,同 BoardProvision 转发只读集)。
  @assistant_role "kanban-assistant"
  @read_actions [:get_tree, :export_markmap]

  @type receive_result :: %{session_uri: URI.t(), assistant_uri: URI.t()}

  @doc """
  接收一块分享的板:落点解析 → 只读挂载。

    * `payload` —— 已 verify 的 token payload(`%{"board" => str, "behavior" => str}`)。
    * `clicker` —— 点击者(登录用户)的 entity URI。
    * `target_session` —— 显式落点 session;`nil` 沿用「首个带 kanban-assistant 的
      session」口径。

  返回 `{:ok, %{session_uri, assistant_uri}}` 或
  `{:error, :bad_board | :no_workspace | :no_session | :no_session_with_assistant
  | :no_assistant_in_session | term()}`。
  """
  @spec receive_shared_board(map(), URI.t(), URI.t() | nil) ::
          {:ok, receive_result()} | {:error, term()}
  def receive_shared_board(payload, clicker, target_session \\ nil)

  def receive_shared_board(
        %{"board" => board_str, "behavior" => behavior_str},
        %URI{} = clicker,
        target_session
      )
      when is_binary(board_str) and is_binary(behavior_str) do
    with {:ok, %URI{} = board_uri} <- parse_board(board_str),
         behavior = Module.concat([behavior_str]),
         {:ok, session_uri, assistant_uri} <- resolve_target(clicker, target_session),
         {:ok, _} <-
           Mount.mount(session_uri, board_uri, assistant_uri, behavior, @read_actions,
             access: :read
           ) do
      {:ok, %{session_uri: session_uri, assistant_uri: assistant_uri}}
    end
  end

  def receive_shared_board(_payload, _clicker, _target_session), do: {:error, :bad_token}

  defp parse_board(board_str) do
    case Ezagent.URI.parse(board_str) do
      {:ok, %URI{} = board_uri} -> {:ok, board_uri}
      _ -> {:error, :bad_board}
    end
  end

  # --- 落点 session 解析 ----------------------------------------------------

  # 显式落点:解析该 session 的 kanban-assistant(无 → :no_assistant_in_session;
  # clicker 非该 session 成员 → SessionReads fail-closed,同样归入该错误)。
  defp resolve_target(%URI{} = clicker, %URI{} = target_session) do
    case session_assistant(target_session, clicker) do
      {:ok, assistant_uri} -> {:ok, target_session, assistant_uri}
      {:error, _} = err -> err
    end
  end

  # nil 落点(现口径):发链接方不知道收方哪个 session,session 不由 URL 传,从接收者
  # 身份反推。步骤:
  #   1. `workspace_of(clicker)` 拿接收者 workspace(entity URI 首段即 workspace);
  #   2. `list_sessions(ws, clicker)`(同 `WorldLive` 首页取「当前/默认」session 的口径)
  #      → 接收者作为成员的 session 列表(按 URI 串排序,无 recency 信号);
  #   3. 逐个挑出**带 kanban-assistant 成员**的 session(收只读钥匙需要这只「手」),取首个。
  # 任何一步空 → 友好错误(web 侧映射为 404,非 500)。
  defp resolve_target(%URI{} = clicker, nil) do
    with %URI{scheme: "workspace"} = workspace_uri <- Ezagent.URI.workspace_of(clicker),
         [_ | _] = sessions <-
           EzagentDomainInstanceMessage.list_sessions(workspace_uri, clicker),
         {:ok, session_uri, assistant_uri} <- first_session_with_assistant(sessions, clicker) do
      {:ok, session_uri, assistant_uri}
    else
      %URI{} -> {:error, :no_workspace}
      :any -> {:error, :no_workspace}
      [] -> {:error, :no_session}
      {:error, _} = err -> err
      _ -> {:error, :no_session}
    end
  end

  # 逐个 session 读成员,返回首个持 kanban-assistant 成员的 {session, assistant}。
  defp first_session_with_assistant(sessions, %URI{} = clicker) do
    sessions
    |> Enum.find_value(fn %URI{} = session_uri ->
      case session_assistant(session_uri, clicker) do
        {:ok, assistant_uri} -> {:ok, session_uri, assistant_uri}
        _ -> nil
      end
    end)
    |> case do
      {:ok, _session, _assistant} = ok -> ok
      _ -> {:error, :no_session_with_assistant}
    end
  end

  # 读一次 session 成员 → 解析该 session 的 kanban-assistant(收只读钥匙的「手」)。
  # read-plane PR-1(main dbac4c666,Allen 在 controller 旧址做了同款迁移;债③搬家后
  # 落点在此):成员读走 `SessionReads.members` 授权闸(clicker 是这些 session 的成员
  # ——nil 落点路 `list_sessions/2` 已按成员过滤,授权必过;显式落点路非成员
  # fail-closed),不再直读 `:session` slice。
  defp session_assistant(%URI{} = session_uri, %URI{} = clicker) do
    with {:ok, members} <- SessionReads.members(clicker, session_uri),
         %URI{} = uri <- Members.role_name_to_uri(members, @assistant_role) do
      {:ok, uri}
    else
      _ -> {:error, :no_assistant_in_session}
    end
  end
end
