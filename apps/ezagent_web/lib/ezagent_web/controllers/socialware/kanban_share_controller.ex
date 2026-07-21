defmodule EzagentWeb.Socialware.KanbanShareController do
  @moduledoc """
  接收「分享的看板」链接(T6.4)的 **transport 落点** —— world 看板操作面
  `kanban.share_board`(`EzagentPluginKanban.WorldActions.share_link/2`)生成的只读分享
  链接指到这里。

  ㊵ 人本位(2026-07-19)后本入口**降级为 deep-link 入口**:in-app 气泡点击走
  `world:dispatch kanban.receive_shared`(不整屏跳转);本 controller 服务**外部
  粘贴链接/浏览器直开**(out-of-app 无 socket)。职责保持 web 层三步:

    1. `Phoenix.Token.verify`(同 salt/max_age,`Phoenix.Token` 属 web 层留在这里)
       → 拿回签名 payload;verify 失败(过期/篡改)→ 403(fail-closed);
    2. 调 plugin `receive_shared_board(payload, clicker)`(人本位:只读钥匙发给
       **点击者本人**,person-scope 挂载,业务契约见该模块文档);
    3. 成功 → 302 重定向到 **kanban 独立页深链** `/plugins/kanban/<board>`
       (不再解析/跳转落点 session —— 人本位下没有落点 session)+ flash。
  """
  use EzagentWeb, :controller

  # salt/max_age 必须与分享侧 `EzagentPluginKanban.WorldActions` 常量逐一对齐。
  @share_board_salt "world_kanban_share"
  # 7 天:与分享链接有效期一致(sign 不带 max_age,过期判定全在此 verify)。
  @share_board_max_age 604_800

  @doc """
  接收分享:verify 只读 token → 调 kanban plugin 的
  `ShareReceive.receive_shared_board/2`(人本位只读挂载)→ 重定向到看板独立页
  深链 + flash。token/篡改失败与挂载失败 → 403(fail-closed)。
  """
  def claim(conn, %{"token" => token}) when is_binary(token) do
    clicker = conn.assigns.current_entity_uri

    with {:ok, payload} <- verify_token(conn, token),
         {:ok, %{board_uri: board_uri}} <-
           EzagentPluginKanban.ShareReceive.receive_shared_board(payload, clicker) do
      conn
      |> put_flash(:info, "看板已加入你的看板页（只读）。")
      |> redirect(to: "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(board_uri)))
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

  # token/篡改/挂载失败一律 403(fail-closed;人本位下不再有「无可挂 session」的
  # 404 家族——挂载不依赖任何 session)。
  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "share link rejected: #{reason_text(reason)}")
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
