# §7 — kanban dev-loop 编排 seed：预物化 agent 拓扑 + 绑会话 + routing 规则。
#
# 把"全 AI 化产品开发闭环"的 agent + 路由配好（用户 Q2「配置 kanban agent 等一系列
# agent 和 routing 规则」）。幂等。跑法（dev server 停着时）：
#
#   mix run scripts/kanban_dev_loop_seed.exs
#
# 拓扑（fusion spec §7.1）：
#   - board       = kanban-manager agent（数据 agent，passive，board 在它 snapshot）
#   - ci-gate     = 接力 agent，收到 [kanban:pr_registered] → 算 verdict + 推 github status（B2）
#   - 绑会话      = board bind_session → 接力动作向会话 session.send，重入路由（B1）
#   - routing 规则 = text_contains("[kanban:pr_registered]") → ci-gate（字面 URI、无环 DAG）
#
# 真 claude brain 升级：把 ci-gate 的 flavor 从 "native" 换成 "cc-headless"（main 已有），
# 它收到 inbound 就用真 claude 决策（本 seed 默认 native，brain 升级见 development.md）。

alias Ezagent.{Workspace, Capability, Cmd, Router}
alias Ezagent.Entity.User
require Logger

admin = %{caller: User.admin_uri(), caps: MapSet.new([Capability.admin_genesis_cap()])}
ws = URI.new!("workspace://system")
session = "session://system/default/main"

create_agent = fn name, role ->
  case Workspace.create_agent(
         ws,
         %{flavor: "native", name: name, role: role, cwd: "", with_pty: false},
         admin
       ) do
    {:ok, %{agent_uri: uri}} -> uri
    # 已存在 → 复用（幂等）
    {:error, {:already_exists, _}} -> Ezagent.URI.agent("system", name)
    other -> raise "create #{name} failed: #{inspect(other)}"
  end
end

disp = fn agent_uri, action, args ->
  cmd =
    Cmd.new(Ezagent.URI.with_action(agent_uri, :kanban, action), action, args, %{
      mode: :call,
      caller: admin.caller,
      caps: admin.caps,
      reply: {:caller_inbox, self()}
    })

  Router.dispatch(cmd)
end

# 1) board agent + 绑会话（B1）
board = create_agent.("dev-loop-board", "kanban-manager")
Logger.info("board = #{board.scheme}://#{board.host}#{board.path}")
{:ok, _} = disp.(board, :bind_session, %{session_uri: session})
{:ok, _} = disp.(board, :set_board_config, %{github_repo: "jjkysy/test-ezagent", miro_board: ""})

# 2) ci-gate 接力 agent（native；brain 升级换 cc-headless）
ci_gate = create_agent.("ci-gate", "kanban-manager")
Logger.info("ci-gate = #{ci_gate.scheme}://#{ci_gate.host}#{ci_gate.path}")

# 3) routing 规则：[kanban:pr_registered] → ci-gate（字面 URI 绕成员校验；无环 DAG）
alias Ezagent.Routing.{Matcher, RuleStore}

table =
  case Application.get_env(:ezagent_core, :routing_tables) do
    [t | _] -> t
    _ -> :routing_rules
  end

ci_gate_str = "#{ci_gate.scheme}://#{ci_gate.host}#{ci_gate.path}"

case RuleStore.add(
       table,
       Matcher.text_contains("[kanban:pr_registered]"),
       [ci_gate_str],
       URI.to_string(User.admin_uri())
     ) do
  :ok -> :ok
  {:ok, _} -> :ok
  other -> Logger.warning("add_rule: #{inspect(other)}")
end

_ = RuleStore.load_into_registry(table)

IO.puts("""

=== kanban dev-loop seed 完成 ===
board    : #{board.scheme}://#{board.host}#{board.path}  (绑会话 #{session})
ci-gate  : #{ci_gate_str}
规则     : [kanban:pr_registered] → ci-gate  (table #{inspect(table)})

闭环：在 board 上 register_pr → B1 注入 session.send([kanban:pr_registered]) → 路由命中
→ ci-gate 收到 → 它 dispatch push_pr 到 board → B2 算 verdict + 推 github commit status。
brain 升级：把 ci-gate 换成 flavor "cc-headless"，它就用真 claude 决策。
""")
