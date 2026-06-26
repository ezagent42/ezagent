defmodule Ezagent.Behavior.Kanban.Shared do
  @moduledoc """
  Kanban Behavior 的共享原语——`Ezagent.Behavior.Kanban`（拓扑/认领/读写动作）与
  `Ezagent.Behavior.Kanban.Connectors`（出站连接器动作）共用的小函数集。

  抽出来纯粹是为了让两个 handler 模块复用同一套读/写/授权/归一逻辑，**不引入新语义**：
  - 读：`tree/1`（经 `ctx[:read]`）；
  - 写：`commit/1`——**全 Behavior 唯一的 `tree set-effect（经 commit/1 收口）` 字面**（main + connectors
    所有树变更都经此收敛，守 moduledoc「所有写动作经唯一 commit/1」约定）；
  - 授权：`owner_or_admin?/2` / `admin?/1`（per-node owner 或 wildcard cap）；
  - 归一：`normalize_artifact/1`（artifact 进节点快照前归一 + content 限长）。
  """

  alias Ezagent.Capability
  alias Ezagent.Cmd
  alias Ezagent.Message

  # inline 内容上限——artifact 进节点快照(真相源)，CI 关键内容(Gherkin/spec)走 inline
  # 而非外部 ref(feishu 死链/权限墙)；设上限防快照膨胀。64KB 够装一般 excalidraw 线框 JSON
  # /Gherkin/spec 卡；不无限大是因为整棵树存成一个 blob，超大图走上传文件。
  @artifact_content_limit 65_536

  @doc "空树（nodes/root_id/seq/drops）。"
  def empty_tree, do: %{nodes: %{}, root_id: nil, seq: 0, drops: []}

  @doc "经 `ctx[:read]` 读当前树（缺省空树）。"
  def tree(ctx), do: ctx[:read].(:tree, empty_tree())

  @doc """
  全 Behavior 唯一的 `{:set` 字面。tree 含 nodes/root_id/seq/drops(图级别 drop 历史)，
  全经此收敛。put_new 归一化 drops——旧树/字面量缺 drops 时补 []，保证后续
  `%{t | drops: ...}` 安全。
  """
  def commit(tree), do: {:set, :tree, Map.put_new(tree, :drops, [])}

  @doc "节点级授权：caller 是 wildcard admin，或 node.owner == caller。"
  def owner_or_admin?(ctx, node),
    do: admin?(ctx) or (node.owner != nil and node.owner == caller_str(ctx))

  @doc "caller 是否持 wildcard(admin) cap。"
  def admin?(ctx) do
    ctx
    |> Map.get(:caps, MapSet.new())
    |> Enum.any?(fn
      %Capability{kind: :any} -> true
      _ -> false
    end)
  end

  @doc "caller URI 的字符串形式（per-node owner 比对用）。"
  def caller_str(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  @doc """
  板级会话绑定的 `{:dispatch}` effect（B1）——动作成功后把一条公告消息打到绑定会话的
  `session.send`，让消息重入路由 → 触发下一个 agent（接力）。仿 `cc_headless_agent.ex:130`
  的 self.send 范式：caller=看板 agent 自己（`self_uri`），自铸一条 session-send cap
  （`granted_by` 自己），`reply: :ignore`（fire-and-forget——被动看板不等回执）。

  `session_uri` 为 nil/非 session URI（未绑定）→ `[]`（动作照常成功，只是不进路由）。
  返回 `[{:dispatch, %Cmd{}}]` 追加进 handler 的 effect 列表即可（与 `commit/1` 并列）。
  """
  @spec session_dispatch(URI.t() | String.t() | nil, URI.t() | nil, String.t()) :: [tuple()]
  def session_dispatch(nil, _self_uri, _text), do: []
  def session_dispatch(_session_uri, nil, _text), do: []

  def session_dispatch(session_uri, %URI{} = self_uri, text) when is_binary(text) do
    case as_session_uri(session_uri) do
      %URI{} = session -> [dispatch_to_session(session, self_uri, text)]
      nil -> []
    end
  end

  def session_dispatch(_, _, _), do: []

  defp as_session_uri(%URI{scheme: "session"} = u), do: u

  defp as_session_uri(s) when is_binary(s) do
    case Ezagent.URI.new!(s) do
      %URI{scheme: "session"} = u -> u
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp as_session_uri(_), do: nil

  defp dispatch_to_session(%URI{} = session, %URI{} = self_uri, text) do
    msg = Message.new(self_uri, %{text: text, attachments: []}, mentions: [])
    target = Ezagent.URI.with_action(session, :session, :send)

    cmd =
      Cmd.new(target, :send, %{message: msg}, %{
        caller: self_uri,
        caps:
          MapSet.new([
            %Ezagent.Capability{
              Capability.cap(
                :session,
                :any,
                :send,
                Ezagent.URI.instance(session),
                Capability.workspace_of(session)
              )
              | granted_by: self_uri,
                granted_at: DateTime.utc_now()
            }
          ]),
        reply: :ignore
      })

    {:dispatch, cmd}
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
