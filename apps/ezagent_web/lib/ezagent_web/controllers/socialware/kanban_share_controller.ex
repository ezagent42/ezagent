defmodule EzagentWeb.Socialware.KanbanShareController do
  @moduledoc """
  接收「分享的看板」链接（T6.4）—— world 看板操作面 `kanban.share_board`
  （`Ezagent.World.KanbanActions.share_link/2`）生成的只读分享链接的落点。

  流程：登录用户（`RequireEntity` 保证 `current_entity_uri`）带 `token`（分享时
  `Phoenix.Token.sign` 签的 board + 只读意图）+ 自己的 `session_uri` 点进来：

    1. `Phoenix.Token.verify`（同 salt/max_age）→ 拿回 board_uri + behavior；verify 失败
       （过期/篡改）→ 403（fail-closed）。
    2. 解析点击者的 session，校验点击者是该 session 的成员（挂进「他自己的」session，
       防跨 session 塞板）。
    3. 解析该 session 的 `kanban-assistant` 成员（收只读钥匙的「手」）。
    4. `Ezagent.Socialware.Mount.mount/6` 直接挂 `access: :read` 的只读钥匙
       （`[:get_tree, :export_markmap]`）。

  **为什么走 `Mount.mount` 直挂而不是 `BoardProvision.forward_board/5`**：后者的
  `assert_forward_access` 要求 caller 在 *from_session*（是来源群成员且群对板有 access），
  而接收场景点击者**不在** from_session —— 设计上授权只在**分享时**查（发起人有 access
  才签得出 token），token 即凭证，接收侧只管挂。granter 仍 = 板主人（`Mount` 内部用板
  主人权铸），与 forward/pull 的 mint chokepoint 完全一致。

  成功 → 板进点击者 tab（挂载表有 `access="read"` 行），302 重定向到 world 看板详情页
  + flash 提示。
  """
  use EzagentWeb, :controller

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Socialware.Mount

  # salt/max_age 必须与分享侧 `Ezagent.World.KanbanActions` 常量逐一对齐。
  @share_board_salt "world_kanban_share"
  # 7 天：与分享链接有效期一致（sign 不带 max_age，过期判定全在此 verify）。
  @share_board_max_age 604_800
  # 只读动作：挂的钥匙只含这些（能看不能改），同 `BoardProvision` 转发只读集。
  @read_actions [:get_tree, :export_markmap]
  @assistant_role "kanban-assistant"

  @doc """
  接收分享：verify 只读 token → 校验点击者是自己 session 的成员 → 解析其 kanban-assistant
  → `Mount.mount` 只读挂进该 session → 重定向到看板详情页 + flash。任何环节失败 → 403。
  """
  def claim(conn, %{"token" => token, "session_uri" => session_str})
      when is_binary(token) and is_binary(session_str) do
    clicker = conn.assigns.current_entity_uri

    with {:ok, board_uri, behavior} <- verify_token(conn, token),
         {:ok, session_uri} <- parse_session(session_str),
         {:ok, assistant_uri} <- resolve_session_assistant(session_uri, clicker),
         {:ok, _} <-
           Mount.mount(session_uri, board_uri, assistant_uri, behavior, @read_actions,
             access: :read
           ) do
      conn
      |> put_flash(:info, "看板已加入你的工作区（只读）。")
      |> redirect(to: "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(board_uri)))
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

  defp parse_session(value) do
    case Ezagent.URI.parse(value) do
      {:ok, %URI{scheme: "session"} = uri} -> {:ok, uri}
      _ -> {:error, :bad_session}
    end
  end

  # 读一次 session 成员 → 校验点击者是成员（挂进「他自己的」session，防跨 session 塞板）
  # → 解析该 session 的 kanban-assistant（收只读钥匙的「手」）。成员读取内联于此、不抽成
  # 独立 `members_of` 函数——那会与 `CompositionCaps` 私有 `read_role_members` 撞 cross-file
  # 重复 gate（那是 #1376 的，Allen 处理，不在本 PR 碰）；此处是本控制器专用的一次性组合读。
  defp resolve_session_assistant(session_uri, %URI{} = clicker) do
    members =
      case Ezagent.Kind.get_slice(session_uri, :session) do
        {:ok, slice} when is_map(slice) -> Map.get(slice, :members, %{})
        _ -> %{}
      end

    cond do
      not member?(members, clicker) ->
        {:error, :not_session_member}

      true ->
        case Members.role_name_to_uri(members, @assistant_role) do
          %URI{} = uri -> {:ok, uri}
          _ -> {:error, :no_assistant_in_session}
        end
    end
  end

  # 成员边 key = 成员 URI（normalize 后比 instance），同 `BoardProvision.caller_member?`。
  defp member?(members, %URI{} = who) do
    key = Ezagent.URI.stable_key(Ezagent.URI.instance(who))

    Enum.any?(members, fn
      {%URI{} = uri, _meta} -> Ezagent.URI.stable_key(Ezagent.URI.instance(uri)) == key
      _ -> false
    end)
  end

  # --- responses ---------------------------------------------------------

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "share link rejected: #{reason}")
  end
end
