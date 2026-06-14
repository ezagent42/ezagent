# 场景 24：销毁级联 — agent / session / workspace

**类别**：12 — 销毁 + 级联清理
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-06-14 — SagaRunner 级联*机制*现已充分覆盖（`scenario_24_destroy_cascade_test.exs`，10 测试绿：2 层 session→agent 级联、幂等步骤、前向失败→反向补偿、operator-repair 标记、真实 slice 回滚）。剩余缺口：完整 **workspace 级 3 层级联** E2E + `destroy(workspace) ⇒ count(orphans) == 0` 不变式。

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 一个填满的 workspace `workspace://acme`：
  - 3 个 agent（cc、curl、echo）各有 config_dir / api-key
  - 2 个 session，每个绑 2 个 agent
  - 1 个 session 上有 Feishu 绑定
- Admin 已登录

## 角色

- **调用方**：admin
- **目标（级联）**：workspace → sessions → agents → config_dirs / api-keys / 绑定
- **框架**：PR #449 SagaRunner（Phase 1 后）

## 步骤

### 销毁单 agent（今天单层已测）

1. 在 `/admin/agents/<uri>` 点 "Destroy"。
2. Agent Kind 转 `:terminating`；PTY 杀；pid-file 清理；config_dir 移除（若拥有，按 `sandbox_destroy_test.exs`）。
3. Session 成员关系驱逐（agent 从每个 session 的 `:members` slice 移除）。
4. 引用 agent 的 routing 规则：今天**未**清理（gap — 见 Notes）。

### 销毁 session

5. 在 session 点 "Destroy"。
6. Session Kind 终止；session_members 行删除；external_mirror 绑定解绑。
7. 验证所有成员收到 `:session_destroyed` 事件。

### 销毁 workspace（级联 — 今天**未测**）

8. 在 `workspace://acme` 点 "Destroy"。
9. **预期**：SagaRunner 编排：
   - Step 1：终止所有 session（步骤失败则补偿）
   - Step 2：终止所有 agent（补偿）
   - Step 3：删除模板、routing 规则、workspace 成员
   - Step 4：删除 workspace 行 + Kind worker
10. **今天**：仅约 step 4 不经正常 saga 跑；部分销毁泄漏状态。

## 预期结果（设想）

- Saga 完成：DB **无**孤儿行；**无**泄漏 PTY；**无**悬挂 ExternalMirrorWorker。
- Saga 失败（级联中）：SagaRunner 标记 operator-repair；admin 在 `/admin/saga-repairs` 看失败步骤 + 补偿状态。

## 失败模式

- 级联中 phx 崩溃：SagaRunner 启动重放；幂等步骤重试。
- 一个 agent 终止失败（例如 PTY 拒绝 SIGKILL）：operator-repair 标记 + saga 停。
- Cap 不匹配（级联中 admin cap 被撤）：saga 停 `:unauthorized`。

## 交叉引用

- 相关 PR：
  - PR #449 — feat(arch-p1d)：SagaRunner
  - PR #451 — Phase 1 所有子分支整合
  - PR #385 — orphan reaper（单 agent）
  - PR #418 — unbind projection 同步
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §5 — SagaRunner 契约
- 测试：
  - `apps/ezagent_core/test/integration/sandbox_destroy_test.exs` — 单 agent
  - `apps/ezagent_core/test/integration/lifecycle_terminate_test.exs` — terminate action body
  - `apps/ezagent_core/test/e2e/scenario_24_destroy_cascade_test.exs` — SagaRunner 级联机制
    （10 测试，2026-06-14 绿）：happy-path 2 层 session→agent 级联、幂等中间步、前向失败→反向补偿、
    补偿失败→operator-repair 标记、回滚时真实 slice 写回、空/无补偿边界。
  - `apps/ezagent_core/test/invariants/cascade_pr0_foundations_test.exs` — 级联基础。
- Open bug / gap：
  - **完整 workspace 级（3 层）级联 E2E**（步骤 8-10）— SagaRunner *机制*已测，但端到端
    `workspace → sessions → agents → config_dirs/api-keys/bindings` 销毁 + `count(orphans) == 0`
    不变式（见下方备注）尚未断言。这是类别 12 主要剩余缺口。
  - 引用已销毁 agent 的 routing 规则未清理。值得单独场景（或本场景内）。

## 备注

- 这是 master README §6 优先级 3 — `SagaRunner` baseline 测试必须在 Phase 2 开始迁移依赖它的 Behavior 前落地。
- 按 `feedback_completion_requires_invariant_test`，级联场景仅当不变式测试断言 "destroy(workspace) ⇒ count(orphans) == 0" 时算 "done"。
