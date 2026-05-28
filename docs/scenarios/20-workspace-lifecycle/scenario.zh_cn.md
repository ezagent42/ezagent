# 场景 20：Workspace 创建 + 添加成员 + 销毁

**类别**：8 — Workspace 管理
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-05-27（create + add_member 路径；销毁 E2E 从未跑过）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- 存在用户 `entity://user/system/alice`

## 角色

- **调用方**：admin
- **目标**：`workspace://acme`（创建）、Alice（添加成员）

## 步骤

### 创建

1. 打开 `/admin/workspaces`；点 "Create workspace"。
2. 输入名 `acme`；提交。
3. 验证 `workspaces` 行 + spawn 一个 `workspace://acme` Kind worker。
4. 默认 SessionTemplate 被 seed（PR #419 默认 + #399 system 规范修复）。

### 添加成员

5. 在 `/admin/workspaces/acme` 点 "Add member"；选 Alice。
6. Behavior `Workspace :add_member` 派发：
   - 验证 Alice URI 携 workspace 前缀 `system`（PR #417 不变式）
   - Spawn 成员侧状态（在 `acme` 上下文的 Kind）
   - 授予 Alice 基础 workspace cap（按 `username-default` agent 自动创建 — 见 master README §6 场景 5）

### 销毁（gap）

7. 点 "Destroy workspace"；确认。
8. **今天**：此操作在 workspace Kind 上触发 `lifecycle.terminate`，但**未**级联到子 session / agent / 成员 URI。Saga 补偿未测。
9. **预期**：全部子资源终止；绑定拆除；成员 URI 驱逐；最后删除 workspace 行 + Kind 行。

## 预期结果

- 创建：`workspaces` 行 + `kind_snapshots` 行 + 默认 SessionTemplate 行。
- 添加成员：`workspace_members` 行 + Alice 的 slice `:identity.workspaces` 含 `workspace://acme`。
- 销毁：**全部**子行删除（今天：gap；单独测试）。

## 失败模式

- 重名创建：`:already_exists`。
- 加跨 workspace URI 成员（`entity://user/other_ws/bob` 加到 `acme`）：被 PR #417 验证器拒绝。
- 销毁带活跃 session 的 workspace：今天部分销毁（泄漏）。Phase 2 Saga（场景 24）将修。

## 交叉引用

- 相关 PR：
  - PR #417 — workspace 前缀不变式
  - PR #419 — add_member spawn-then-grant + 默认 SessionTemplate seed
  - PR #399 — revert PR #397 过校正；`session://default/system/main` 是规范（Allen 2026-05-26）
  - PR #398 — 改名 `session://default/*` → `session://system/*`
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-25-workspace-default-to-system.md`
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model.md`
- 测试：
  - `apps/ezagent_domain_workspace/test/integration/add_member_spawn_then_grant_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/add_template_invokes_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/create_session_dispatch_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs`
  - `apps/ezagent_core/test/integration/lifecycle_terminate_test.exs`（仅 terminate）
- Open bug / gap：
  - **无 destroy-cascade E2E 测试**。见场景 24。

## 备注

- 销毁 gap 是类别 8 的主要 gap。在场景 24 落地之前，销毁非空 workspace 是操作员不推荐的。
- 按 PR #399，`system` 是规范默认 workspace 名；历史的 `default` 别名禁用。测试应使用 `system`。
