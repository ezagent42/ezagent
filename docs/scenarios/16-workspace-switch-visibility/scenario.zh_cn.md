# 场景 16：切换 workspace + 可见性过滤

**类别**：6 — 跨 workspace
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-27（PR #434 基于 cap 的可见性合并）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- **两个** workspace：`workspace://system`（默认）和 `workspace://acme`
- 两个 workspace 各有 agent：`entity://agent/system/echo_1` 和 `entity://agent/acme/echo_a`
- Admin 在两个 workspace 都有 cap（admin 持 `:any`）

## 角色

- **调用方**：admin
- **目标**：workspace 下拉 + per-workspace agent 列表

## 步骤

1. 在 `/admin`，观察 workspace 下拉（右上）显示 `system`。
2. 验证 agents 列表**仅**显示 `entity://agent/system/echo_1`（workspace 过滤激活）。
3. 打开 workspace 下拉；验证 `acme` 可见（admin 在其中有 cap）。
4. 点 `acme`；LV 更新 context。
5. 验证 agents 列表现在**仅**显示 `entity://agent/acme/echo_a`。
6. Sessions、templates、routing rules 列表都反映新 workspace。
7. 切回 `system`；验证过滤回退。

## 预期结果

- LV socket assigns `current_workspace_uri` 在切换时更新。
- 所有 per-workspace 查询用新 URI 作为过滤参数。
- URL 可能携 `?ws=<workspace_uri>`（按 UI 实现 TBD）。
- 切换时检 cap（admin 有；非 admin 除非在目标 workspace 有 cap 否则失败）。

## 失败模式

- 尝试切到用户**无** cap 的 workspace：下拉**不**应显示。若命中过期 URL `?ws=other`，LV 拒绝 `:unauthorized` + 重定向到默认。
- 用户在某 workspace 中时该 workspace 被销毁：LV 经 PubSub 检测；重定向到默认 workspace。
- 同名 + 不同 ID 混淆：workspace URI 按 `feedback_uuid_is_canonical_identifier` 是规范的。

## 交叉引用

- 相关 PR：
  - PR #423 — SPEC：基于 cap 的 workspace 可见性
  - PR #434 — feat：cap 可见性替换 visible 字段
  - PR #417 — workspace 前缀不变式
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-27-workspace-cap-based-visibility.md`
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model.md`
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model-v2.md`
- 测试：
  - `apps/ezagent_core/test/integration/workspace_isolation_test.exs`
  - `apps/ezagent_domain_workspace/test/integration/plugin_isolation_workspace_test.exs`
- Open bug / gap：
  - 多 workspace 用户登录后默认 workspace：见场景 17。

## 备注

- PR #434 是结构性修复：之前的 `workspace.visible :: bool` 被替换为 "用户能看到一个 workspace 当且仅当持有任何 `workspace_uri` 匹配（或 `:any`）的 cap"。
- 按 `feedback_north_star_plugin_isolation`，下拉 + 过滤是通用的；无 plugin 知晓。
