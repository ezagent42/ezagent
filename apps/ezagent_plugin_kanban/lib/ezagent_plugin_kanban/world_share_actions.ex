defmodule EzagentPluginKanban.WorldShareActions do
  @moduledoc """
  看板**分享面**业务逻辑(T6.4 分享链接 / ㊵ 人本位接收 / ㉙ share_to_session /
  规则8 request_edit·approve_edit)——2026-07-20 从 `EzagentPluginKanban.WorldActions`
  拆出(`oversized_modules_gt_1000` arch gate:分享二期把 WorldActions 顶过 1000 行,
  按「拆模块不放宽基线」的规矩把内聚的分享面独立成模块)。

  分工:`WorldActions` 保持瘦 dispatcher——`handle_dispatch` 子句 + `{:noreply, socket}`
  状态包装 + `materialize_op` 操作留痕在那边;本模块承载分享面的**业务结果**
  (`{:ok, _} | {:error, reason}`,公开供测试)与 ㊵ 接收路的 socket 状态推送。

  token salt / max_age / behavior 字符串常量与接收侧
  `EzagentWeb.Socialware.KanbanShareController` 逐一对齐(改动必须两侧同步)。
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.Invocation
  alias EzagentPluginKanban.WorldActions
  alias EzagentPluginKanban.WorldData

  # 分享看板 token(T6.4):照 WorldActions upload-grant 的 Phoenix.Token 模式(sign/verify +
  # salt + max_age)。分享时校验发起人 access → 把 board + 只读意图签进 token → 拼接收链接;
  # 接收侧(ezagent_web `KanbanShareController`)用同 salt/max_age verify + 经
  # `ShareReceive.receive_shared_board/2` 给点击者本人铸只读钥匙(mint_cap)。
  # salt/max_age 必须与接收侧常量逐一对齐;max_age(7 天)在接收侧 verify 时校验。
  @share_board_salt "world_kanban_share"
  # 7 天:与 web 深链入口(KanbanShareController)verify 口径逐一对齐。
  @share_board_max_age 604_800
  # behavior 以字符串入 token(token payload 是 JSON-safe 字符串契约;接收侧
  # `Module.concat` 反解)。
  @share_board_behavior "Ezagent.ActionSet.Kanban"
  @share_board_receive_path "/socialware/kanban/receive"

  # --- 分享看板(T6.4):校验 access → 签只读 token → 拼接收链接 -----------------

  @doc """
  分享看板 = 生成一个只读接收链接。

  ① 校验发起人对这块板有 access —— 复用 world 的发现可见性谓词(`WorldData.can_share?`:
     admin / 板主人 data_owner / 持指向该板的 cap);
  ② `Phoenix.Token.sign` 把 board_uri + behavior + 只读意图签成 token(照 WorldActions
     upload-grant 的 sign/verify + salt + max_age 模式);
  ③ 拼成接收链接(接收 route 见 `EzagentWeb.Socialware.KanbanShareController`)。

  授权只在**分享时**查(token 携带凭证),接收侧只管挂。返回 `{:ok, link}`(发起人有
  access)或 `{:error, :no_access | :bad_kanban_uri}`。
  """
  @spec share_link(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, String.t()} | {:error, :no_access | :bad_kanban_uri}
  def share_link(socket, uri_str) do
    case parse(uri_str) do
      %URI{} = uri ->
        if share_access?(socket, uri),
          do: {:ok, build_share_link(socket, uri)},
          else: {:error, :no_access}

      :error ->
        {:error, :bad_kanban_uri}
    end
  end

  # 发起人对板是否有 access:复用 world 的发现可见性谓词(admin / 板主人 data_owner / 持指向
  # 该板的 cap)—— 能看见即可分享。**不**用 dispatch 探针:kanban 板动作的 cap 由 session 的
  # kanban-assistant(agent)持有,登录者(人)自身通常不持板动作 cap(他是 data_owner),
  # 故以「登录者 own / 持 cap」判 access(同 `WorldData.visible?` 的发现口径)。
  defp share_access?(socket, %URI{} = uri) do
    WorldData.can_share?(uri, WorldActions.read_ctx(socket))
  end

  defp build_share_link(socket, %URI{} = uri) do
    # token payload 的 board 串 hoist 到具名变量(不内联 `URI.to_string` 进 map)——
    # 同 uri_query serialization-boundary gate 的审计约定(URI reorder 时同步复核)。
    board_str = URI.to_string(uri)

    payload = %{
      "board" => board_str,
      "behavior" => @share_board_behavior,
      "access" => "read"
    }

    # max_age 在接收侧 `Phoenix.Token.verify` 时校验(sign 不带 max_age)。
    token = Phoenix.Token.sign(socket, @share_board_salt, payload)
    @share_board_receive_path <> "?" <> URI.encode_query(token: token)
  end

  # --- ㊵ 人本位接收(in-app 路;out-of-app 深链归 KanbanShareController) -----
  #
  # 气泡点击不再 `<a href>` 整屏跳:同 salt/max_age verify token → 调 plugin
  # `ShareReceive.receive_shared_board/2`(person-scope 只读挂载,业务契约见该模块)
  # → **caps assign 刷新**(新钥匙不经页面重载,不刷则 cap 派生枚举/后续 dispatch
  # 都看不见)→ 推 `active_view=kanban_board` + 刷新板集合,前端原地切 tab。
  @doc "㊵ in-app 接收分享:verify token → person-scope 只读挂载 → 刷 caps + 原地切 tab。"
  @spec receive_shared(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def receive_shared(socket, token) do
    clicker = socket.assigns.current_entity_uri

    with {:ok, payload} <- verify_share_token(socket, token),
         {:ok, %{board_uri: board_uri}} <-
           EzagentPluginKanban.ShareReceive.receive_shared_board(payload, clicker) do
      ctx = WorldActions.read_ctx(socket)

      instances =
        case socket.assigns[:current_session_uri] do
          %URI{} = session_uri -> WorldData.session_boards(session_uri, ctx)
          _ -> WorldData.list_instances(ctx)
        end

      state =
        board_uri
        |> WorldData.board_state(ctx)
        |> Map.merge(%{
          "active_view" => "kanban_board",
          "instances" => instances,
          "last_dispatch_status" => "ok"
        })

      {:noreply,
       socket
       |> assign(:last_dispatch_status, "ok")
       |> push_event("world:state", state)}
    else
      {:error, why} ->
        {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(why)}")}
    end
  end

  defp verify_share_token(socket, token) do
    case Phoenix.Token.verify(socket, @share_board_salt, token, max_age: @share_board_max_age) do
      {:ok, %{"board" => b, "behavior" => bh} = payload} when is_binary(b) and is_binary(bh) ->
        {:ok, payload}

      _ ->
        {:error, :bad_token}
    end
  end

  # --- ㉙ 分享二期:share_to_session ----------------------------------------
  #
  # 把板分享进 `session_uri`(缺省当前会话):分享侧 access gate(能看见即可分享,
  # 同 share_link)→ 以分享人身份物化一条**带接收链接**的分享消息进目标会话
  # (`hops: 0`:存完即 :hop_exhausted,零路由 fan-out,不惊动 assistant/relay;
  # 可见性 external_visible——气泡要给会话成员看见;操作留痕另经 materialize_op
  # 的 `visibility: :internal, hops: 0` 内部消息,两条契约并行)。
  # 错误全走同步 :call 返回 → `last_dispatch_status`(DISPATCH_ERR 字典),
  # **零散文错误物化**;若日后改异步物化,失败必须走
  # `Ezagent.Agent.ErrorSignal.reply_body/1` 结构化通道(bootstrap④ 约束)。
  @doc """
  ㉙ 分享到会话的业务结果(公开供测试):access gate → 目标会话解析 →
  物化分享消息(`hops: 0`)。返回 `{:ok, session_uri}` 或
  `{:error, :no_access | :bad_kanban_uri | :no_session_context | term()}`。
  """
  @spec share_to_session_result(Phoenix.LiveView.Socket.t(), String.t(), String.t() | nil) ::
          {:ok, URI.t()} | {:error, term()}
  def share_to_session_result(socket, uri_str, session_str) do
    with %URI{} = board_uri <- parse(uri_str),
         :ok <- access_check(socket, board_uri),
         {:ok, %URI{scheme: "session"} = session_uri} <- target_session(socket, session_str),
         link = build_share_link(socket, board_uri),
         text = "【看板分享】看板「#{uri_label(board_uri)}」 #{link}",
         :ok <- send_session_message(socket, session_uri, text) do
      {:ok, session_uri}
    else
      :error -> {:error, :bad_kanban_uri}
      {:error, _} = err -> err
    end
  end

  # --- 规则8:request_edit / approve_edit ------------------------------------
  #
  # 申请编辑 = 已持只读钥匙的人往当前会话物化一条申请气泡(带 request-edit 标记
  # 链接,unfurl 渲成「批准」按钮);板主人点批准 → `approve_edit` 复查
  # caller==data_owner + **D4 不变量 3:升级点复查同 ws**(operate 钥匙永不跨 ws,
  # 升级不是绕过不变量的后门)+ 申请人已持只读钥匙 → `CompositionCaps.mint_cap`
  # 铸全动作钥匙(升级 = 在已持读钥匙之上补齐写动作 cap,不落挂载表)。
  @request_edit_path "/plugins/kanban/request-edit"

  @doc """
  规则8 申请编辑(公开供测试):caller 对板有 access(持钥可读)且非板主人 →
  往当前会话物化申请气泡。返回 `{:ok, session_uri}` 或
  `{:error, :bad_kanban_uri | :no_access | :already_owner | :no_session_context | term()}`。
  """
  @spec request_edit_result(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def request_edit_result(socket, uri_str) do
    caller = socket.assigns.current_entity_uri

    with %URI{} = board_uri <- parse(uri_str),
         :ok <- access_check(socket, board_uri),
         :ok <- if(board_owner?(caller, board_uri), do: {:error, :already_owner}, else: :ok),
         {:ok, %URI{scheme: "session"} = session_uri} <- target_session(socket, nil),
         marker =
           @request_edit_path <>
             "?" <>
             URI.encode_query(
               board: URI.to_string(board_uri),
               grantee: URI.to_string(caller)
             ),
         text = "【申请编辑】申请编辑看板「#{uri_label(board_uri)}」 #{marker}",
         :ok <- send_session_message(socket, session_uri, text) do
      {:ok, session_uri}
    else
      :error -> {:error, :bad_kanban_uri}
      {:error, _} = err -> err
    end
  end

  @doc """
  规则8 批准(公开供测试):caller 必须是板主人(`data_owner`)→ D4 同 ws 复查 →
  申请人须已持该板**只读**钥匙(cap 反推,见 `person_read_mount?/3`)→
  `CompositionCaps.mint_cap` 铸全动作钥匙升级。
  返回 `{:ok, grantee_uri}` 或 `{:error, :bad_kanban_uri | :not_board_owner |
  :cross_workspace_denied | :no_read_mount | term()}`。
  """
  @spec approve_edit_result(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def approve_edit_result(socket, uri_str, grantee_str) do
    caller = socket.assigns.current_entity_uri
    behavior = Module.concat([@share_board_behavior])

    with %URI{} = board_uri <- parse(uri_str),
         %URI{} = grantee <- parse(grantee_str),
         :ok <- if(board_owner?(caller, board_uri), do: :ok, else: {:error, :not_board_owner}),
         :ok <- EzagentPluginKanban.ShareReceive.ws_policy(:operate, grantee, board_uri),
         :ok <-
           if(person_read_mount?(board_uri, grantee, behavior),
             do: :ok,
             else: {:error, :no_read_mount}
           ),
         {:ok, _caps} <-
           Ezagent.Socialware.CompositionCaps.mint_cap(
             grantee,
             board_uri,
             behavior,
             Ezagent.ActionSet.action_names(behavior)
           ) do
      {:ok, grantee}
    else
      :error -> {:error, :bad_kanban_uri}
      {:error, _} = err -> err
    end
  end

  # 分享侧 access gate(能看见即可分享/申请,同 share_link 口径)。
  defp access_check(socket, %URI{} = board_uri) do
    if WorldData.can_share?(board_uri, WorldActions.read_ctx(socket)),
      do: :ok,
      else: {:error, :no_access}
  end

  # 目标会话:显式参数优先,缺省当前会话;都没有 → :no_session_context。
  defp target_session(_socket, session_str) when is_binary(session_str) and session_str != "" do
    case parse(session_str) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> {:error, :bad_session_uri}
    end
  end

  defp target_session(socket, _) do
    case socket.assigns[:current_session_uri] do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> {:error, :no_session_context}
    end
  end

  # 以 caller 身份往会话物化一条**可见**消息(`hops: 0`:存完即 :hop_exhausted,
  # 零路由 fan-out)。:call 模式——失败同步返回给 caller(禁散文错误物化)。
  defp send_session_message(socket, %URI{} = session_uri, text) do
    caller = socket.assigns.current_entity_uri
    msg = Ezagent.Message.new(caller, %{text: text, attachments: []}, hops: 0)

    result =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :send),
        mode: :call,
        args: %{message: msg},
        ctx: %{
          caller: caller,
          authenticated_principal: caller,
          caps: Map.get(socket.assigns, :current_caps, MapSet.new()),
          reply: {:caller_inbox, self()}
        },
        origin: :authenticated_external
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:send_failed, other}}
    end
  end

  # caller 是否板主人(data_owner)——与 WorldData.owns_board? 同款结构比对。
  defp board_owner?(%URI{} = caller, %URI{} = board_uri) do
    case Ezagent.CapabilityRegistry.data_owner_of(
           Module.concat([@share_board_behavior]),
           Ezagent.URI.instance(board_uri)
         ) do
      %URI{} = owner -> owner == caller
      _ -> false
    end
  rescue
    _ -> false
  end

  # 申请人是否已持该板只读钥匙(规则8 前置:升级的是「已持只读钥匙的人」)。
  # **不裸检查 cap-shape**(在 dispatch chokepoint 外判 cap 形状 = 违反
  # CapCheckOnlyAtChokepoint)。改以申请人身份对板 dispatch 一个只读动作
  # (`:get_tree`,mode `:call`),cap 校验落在 dispatch 许可路上:`{:ok,_}` = 有只读
  # 钥匙,任何 `{:error,_}` = 没有。同 `BoardProvision.session_holds_board_cap?` 的
  # 合规探针模式(EntityCaps.load 只用于装 envelope,不裸判 cap)。
  defp person_read_mount?(%URI{} = board_uri, %URI{} = grantee, behavior) do
    target = Ezagent.URI.with_action(board_uri, behavior.state_slice(), :get_tree)
    caps = grantee |> Ezagent.EntityCaps.load() |> MapSet.new()

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: grantee,
             authenticated_principal: grantee,
             caps: caps,
             reply: {:caller_inbox, self()}
           },
           origin: :trusted_internal
         }) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  # --- 小工具(与 WorldActions 同款私有 helper 的本地副本,避免互相开洞) -------

  defp parse(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, %URI{} = uri} -> uri
      _ -> :error
    end
  end

  defp parse(_), do: :error

  defp uri_label(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()

  defp reason(r) when is_atom(r), do: Atom.to_string(r)
  defp reason(r), do: inspect(r)
end
