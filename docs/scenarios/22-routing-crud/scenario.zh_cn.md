# 场景 22：Routing 规则 CRUD + 优先级

**类别**：10 — Routing
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-26（PR #418 + post-#120 整合）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- 一个 session `session://system/sess_a`，成员：admin + 2 个 echo agent
- 系统默认规则激活：`always() → ["$session_members"]`（PR #120，不可删除）

## 角色

- **调用方**：admin
- **目标**：`RoutingRegistry` 中的 `routing_rules` 表
- **Behavior**：`Ezagent.Behavior.Routing`（actions：`:add_rule`、`:remove_rule`、`:disable`、`:enable`、`:list_rules`）

## 步骤

### 加 per-session 规则

1. 打开 `/admin/sessions/sess_a/routing`。
2. 点 "Add rule"；选 Matcher AST：
   - Matcher 类型：`{:mention, "agent://system/echo_1"}`
   - Receptor：`["entity://agent/system/echo_1"]`
3. 提交；验证规则出现 + `enabled = true`。
4. 验证 DB `routing_rules` 行，Matcher 经 `Ezagent.Routing.Matcher.to_json/1` 序列化。

### 测优先级

5. 在 `sess_a` 发非 mention："hi all"。验证两个 echo 都收到（系统默认扇出）。
6. 发 mention：`@echo_1 hi`。验证**仅** echo_1 收到（自定义规则 + mention-gating 组合）。

### 禁用 + 重新启用

7. 禁用 per-session 规则。再发 `@echo_1 hi`；验证 mention-gated 路由穿透到默认规则（echo_1 收到因为 mention-gated 定位被 mention 的 agent，与自定义规则无关）。
8. 重新启用。

### 删除

9. 点 "Remove rule"；验证行被删除。
10. 尝试删除系统默认 `always → $session_members` 规则；验证 `:cannot_delete_system_default`（PR #120 — 系统默认仅 admin 可禁用）。

## 预期结果

- CRUD 操作全部经 `Ezagent.Behavior.Routing` 派发。
- `RoutingRegistry` ETS 表（按 Decision #95 owner-pid 检查）同步更新。
- Matcher AST 正确 JSON 序列化 + 反序列化（5-leaf + 3-组合子语法 — PR #118）。
- 优先级：自定义规则 + 系统默认都加性应用；mention-gating 在上层。

## 失败模式

- 加循环规则（规则 A 指向 B，B 经 routing-emit 指向 A）：当前不可检测，但 `RoutingResolver` 单步，无无限循环。
- 加无效 receptor URI 规则：`:invalid_receptor`。
- 加 reserved 魔法 token `$session_members` 作为 receptor：允许（这是系统默认模式）。
- 禁用 + 重启 phx：enable 状态经 `kind_snapshots` 存活（Decision #115）。

## 交叉引用

- 相关 PR：
  - PR #95 — RoutingRegistry 作第 3 Registry 家族（Decision #95）
  - PR #118 — Matcher 组合子 and/or/not（Decision #118）
  - PR #120 — Routing 整合 + 系统默认 + CI 不变式 gate（Decision #120）
  - PR #418 — unbind projection + session routing 导航
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  - （PR #120 文档在 ARCHITECTURE Decision Log）
- 测试：
  - `apps/ezagent_core/test/integration/routing_consolidation_invariant_test.exs` — **核心**不变式 gate
  - `apps/ezagent_core/test/integration/routing_boot_test.exs`
  - `apps/ezagent_core/test/integration/routing_cap_test.exs`
  - `apps/ezagent_core/test/integration/chat_routing_test.exs`
  - `apps/ezagent_domain_instance_message/test/.../default_rules_migration_test.exs`
- 证据：
  - `docs/notes/phase-9-demo-2026-05-21.md` — routing 截图

## 备注

- `RoutingRegistry` 与 `KindRegistry` + `BehaviorRegistry` 并列为第 3 Registry 家族，但携带 owner-pid 检查因 admin 运行时写（非仅 boot 时）。
- "no rules + no members → no recipients" 不变式测试（`routing_consolidation_invariant_test.exs`）是任何未来 hidden-fan-out 重新引入的回归 gate。
