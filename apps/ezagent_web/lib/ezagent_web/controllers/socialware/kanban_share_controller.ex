defmodule EzagentWeb.Socialware.KanbanShareController do
  @moduledoc """
  接收「分享的看板」链接（T6.4）—— world 看板操作面 `kanban.share_board`
  （`Ezagent.World.KanbanActions.share_link/2`）生成的只读分享链接的落点。

  流程：登录用户（`RequireEntity` 保证 `current_entity_uri`）**只带 `token`**（分享时
  `Phoenix.Token.sign` 签的 board + 只读意图）点进来：

    1. `Phoenix.Token.verify`（同 salt/max_age）→ 拿回 board_uri + behavior；verify 失败
       （过期/篡改）→ 403（fail-closed）。
    2. **服务端解析接收者自己的目标 session**：发链接方不知道收方哪个 session，故
       `session_uri` 不该塞在 URL 里。这里从 `conn.assigns.current_entity_uri` 反推
       接收者的 workspace（`Ezagent.URI.workspace_of/1`），用世界首页/sessions 列表同一
       条 `EzagentDomainInstanceMessage.list_sessions/2`（返回「该用户是成员」的 session）
       挑出**第一个带 `kanban-assistant` 成员的 session** 作为落点（同 `WorldLive` 用
       `List.first/1` 取「当前/默认」session 的口径；列表按 URI 串排序、无 recency 信号，
       故取确定性首个）。接收者没有可挂的 session → 友好错误（非 500）。
    3. 解析该 session 的 `kanban-assistant` 成员（收只读钥匙的「手」）。
    4. `Ezagent.Socialware.Mount.mount/6` 直接挂 `access: :read` 的只读钥匙
       （`[:get_tree, :export_markmap]`）。

  **为什么走 `Mount.mount` 直挂而不是 `BoardProvision.forward_board/5`**：后者的
  `assert_forward_access` 要求 caller 在 *from_session*（是来源群成员且群对板有 access），
  而接收场景点击者**不在** from_session —— 设计上授权只在**分享时**查（发起人有 access
  才签得出 token），token 即凭证，接收侧只管挂。granter 仍 = 板主人（`Mount` 内部用板
  主人权铸），与 forward/pull 的 mint chokepoint 完全一致。

  成功 → 板进点击者 session 的挂载表（`access="read"` 行），302 重定向到**接收者 session
  的 world 会话页**（`/sessions?session=<www-form-encoded session_uri>`，`WorldLive` 的
  conversation 面）—— 板真正出现的地方（看板 tab 在该页 tab 栏，客户端 `session.view.switch`
  切换，URL 无 view 深链），而不是 T6.3 缩成 Miro 配置面的 `/plugins/kanban/<board>`。
  """
  use EzagentWeb, :controller

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Socialware.Mount
  alias Ezagent.Socialware.SessionReads

  # salt/max_age 必须与分享侧 `Ezagent.World.KanbanActions` 常量逐一对齐。
  @share_board_salt "world_kanban_share"
  # 7 天：与分享链接有效期一致（sign 不带 max_age，过期判定全在此 verify）。
  @share_board_max_age 604_800
  # 只读动作：挂的钥匙只含这些（能看不能改），同 `BoardProvision` 转发只读集。
  @read_actions [:get_tree, :export_markmap]
  @assistant_role "kanban-assistant"

  @doc """
  接收分享：verify 只读 token → 服务端解析接收者的目标 session（带 kanban-assistant）
  → 解析其 kanban-assistant → `Mount.mount` 只读挂进该 session → 重定向到该 session 的
  world 会话页 + flash。token/篡改失败 → 403（fail-closed）；无可挂 session → 友好 404。
  """
  def claim(conn, %{"token" => token}) when is_binary(token) do
    clicker = conn.assigns.current_entity_uri

    with {:ok, board_uri, behavior} <- verify_token(conn, token),
         {:ok, session_uri, assistant_uri} <- resolve_target_session(clicker),
         {:ok, _} <-
           Mount.mount(session_uri, board_uri, assistant_uri, behavior, @read_actions,
             access: :read
           ) do
      conn
      |> put_flash(:info, "看板已加入你的工作区（只读）。在会话页的「看板」标签查看。")
      |> redirect(to: "/sessions?session=" <> URI.encode_www_form(URI.to_string(session_uri)))
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  def claim(conn, _params), do: reject(conn, :missing_params)

  # --- token -------------------------------------------------------------

  # verify → 拿回 board_uri + behavior（module）。behavior 以字符串入 token（分享侧 world
  # 无 kanban dep），`Module.concat` 反解（同 `Mount.decode_behavior` 约定；已签名，安全）。
  defp verify_token(conn, token) do
    case Phoenix.Token.verify(conn, @share_board_salt, token, max_age: @share_board_max_age) do
      {:ok, %{"board" => board_str, "behavior" => behavior_str}}
      when is_binary(board_str) and is_binary(behavior_str) ->
        case Ezagent.URI.parse(board_str) do
          {:ok, %URI{} = board_uri} -> {:ok, board_uri, Module.concat([behavior_str])}
          _ -> {:error, :bad_board}
        end

      _ ->
        {:error, :bad_token}
    end
  end

  # --- session / member / assistant --------------------------------------

  # 服务端解析接收者的落点 session：发链接方不知道收方哪个 session，故 session 不由 URL 传，
  # 而是从接收者身份反推。步骤：
  #   1. `workspace_of(clicker)` 拿接收者 workspace（entity URI 首段即 workspace）。
  #   2. `list_sessions(ws, clicker)`（同 `WorldLive` 首页取「当前/默认」session 的口径）
  #      → 接收者作为成员的 session 列表（按 URI 串排序，无 recency 信号）。
  #   3. 逐个挑出**带 kanban-assistant 成员**的 session（收只读钥匙需要这只「手」）；取首个。
  # 任何一步空 → 友好错误（`reject/2` 映射为 404，非 500）。
  defp resolve_target_session(%URI{} = clicker) do
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

  # 逐个 session 读成员，返回首个持 kanban-assistant 成员的 {session, assistant}。
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

  # 读一次 session 成员 → 解析该 session 的 kanban-assistant（收只读钥匙的「手」）。成员读取
  # 走 `SessionReads.members` 授权闸（clicker 是这些 session 的成员——`list_sessions/2`
  # 已按成员过滤，故授权必过；非成员会 fail-closed），不再直读 `:session` slice。
  defp session_assistant(%URI{} = session_uri, %URI{} = clicker) do
    with {:ok, members} <- SessionReads.members(clicker, session_uri),
         %URI{} = uri <- Members.role_name_to_uri(members, @assistant_role) do
      {:ok, uri}
    else
      _ -> {:error, :no_assistant_in_session}
    end
  end

  # --- responses ---------------------------------------------------------

  # token/篡改类 → 403（fail-closed）；接收者侧「无可挂 session」类 → 友好 404（非 500，
  # 非 403：不是权限被拒，是接收者还没有能承接看板的 session）。
  @no_session_reasons [:no_workspace, :no_session, :no_session_with_assistant]

  defp reject(conn, reason) when reason in @no_session_reasons do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, no_session_message(reason))
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "share link rejected: #{reason}")
  end

  defp no_session_message(_reason),
    do:
      "无法接收看板：你当前还没有可承接看板的会话（需要一个带 kanban-assistant 的会话）。" <>
        "请先在世界里创建/进入这样一个会话，再点分享链接。"
end
