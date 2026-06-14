# 场景 17：在多 workspace 持 cap 的用户

**类别**：6 — 跨 workspace
**状态**：✅ implemented-and-tested
**最近验证**：2026-06-14 — 场景级旅程已 codified 于 `apps/ezagent_core/test/e2e/scenario_17_multi_workspace_user_test.exs`（4 测试，绿）：多 workspace 可见性、系统成员用 per-workspace cap 跨域派发进两个 workspace、非系统拒绝对照、撤销后再次拒绝。登录默认 workspace 选择（旧文档的头号 gap）**已解决且有测试** — 见备注。

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- 两个 workspace：`workspace://system` 和 `workspace://acme`
- 用户 U 在两个 workspace 都有 cap（admin 授予，场景 14，每 workspace 一次）

## 角色

- **调用方**：用户 U
- **目标**：2 个 workspace

## 步骤

### 登录 + 默认 workspace

1. U 经密码登录（场景 02 用 U 的凭据）。
2. LV 为 U 选默认 workspace = U 的 home workspace（entity URI 的 workspace 段），确定性，由 `SessionPrincipal.put` 统一写入（见备注）。
3. 验证 workspace 下拉显示 `system` 和 `acme` **两者**。

### 切换

4. 切到 `acme`（场景 16）。
5. 验证 U 可执行其在 `acme` 有 cap 的 action（例如在 `acme` session 发消息）。

### 跨 workspace cap 泄漏防护

6. 从 `acme` 上下文，尝试对 `system` URI 派发。
7. 验证 `:cross_workspace_denied`（按 Invocation §5.6）。
8. 切回 `system`；验证同 action 现在成功。

### Magic-link 交互

9. U 退出 + 用场景 01 的 magic-link 重新认证。
10. 验证 magic-link 后默认 workspace 选择与密码登录默认一致。（**现已一致** — magic-link 与密码登录都经 `SessionPrincipal.put` 同一入口写入 home workspace；见备注。）

## 预期结果

- U 可在 workspace 间自由切换（cap-gated）。
- 跨 workspace 派发按结构性 cap 检查拒绝。
- 默认 workspace 选择是确定性的 + 已记录。

## 失败模式

- U 被授予 cap，然后撤销：下次 LV mount 时该 workspace 从下拉消失（PubSub 驱动更新）。
- U 被授予非成员 workspace 的 cap：他是否自动加为成员？今天：**否** — cap 授予 ≠ 成员关系。差异值得 SPEC。

## 交叉引用

- 相关 PR：
  - PR #417 — workspace 前缀不变式
  - PR #434 — cap-based 可见性
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-24-workspace-user-mental-model-v2.md` — 部分覆盖
  - `docs/superpowers/specs/2026-05-25-workspace-default-to-system.md` — system 作为默认（但非多 WS 用户）
- 测试：
  - `apps/ezagent_core/test/e2e/scenario_17_multi_workspace_user_test.exs` — 场景级旅程
    （双成员可见性、系统成员跨域派发进两个 workspace、非系统拒绝对照、撤销后再次拒绝）。
  - `apps/ezagent_core/test/invariants/cap_based_workspace_visibility_invariant_test.exs` —
    INV-1..8 覆盖 workspace 下拉/可见性模型（步骤 3）。
  - `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs` +
    `promote_to_system_grants_cross_workspace_test.exs` — 基于成员的跨域授权谓词（步骤 4-8）。
  - `apps/ezagent_domain_instance_message/test/integration/workspace_isolation_test.exs` —
    反向跨 workspace 派发路径。
  - `apps/ezagent_web/test/ezagent_web/session_principal_test.exs:147` — 默认 workspace 不变式
    （`current_workspace_uri == entity_workspace_uri`），所有登录路径统一强制。
- Open bug / gap：
  - **Cap 授予 ≠ 成员**语义：今天它们是独立字段（cap-scope 与成员都按 INV-6 贡献可见性）。
    若要单一真相源可对齐，但非正确性 gap。

## 备注

- **登录默认 workspace 已解决（Phase 9 PR-5，SPEC v3 §6.1）— 旧文档的「字母序 vs last-active、不一致、需 SPEC」是 Phase 9 之前的描述。** `EzagentWeb.SessionPrincipal.put/2,3` 是 `:current_workspace_uri` 的唯一授权写入口，所有登录路径都经它（`session_controller.ex:138` 密码、`magic_link_controller.ex:92` magic-link、`registration_controller.ex:154` 注册）。它永远 `workspace_uri = entity_workspace_uri(entity_uri)`（用户 home workspace），写入处强制不变式 `current_workspace_uri == entity_workspace_uri(current_entity_uri)`（已测：`session_principal_test.exs:147`，+ :217/:261 证明无其它写入者）。故默认值确定且跨登录方式一致。workspace *切换* = 退出 + 重新认证到目标 workspace（SPEC v3 §6.4）—— entity URI 与 workspace 绑定，切 workspace 即切 entity。
- entity URI 与 workspace 绑定意味着「多 workspace 用户」到达非 home workspace 的方式：要么跨域授权（系统成员 / `:any` cap），要么重新认证进目标 workspace —— 两者都由场景测试 + 所引不变式覆盖。
