defmodule EzagentPluginKanban.ShareReceive do
  @moduledoc """
  接收「分享的看板」的**业务归宿**(债③ + ㊵ 人本位重做)。

  ## ㊵ 人本位(2026-07-19)

  历史上这条链是「会话本位」:解析落点 session → 把只读钥匙发给该 session 的
  kanban-assistant(xy-review §1 复审判定为三层会话本位设计)。用户钉死的模型是
  **人本位**:分享 = 钥匙给点击者本人。据此重做:

    1. token payload(已 verify)→ board URI + behavior(behavior 以字符串入 token,
       `Module.concat` 反解,同 `Mount.decode_behavior` 约定;已签名,安全);
    2. **ws policy 单守卫**(`ws_policy/3`):D4 拍板 = 只读放开、operate 隔离。
       链接分享是 `:read`,默认放行(含跨 workspace);D4 若翻案只改这一处;
    3. `Ezagent.Socialware.Mount.mount_for_person/5` 给**点击者本人**挂
       `access: :read` 只读钥匙(`[:get_tree, :export_markmap]`),落 person-scope
       挂载行(无 session 轴;⑲ 删板撤钥匙走 cap-epoch `Ezagent.Cap.revoke_all_to/2`
       —— 指向板的所有 cap 含 person 行一次性验签失效,挂载表行随后 bookkeeping 删)。

  授权只在**分享时**查(发起人有 access 才签得出 token),token 即凭证,接收侧
  只管挂;granter 仍 = 板主人(`Mount` 内部用板主人权铸,#154 mint chokepoint
  不变)。**不发生 session 跳转**:板经点击者自己的钥匙进他的 kanban tab
  (`WorldData.session_boards/2` ws∪cap 派生枚举),读/写按点击者与板的关系在
  dispatch chokepoint 如实判(只读钥匙 → get_tree 成、写动作 :missing_cap)。

  ## 会话本位旧段整体删除(assistant 解析)

  `resolve_target` / `first_session_with_assistant` / `session_assistant` /
  `@assistant_role` 全删 —— 人本位下点击者本人的钥匙就够 tab 读板(world 读树以
  登录者身份 dispatch `get_tree`,不经 assistant)。assistant 钥匙只剩两个正当
  来源:`create_board`(⑳)与 `forward_board`(D4 lane)。

  **成员读红线(read-plane PR-1)**:本模块已无 session 成员读。若日后重新需要
  (如 ㉙ share_to_session 的目标会话成员判),必须走
  `Ezagent.Socialware.SessionReads`(授权门,fail-closed),**不得**退回
  `get_slice(:session)` 裸读 —— PR-5 全平面 gate 收紧后 CI 会红。
  """

  alias Ezagent.Socialware.Mount

  # kanban 只读动作集(能看不能改,同 BoardProvision 转发只读集)。
  @read_actions [:get_tree, :export_markmap]

  @type receive_result :: %{board_uri: URI.t(), grantee: URI.t()}

  @doc """
  接收一块分享的板(人本位):ws policy 守卫 → 给点击者本人只读挂载。

    * `payload` —— 已 verify 的 token payload(`%{"board" => str, "behavior" => str}`)。
    * `clicker` —— 点击者(登录用户)的 entity URI,即钥匙 grantee。

  返回 `{:ok, %{board_uri, grantee}}` 或
  `{:error, :bad_board | :bad_token | :cross_workspace_denied | term()}`。
  """
  @spec receive_shared_board(map(), URI.t()) :: {:ok, receive_result()} | {:error, term()}
  def receive_shared_board(payload, clicker)

  def receive_shared_board(
        %{"board" => board_str, "behavior" => behavior_str},
        %URI{} = clicker
      )
      when is_binary(board_str) and is_binary(behavior_str) do
    with {:ok, %URI{} = board_uri} <- parse_board(board_str),
         behavior = Module.concat([behavior_str]),
         :ok <- ws_policy(:read, clicker, board_uri),
         {:ok, _} <-
           Mount.mount_for_person(board_uri, clicker, behavior, @read_actions, access: :read) do
      {:ok, %{board_uri: board_uri, grantee: clicker}}
    end
  end

  def receive_shared_board(_payload, _clicker), do: {:error, :bad_token}

  defp parse_board(board_str) do
    case Ezagent.URI.parse(board_str) do
      {:ok, %URI{} = board_uri} -> {:ok, board_uri}
      _ -> {:error, :bad_board}
    end
  end

  @doc """
  跨 workspace 口径的**单守卫点**(D4,2026-07-19 拍板:只读放开 + operate 隔离)。

  链接分享的接收是 `:read` —— 放行(含跨 ws:token 已由有 access 的分享人签出,
  只读钥匙不泄写权)。`:operate` 升级(规则8 `request_edit`)保持 ws 隔离 ——
  跨 ws 的编辑权仍走 `forward_board` 的 `same_workspace` 硬守卫语义。
  D4 若翻案,只改本函数。
  """
  @spec ws_policy(:read | :operate, URI.t(), URI.t()) ::
          :ok | {:error, :cross_workspace_denied}
  def ws_policy(:read, %URI{}, %URI{}), do: :ok

  def ws_policy(:operate, %URI{} = grantee, %URI{} = board_uri) do
    grantee_ws = Ezagent.URI.workspace_of(grantee)
    board_ws = Ezagent.Capability.workspace_of(board_uri)

    if match?(%URI{}, grantee_ws) and match?(%URI{}, board_ws) and
         URI.to_string(grantee_ws) == URI.to_string(board_ws),
       do: :ok,
       else: {:error, :cross_workspace_denied}
  end
end
