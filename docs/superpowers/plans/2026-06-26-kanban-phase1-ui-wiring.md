# Kanban Phase 1 — UI 接线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 executing-plans 逐任务实施。步骤用 `- [ ]`。
> 上位设计：`docs/discuss/2026-06-26-kanban-team-flow-spec.md`(SPEC §7 Phase 1) + `…/flow-redesign.md`。

**Goal:** 让 kanban 在 world UI 可达 + 看板能绑会话（B1 接力的前置），不碰 core、纯 plugin+world。

**Architecture:** ① kanban 插件声明 `config_surface/0` → Plugins 页出可点入口；② `bind_session` 进 world 动作白名单 + 看板配置面板加"绑会话"控件。

**Tech Stack:** Elixir/OTP（kanban 插件 + world plugin）、React/TS（world assets）、ExUnit。

## Global Constraints
- 三层铁律：连接器/Behavior 在 kanban **plugin**，UI 在 **world**，**core 不碰**；跨 Kind 走 `Ezagent.Invocation.dispatch`（P14）。
- Behavior 只 `use Ezagent.Lifecycle`；动手前 load `ezagent-developer` skill。
- gate：`mix ezagent.check_invariants.lifecycle` 无新增违规 + `mix format --check-formatted` + 相关 `mix test` 绿。
- 每任务结束：单测绿 + e2e + **截图** + commit。

---

### Task 1: kanban 声明 config_surface/0（Plugins 页入口）

**Files:**
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`（删 106-114 的"故意不声明"注释，加 `config_surface/0`）
- Test: `apps/ezagent_plugin_kanban/test/application_test.exs`（无则建）

**Interfaces:**
- Produces: `EzagentPluginKanban.Application.config_surface/0 :: %{kind: :route, path: "/plugins/kanban", label: "看板"}`
- Consumes: world `config_target/1`（`workspace_plugin_data.ex:289`）认 `%{kind: :route, path, label}`→`{path,label}`。

- [ ] **Step 1: 写失败测试**
```elixir
# apps/ezagent_plugin_kanban/test/application_test.exs
defmodule EzagentPluginKanban.ApplicationTest do
  use ExUnit.Case, async: true
  test "config_surface 声明 /plugins/kanban 路由入口（Plugins 页可点）" do
    assert %{kind: :route, path: "/plugins/kanban", label: label} =
             EzagentPluginKanban.Application.config_surface()
    assert is_binary(label) and label != ""
  end
end
```
- [ ] **Step 2: 跑测试确认失败**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/application_test.exs`
Expected: FAIL（config_surface 默认 nil，断言不匹配）
- [ ] **Step 3: 实现**（application.ex，替换 106-114 注释块）
```elixir
@impl Ezagent.Plugin
def config_surface, do: %{kind: :route, path: "/plugins/kanban", label: "看板"}
```
- [ ] **Step 4: 跑测试确认通过 + 不变式 gate**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/application_test.exs && mise exec -- mix ezagent.check_invariants.lifecycle`
Expected: PASS（gate 仅既存 core NP-2，无新增）
- [ ] **Step 5: e2e + 截图**：起 server，登录 world，`/plugins` 页**截图**显示"看板"可点入口，点进 `/plugins/kanban` 列表**截图**。存 `docs/e2e/2026-06-26-kanban-phase1/`。
- [ ] **Step 6: commit**
```bash
git add apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex apps/ezagent_plugin_kanban/test/application_test.exs docs/e2e/2026-06-26-kanban-phase1
git commit -m "feat(kanban): config_surface → Plugins 页 kanban 入口(Phase1 A)"
```

---

### Task 2: bind_session 进 world 动作白名单 + 配置面板控件

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:242`（`@kanban_actions` 加 `kanban.bind_session`）
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`（加 `handle_dispatch(socket, "kanban.bind_session", …)` 子句）
- Modify: `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx`（本图配置面板加"绑定会话"输入+按钮，dispatch `kanban.bind_session`）
- Test: `apps/ezagent_plugin_kanban/test/behavior/relay_test.exs`（已存在 bind_session 行为测试，补一条 world 白名单断言到 world 测试）

**Interfaces:**
- Consumes: kanban Behavior `bind_session`（已存在，`%{session_uri}`→ BoardConfig.session_uri，`connectors.ex bind_session`）。
- Produces: world 经 `kanban.bind_session` dispatch 该动作；UI 控件触发。

- [ ] **Step 1: 写失败测试**（world 端：bind_session 在白名单 + 有 handler 子句）
```elixir
# apps/ezagent_plugin_world/test/kanban_bind_session_test.exs
defmodule EzagentPluginWorld.KanbanBindSessionTest do
  use ExUnit.Case, async: true
  test "kanban.bind_session 在 world 动作白名单" do
    wl = EzagentPluginWorld.WorldLive.__kanban_actions__()  # 见 Step3：暴露白名单的 test helper
    assert "kanban.bind_session" in wl
  end
