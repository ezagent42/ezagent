# 场景 17：在多 workspace 持 cap 的用户

**类别**：6 — 跨 workspace
**状态**：⚠️ implemented-with-gaps
**最近验证**：仅反向路径（`workspace_isolation_test.exs`）

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
2. LV 为 U 选默认 workspace。**今天这是实现定义的** — 可能是 cap 集中字母序第一个 workspace。SPEC 非权威。
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
10. 验证 magic-link 后默认 workspace 选择与密码登录默认一致。（当前实现：**不**一致 — magic-link 可能默认到 last-active；密码默认到字母序第一。需要 SPEC。）

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
  - `apps/ezagent_core/test/integration/workspace_isolation_test.exs` — 覆盖反向跨 workspace 派发路径
  - 无多 WS 用户登录时默认 workspace 选择的测试
- Open bug / gap：
  - **无多 workspace 用户登录默认 workspace 的 SPEC**。这是类别 6 的头号 gap，也是场景 04（跨 workspace token）下游阻塞的原因。
  - **Cap 授予 ≠ 成员**语义：今天它们是独立字段。值得对齐。

## 备注

- 按 Allen 2026-05-26（PR #399 + #398），`workspace://system` 是无偏好时的规范 fallback。确认这是多 WS 登录的通用默认是下一个 SPEC。
- 这是任何非平凡多租户结构生产部署的主要阻塞。
