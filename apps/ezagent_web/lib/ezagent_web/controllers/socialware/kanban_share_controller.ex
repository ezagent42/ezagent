defmodule EzagentWeb.Socialware.KanbanShareController do
  @moduledoc """
  接收「分享的看板」链接(T6.4)的 **transport 落点** —— world 看板操作面
  `kanban.share_board`(`EzagentPluginKanban.WorldActions.share_link/2`)生成的只读分享
  链接指到这里。

  债③(2026-07-16):接收**业务**(落点 session 解析 + 只读挂载 + kanban 字面)已
  整体搬进 kanban plugin `EzagentPluginKanban.ShareReceive.receive_shared_board/3`
  (P13:Phoenix 是 transport 不是业务层)。本 controller 只剩 web 层职责:

    1. `Phoenix.Token.verify`(同 salt/max_age,`Phoenix.Token` 属 web 层留在这里)
       → 拿回签名 payload;verify 失败(过期/篡改)→ 403(fail-closed);
    2. 调 plugin `receive_shared_board(payload, clicker)`(落点解析 + `access: :read`
       只读挂载 + 顺发 render cap,业务契约见该模块文档);
    3. 成功 → 302 重定向到**接收者 session 的 world 会话页**
       (`/sessions?session=<www-form-encoded session_uri>`,`WorldLive` 的
       conversation 面)+ flash;接收者没有可挂的 session → 友好 404(非 500)。
  """
  use EzagentWeb, :controller

  # salt/max_age 必须与分享侧 `EzagentPluginKanban.WorldActions` 常量逐一对齐。
  @share_board_salt "world_kanban_share"
  # 7 天:与分享链接有效期一致(sign 不带 max_age,过期判定全在此 verify)。
  @share_board_max_age 604_800

  @doc """
  接收分享:verify 只读 token → 调 kanban plugin 的
  `ShareReceive.receive_shared_board/3`(落点解析 + 只读挂载)→ 重定向到落点 session
  的 world 会话页 + flash。token/篡改失败 → 403(fail-closed);无可挂 session →
  友好 404。
  """
  def claim(conn, %{"token" => token}) when is_binary(token) do
    clicker = conn.assigns.current_entity_uri

    with {:ok, payload} <- verify_token(conn, token),
         {:ok, %{session_uri: session_uri}} <-
           EzagentPluginKanban.ShareReceive.receive_shared_board(payload, clicker) do
      conn
      |> put_flash(:info, "看板已加入你的工作区（只读）。在会话页的「看板」标签查看。")
      |> redirect(to: "/sessions?session=" <> URI.encode_www_form(URI.to_string(session_uri)))
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  def claim(conn, _params), do: reject(conn, :missing_params)

  # --- token(web 层:Phoenix.Token 签名/校验) ----------------------------

  # verify → 签名 payload(board + behavior 字符串;反解归 plugin)。
  defp verify_token(conn, token) do
    case Phoenix.Token.verify(conn, @share_board_salt, token, max_age: @share_board_max_age) do
      {:ok, %{"board" => board_str, "behavior" => behavior_str} = payload}
      when is_binary(board_str) and is_binary(behavior_str) ->
        {:ok, payload}

      _ ->
        {:error, :bad_token}
    end
  end

  # --- responses ---------------------------------------------------------

  # token/篡改类 → 403(fail-closed);接收者侧「无可挂 session」类 → 友好 404(非 500,
  # 非 403:不是权限被拒,是接收者还没有能承接看板的 session)。
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