end
```
- [ ] **Step 2: 跑测试确认失败**
Run: `mise exec -- mix test apps/ezagent_plugin_world/test/kanban_bind_session_test.exs`
Expected: FAIL（白名单无 bind_session / helper 未定义）
- [ ] **Step 3: 实现**
  1. `world_live.ex:242` `@kanban_actions` 末尾加 `kanban.bind_session`；加 `def __kanban_actions__, do: @kanban_actions`（test helper）。
  2. `kanban_actions.ex` 加：
```elixir
def handle_dispatch(socket, "kanban.bind_session", %{"kanban_uri" => u, "session_uri" => s}),
  do: act(socket, u, :bind_session, %{session_uri: s})
```
  3. `Kanban.tsx` 本图配置面板（`本图配置` 区块）加一个 session URI 输入 + "绑定会话"按钮，onClick `onAction("kanban.bind_session", {kanban_uri, session_uri})`。
- [ ] **Step 4: 跑测试确认通过 + format + 不变式**
Run: `mise exec -- mix test apps/ezagent_plugin_world/test/kanban_bind_session_test.exs && mise exec -- mix format --check-formatted apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`
Expected: PASS
- [ ] **Step 5: e2e + 截图**：world 看板配置面板**截图**"绑定会话"控件；填一个 session URI 点绑定，erpc 核验 `BoardConfig.read(board).session_uri` 已写 + **截图**配置面板回显。存 `docs/e2e/2026-06-26-kanban-phase1/`。
- [ ] **Step 6: commit**
```bash
git add apps/ezagent_plugin_world docs/e2e/2026-06-26-kanban-phase1
git commit -m "feat(kanban): bind_session 进 world 白名单+配置面板控件(Phase1 B)"
```

---

## Self-Review（writing-plans）
- **Spec 覆盖**：Phase 1 = SPEC 能力 A(config_surface)+B(bind_session UI) ✓ 两任务一一对应。
- **占位扫描**：无 TBD/TODO；代码块给全。
- **类型一致**：`config_surface/0` 返回形与 world `config_target/1` 匹配（`%{kind: :route, path, label}`）；`bind_session` args `%{session_uri}` 与 Behavior 一致。
- **后续 Phase**：Phase 2-5 各自独立计划（多子系统，writing-plans 拆分），到时再写（github plugin 抽出是 Phase 2 单独大计划）。

## dev-together 对齐
- **machine return gate = 本流程 CI 硬门**（Phase 2）：dev-together "return 要 CI 绿+rebased on main" 就是看板 push_pr 的 commit status 硬门——同一机制。
- **handoff 4-property DoD = issue 节点 spec + check_pr_gate 判据**（Gherkin/issue/test_green/upstream_done）。
- **team.md 花名册**：ABCD = team.md 行（A/D `role:human-dev`，B/C `role:agent`，身份=`github_username`）；`board_node_id` 缝 dev-together 台账↔节点（Phase 3 落实）。
