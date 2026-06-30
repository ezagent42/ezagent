# 全 AI 化产品开发闭环 e2e —— 在合并后的 agent 化基座(kanban-as-role)上。
# 经 Router.dispatch 把 kanban 动作打到 entity://agent。返回每步结果汇总。
alias Ezagent.{Workspace, Capability, Router, Cmd}
alias Ezagent.Entity.User

admin = %{caller: User.admin_uri(), caps: MapSet.new([Capability.admin_genesis_cap()])}
member_cap = Capability.cap(:agent, Ezagent.Behavior.Kanban, :any)

uniq = System.unique_integer([:positive])
ws_uri = URI.new!("workspace://system")

disp = fn agent_uri, action, args, ctx ->
  cmd = Cmd.new(Ezagent.URI.with_action(agent_uri, :kanban, action), action, args,
    %{mode: :call, caller: ctx.caller, caps: ctx.caps, reply: {:caller_inbox, self()}})
  Router.dispatch(cmd)
end

steps = []
add = fn steps, label, res -> steps ++ [{label, res}] end

# === 1. 建 board-mgr agent (role kanban-manager × flavor native) ===
mgr_name = "board-mgr-#{uniq}"
{:ok, %{agent_uri: board}} =
  Workspace.create_agent(ws_uri, %{flavor: "native", name: mgr_name, role: "kanban-manager", cwd: "", with_pty: false}, admin)
steps = add.(steps, "create_board_mgr", {:ok, Map.take(board, [:scheme, :host, :path])})

# === 2. 9 阶段接力链 (每节点深一棒: positioning→…→pr) ===
chain = [
  {"", "定位:习惯养成产品", nil},
  {"metric", "指标:7日留存>40%", "metric"},
  {"pain", "痛点:坚持难/易放弃", "pain"},
  {"anchor", "锚点:连续打卡激励", "anchor"},
  {"ux", "UX:一键打卡卡片", "ux"},
  {"feature", "功能:连续打卡+补签", "feature"},
  {"issue", "issue:打卡API+存储", "issue"},
  {"test", "测试:打卡e2e用例", "test"},
  {"pr", "PR:打卡功能落地", "pr"}
]

{node_ids, steps} =
  Enum.reduce(chain, {[], steps}, fn {_stagekey, title, set_to}, {ids, st} ->
    parent = List.last(ids) || ""
    {:ok, %{id: nid}} = disp.(board, :add_node, %{parent_id: parent, title: title}, admin)
    st = add.(st, "add_node:#{title}", {:ok, nid})
    st =
      if set_to do
        r = disp.(board, :set_stage, %{id: nid, stage: set_to}, admin)
        add.(st, "set_stage:#{nid}->#{set_to}", r)
      else
        st
      end
    {ids ++ [nid], st}
  end)

# === 3. 建 worker agent + 认领 feature 节点(n6) ===
worker_name = "worker-feat-#{uniq}"
{:ok, %{agent_uri: worker}} =
  Workspace.create_agent(ws_uri, %{flavor: "native", name: worker_name, role: "kanban-manager", cwd: "", with_pty: false}, admin)
steps = add.(steps, "create_worker", {:ok, Map.take(worker, [:path])})

feature_id = Enum.at(node_ids, 5)   # n6 feature
worker_ctx = %{caller: worker, caps: MapSet.new([member_cap])}
steps = add.(steps, "worker_claim_feature", disp.(board, :claim_node, %{id: feature_id}, worker_ctx))

# === 4. status 流转 doing → done (owner=worker) ===
steps = add.(steps, "status_doing", disp.(board, :set_status, %{id: feature_id, status: "doing"}, worker_ctx))
steps = add.(steps, "status_done", disp.(board, :set_status, %{id: feature_id, status: "done"}, worker_ctx))

# === 5. 配 github + register_pr 到 issue 节点(n7) ===
issue_id = Enum.at(node_ids, 6)
steps = add.(steps, "set_board_config", disp.(board, :set_board_config, %{github_repo: "jjkysy/test-ezagent", miro_board: ""}, admin))
steps = add.(steps, "register_pr", disp.(board, :register_pr, %{id: issue_id, pr: "1"}, admin))

# === 6. markmap 投影 + get_tree 验证板持久化 ===
{:ok, %{markdown: md}} = disp.(board, :export_markmap, %{}, admin)
steps = add.(steps, "export_markmap_lines", {:ok, length(String.split(md, "\n"))})
{:ok, %{tree: %{nodes: nodes}}} = disp.(board, :get_tree, %{}, admin)
steps = add.(steps, "get_tree_node_count", {:ok, map_size(nodes)})
{:ok, slice} = Ezagent.Kind.get_slice(board, :kanban)
steps = add.(steps, "slice_persisted_nodes", {:ok, map_size(slice.tree.nodes)})

# === 汇总 ===
oks = Enum.count(steps, fn {_l, r} -> match?({:ok, _}, r) or match?(:ok, r) end)
%{
  board_uri: "#{board.scheme}://#{board.host}#{board.path}",
  worker_uri: "#{worker.scheme}://#{worker.host}#{worker.path}",
  total_steps: length(steps),
  ok_steps: oks,
  feature_owner: nodes[feature_id].owner,
  feature_status: nodes[feature_id].status,
  issue_artifacts: nodes[issue_id].artifacts,
  markmap_preview: String.slice(md, 0, 220),
  steps: Enum.map(steps, fn {l, r} -> {l, (if match?({:ok,_},r) or r==:ok, do: :OK, else: r)} end)
}
