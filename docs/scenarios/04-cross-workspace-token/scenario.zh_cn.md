# 场景 04：跨 workspace agent token 使用（codex 外部 agent）

**类别**：1 — 认证 / Identity
**状态**：❌ not-implemented
**最近验证**：从未（场景作为可运行 e2e 尚不存在）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已为 workspace W1 的终端用户 U mint 了 token（场景 03）
- workspace W2 的 codex 或外部 CLI agent A 需代表 U 派发到 W1

## 角色

- **调用方**：W2 的 codex 外部 agent，持有 U 的 W1 token
- **目标**：W1 中任何 URI（例如 `session://<...>/W1/<...>`）
- **Behavior**：`Ezagent.Behavior.UserTokens`（认证）+ 目标上派发的 Behavior

## 步骤（设想 — 尚未接线）

1. W1 的 admin 给用户 U mint token T；T 携带 `workspace_uri: workspace://W1`。
2. W2 的 codex agent A 读取 T（经安全通道交付 — TBD；今天无 enrollment 协议）。
3. A 用 `EZAGENT_TOKEN=T` 对 `session://W1/<id>` 派发 `chat.send`。
4. 派发通过：
   - `authz_check`：T 的 `workspace_uri` 与目标 workspace 匹配。
   - `cross_workspace_check`（Invocation §5.6）：调用方**当前**workspace 是 W2，但 T 的 `workspace_uri` 是 W1，所以请求在边界内。
5. 目标 session 收到消息；A 的回复流回。

## 预期结果

- Token 主体（U）被记为 `ctx.caller`，**不是** codex agent。
- 审计行标注 "delegated dispatch: A acted as U"。
- 跨 workspace cap 泄漏被阻止：A 不能执行 U 无 cap 的 action。

## 失败模式

- A 持 T 但尝试 U 无 cap 的 action：按 action-axis 检查 `:unauthorized`。
- T 在 A 流中被撤销（场景 03 步骤 10）：下一次派发失败；飞行中不中断（gap，见场景 03 Notes）。
- W2 的 A 持的 token 范围是 W3：派发到 W1 失败 `:cross_workspace_denied`。

## 交叉引用

- 相关 PR：无 — 本场景已预期但尚未接线。
- 相关 SPEC：
  - `2026-05-20-username-and-auth-design.md` — 概念上提到委托 token
  - `2026-05-27-agent-bridge-domain-extraction.md` — codex bridge 管道（auth 前置但非 token-handoff 路径）
- 测试：无
- Open bug / gap：
  - **无 enrollment 协议**：A 如何获得 T 未规约。选项：(a) admin 手工把 T 放入 A 的 config_dir；(b) U 经类 OAuth 流授权 A。
  - **无委托派发审计 shape**：今天 `invocations` 仅记录 `ctx.caller`；无 "acting-as" 记录。需新列或 `metadata` 字段。
  - **无 token 主体跨 workspace cap 检查**：今天 `cross_workspace_check` 看派发进程 workspace，非 token 主体 workspace。需 SPEC。

## 备注

- 本场景是 **codex v2 的前置**（Allen 2026-05-27 — `agent-bridge-pr-g`）。无此，codex agent 只能在其 bridge 注册的 workspace 内操作。
- 这是类别 1 的头号 gap；缺席已在 master README §6 "次级投资" 诚实标记。
