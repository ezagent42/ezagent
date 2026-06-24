defmodule EzagentPluginKanban.Miro.Sync do
  @moduledoc """
  把 ezagent 的节点树推到 Miro（df-prd 增量 4 出站）。

  - `tree_to_ops/1` —— **纯函数**：树 → 有序操作列表（根在前、父在子前、兄弟按 order），
    每项 `%{ez_id, content, parent_ez_id}`。可单测、无网络。
  - `push_tree/2` —— 建**新板** + 按序建节点（首推/演示用）。
  - `sync_out/2` —— **复用同板**增量出站（删板上现有 + 按树重建，返 ez_id↔miro_id 映射）。
  - `detect_inbound/2` —— **纯函数**入站检测（人新增，非破坏性；真相源=ezagent）。

  双向轮询编排见 `EzagentPluginKanban.MiroSync`（plugin 自有进程，不复用 session
  锁死的 external_mirror 域）。
  """

  alias EzagentPluginKanban.Miro

  @type op :: %{ez_id: String.t(), content: String.t(), parent_ez_id: String.t() | nil}

  @doc "树 → 有序操作列表（DFS：根→子，兄弟按 :order）。空树返回 []。"
  @spec tree_to_ops(%{nodes: map(), root_id: String.t() | nil}) :: [op()]
  def tree_to_ops(%{nodes: nodes, root_id: root_id}) when is_map(nodes) and not is_nil(root_id) do
    walk(root_id, nodes)
  end

  def tree_to_ops(_), do: []

  defp walk(id, nodes) do
    node = Map.fetch!(nodes, id)
    self_op = %{ez_id: id, content: render_content(node), parent_ez_id: node.parent_id}

    children =
      nodes
      |> Enum.filter(fn {_cid, n} -> n.parent_id == id end)
      |> Enum.sort_by(fn {_cid, n} -> n.order end)
      |> Enum.map(fn {cid, _n} -> cid end)

    [self_op | Enum.flat_map(children, fn cid -> walk(cid, nodes) end)]
  end

  @status_icon %{unassigned: "○", claimed: "◔", doing: "◑", done: "●"}

  @doc """
  把节点的丰富信息渲染成 Miro 节点的**富文本 label**（status 图标 + `[stage]` 标签 +
  标题 + `@owner` + 📊metrics + 📎artifacts）。

  ⚠️ Miro REST kanban create **不支持设节点颜色/样式**（`style.nodeColor`/
  `nodeView.style.color`/`fillColor` 均 400 "not supported"，配色是 Web SDK 浏览器独有）
  → 故所有元信息都编进文字 label。**不带外层 `<p>`**（Miro 自动包一层）。

  只对带 `:status`（即真节点模型）的节点富化；老式 `%{title}` 字面只回标题。
  """
  @spec render_content(map()) :: String.t()
  def render_content(%{status: _} = node) do
    [
      Map.get(@status_icon, Map.get(node, :status)),
      stage_tag(Map.get(node, :stage)),
      html_escape(Map.get(node, :title, "")),
      owner_tag(Map.get(node, :owner)),
      metrics_tag(Map.get(node, :metrics, [])),
      artifacts_tag(Map.get(node, :artifacts, []))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  def render_content(node), do: html_escape(Map.get(node, :title, ""))

  defp stage_tag(nil), do: ""
  defp stage_tag(stage), do: "[#{stage}]"

  defp owner_tag(nil), do: ""
  defp owner_tag(owner), do: "<b>@#{owner |> to_string() |> String.split("/") |> List.last()}</b>"

  defp metrics_tag([]), do: ""

  defp metrics_tag(ms),
    do: "📊" <> Enum.map_join(ms, ";", fn m -> "#{m.name}:#{m.current || "—"}/#{m.target}" end)

  defp artifacts_tag([]), do: ""

  # Miro 是**概览投影**：显示挂了哪些附件（名字 + 有外链就给链接），**不塞附件内容**
  # （inline content / excalidraw JSON 塞进 label 是噪音）。内容/分享走 ezagent（节点 + 发对话）。
  defp artifacts_tag(as) do
    body =
      as
      |> Enum.take(6)
      |> Enum.map_join(" · ", &one_artifact/1)

    extra = if length(as) > 6, do: " …+#{length(as) - 6}", else: ""
    "📎 " <> body <> extra
  end

  defp one_artifact(a) do
    name = html_escape(to_string(Map.get(a, :ref) || Map.get(a, :kind) || "产物"))
    url = Map.get(a, :url)

    if is_binary(url) and url != "", do: "#{name}(#{html_escape(url)})", else: name
  end

  defp html_escape(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  把整棵树推到一块新建的 Miro 板。
  返回 `{:ok, %{board_id, mapping}}`（全部成功）或 `{:error, %{board_id, mapping, errors}}`。
  """
  @spec push_tree(%{nodes: map(), root_id: String.t() | nil}, String.t()) ::
          {:ok, map()} | {:error, term()}
  def push_tree(tree, board_name) do
    with {:ok, %{token: token}} <- Miro.read_creds(),
         {:ok, board_id} <- Miro.create_board(token, board_name) do
      finish(board_id, create_tree(token, board_id, tree))
    end
  end

  @doc """
  出站增量同步：把树推到**已存在的同一块板**（复用 board_id）。Miro 无 in-place
  update，故策略 = 删板上现有 mind-map 节点 + 按树重建（幂等、复用板）。返回
  `{:ok, %{board_id, mapping}}`——mapping 是 ez_id↔miro_id，供入站回声防护对比。
  """
  @spec sync_out(%{nodes: map(), root_id: String.t() | nil}, String.t()) ::
          {:ok, map()} | {:error, term()}
  def sync_out(tree, board_id) do
    with {:ok, %{token: token}} <- Miro.read_creds(),
         :ok <- Miro.delete_all_nodes(token, board_id) do
      finish(board_id, create_tree(token, board_id, tree))
    end
  end

  # 按有序 ops 在 board 上建节点，维护 ez_id↔miro_id 映射（子节点带父 miro_id）。
  defp create_tree(token, board_id, tree) do
    tree
    |> tree_to_ops()
    |> Enum.reduce({%{}, []}, fn op, {map, errs} ->
      parent_miro = op.parent_ez_id && Map.get(map, op.parent_ez_id)

      case Miro.create_node(token, board_id, op.content, parent_miro) do
        {:ok, miro_id} -> {Map.put(map, op.ez_id, miro_id), errs}
        {:error, e} -> {map, [{op.ez_id, e} | errs]}
      end
    end)
  end

  defp finish(board_id, {mapping, errors}) do
    result = %{board_id: board_id, mapping: mapping, errors: Enum.reverse(errors)}
    if errors == [], do: {:ok, result}, else: {:error, result}
  end

  @type inbound_op :: %{miro_id: String.t(), content: String.t(), parent_ez_id: String.t() | nil}

  @doc """
  入站检测（**纯函数、非破坏性**）：对比 Miro 当前节点 vs 上次出站映射，找出**人在
  Miro 新加**的节点（miro_id 不在映射里）。返回 `[%{miro_id, content, parent_ez_id}]`，
  parent_ez_id 由映射反查（根 / 父尚未知则 nil）。

  **只检测新增**——真相源 = ezagent，Miro 端删除**不**回删 ezagent（下次 `sync_out`
  重建即自愈），故此处不产出 delete op。Miro 节点 parent 在 GET 响应里是
  `node["parent"]["id"]`（根 `data.isRoot==true`、无 parent）。
  """
  @spec detect_inbound([map()], map()) :: [inbound_op()]
  def detect_inbound(miro_nodes, mapping) when is_list(miro_nodes) and is_map(mapping) do
    known = mapping |> Map.values() |> MapSet.new()
    reverse = Map.new(mapping, fn {ez, miro} -> {miro, ez} end)

    miro_nodes
    |> Enum.reject(fn n -> MapSet.member?(known, n["id"]) end)
    |> Enum.map(fn n ->
      parent_miro = get_in(n, ["parent", "id"])

      %{
        miro_id: n["id"],
        content: strip_html(get_in(n, ["data", "nodeView", "data", "content"]) || ""),
        parent_ez_id: parent_miro && Map.get(reverse, parent_miro)
      }
    end)
  end

  # Miro 节点 content 带 `<p>…</p>` 包裹——剥成纯文本作 ezagent 标题。
  defp strip_html(s), do: s |> String.replace(~r{</?[a-zA-Z][^>]*>}, "") |> String.trim()
end
