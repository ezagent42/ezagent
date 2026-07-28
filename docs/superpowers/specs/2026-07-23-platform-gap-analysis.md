# 企业自助开通 Beta · 平台功能 Gap 分析（前后端）

> 2026-07-23 · ruihua（designer）· 基于 PR #1436 产品计划 + 服务蓝图
> 范围：**beta P0（G4+G5）** + 最低要求的 backlog 文档化（G3）
> 受众：ruihua + 研发（zyli）+ Allen

---

## §1 Gap 总览矩阵

```
                     Admin 侧           Founder/Member 侧     平台基础设施
                     ─────────          ─────────────────     ────────────
G4 Agent 凭证就绪    配置 UI（新）       状态感知（改）         cap-signing（新）
G5 错误机制          通知中心（改）       消息卡片（新）         ErrorMatcher（新）
                     Layer 2 修复入口    Layer 1/2/3 交互     ErrorRenderer（新）
backlog 身份感知     —                  workspace 标识（改）    —
```

---

## §2 Admin 侧 Gap

| # | Gap | 类型 | 优先级 | 说明 |
|:--|:--|:--|:--|:--|
| A1 | **Agent 凭证配置 UI** | 前端（新） | G4 阻塞 | Admin 在何处、以何种方式为 workspace agent 配置凭证？当前仅 CLI，beta 需要 UI。具体形态取决于托管 agent 架构 |
| A2 | **Workspace provisioning 流程扩展** | 后端（改） | G4 阻塞 | `Provisioning.create_agent/3` 需扩展以支持托管凭证注入。当前 agent 创建后需手动配 key |
| A3 | **cap-signing 集成：签发 agent:key:write** | 后端（新） | G4 阻塞 | entity-caps 在 workspace 创建时自动签发 cap 给 founder。依赖 cap-signing 实现线 |
| A4 | **通知中心 — Layer 2 修复提醒渲染** | 前端（改） | G5 | world_live 需渲染 admin 通知卡片：「哪个 workspace / agent / 错误 / 谁发起的 / 修复入口」 |
| A5 | **通知中心 — 修复完成回执** | 后端（新） | G5 | Admin 修复完成后，系统自动通知发起提醒的 user。触发点：修复操作成功 → `Notifications` broadcast |

---

## §3 Founder/Member 侧 Gap

| # | Gap | 类型 | 优先级 | 说明 |
|:--|:--|:--|:--|:--|
| F1 | **Agent 状态感知** | 前端（改） | G4 | agent 列表需显示「凭证未就绪」/「就绪」状态（当前仅 UUID + flavor）。与 G6（agent 名称化）有重叠但 beta 可先做状态指示 |
| F2 | **Workspace 身份标识** | 前端（改） | G3 文档化 | world 侧边栏/header 显示 workspace 名称 + 用户角色（如「Acme Corp · Founder」）。最低感知要求 |
| F3 | **错误消息卡片 — 结构化渲染** | 前端（新） | G5 | 新增消息卡片组件：显示「发生了什么 + 影响 + 行动入口（按钮/链接/修复者名称）」，替代通用道歉文案 |
| F4 | **错误消息卡片 — Layer 1 修复链接** | 前端（新） | G5 | 卡片内按钮跳转到对应修复页（如配额管理、Agent 配置） |
| F5 | **错误消息卡片 — Layer 2 发送提醒** | 前端（新） | G5 | 卡片内「发送提醒给 <name>」按钮 → 点击 → 确认 toast → 通知 admin |
| F6 | **错误消息卡片 — Layer 3 兜底消息** | 前端（新） | G5 | 显示「此问题已自动登记（登记号 #N），团队会跟进处理」 |

---

## §4 平台层 Gap（基础设施）

| # | Gap | 类型 | 优先级 | 说明 |
|:--|:--|:--|:--|:--|
| P1 | **ErrorCode 注册表模块** | 后端（新） | G5 | 数据定义模块：错误码 schema、首批 24+6 条注册。位置待 D1 裁定（core vs domain_agent） |
| P2 | **ErrorMatcher** | 后端（新） | G5 | `match/1`：`{:error, reason}` → 错误码 + category + 修复路径 |
| P3 | **ErrorRenderer** | 后端（新） | G5 | 根据错误码 + 当前用户权限 → 判断 Layer 1/2/3 → 生成消息卡片 data |
| P4 | **Layer 3 自动登记** | 后端（新） | G5 | 错误码未注册 → 系统自动创建 issue（GitHub Issue / DB 记录）含错误码 + workspace + 时间戳 |
| P5 | **world_live 错误消息渲染** | 后端（改） | G5 | `handle_info({:error_message, ...})` → push 到前端渲染结构化消息卡片。当前 world_live 无此路径 |
| P6 | **cap-signing 就绪状态** | 后端（依赖） | G4 阻塞 | cap-signing spec 已 SOUND（7 轮评审通过），实现排期中。Beta G4 的硬依赖 |

### 实施优先级排序

```
P0（阻塞 beta）
  P6 cap-signing 就绪
  P1 ErrorCode 注册表
  P2 ErrorMatcher
  P3 ErrorRenderer

P1（G5 核心链路）
  P5 world_live 错误渲染
  F3/F4/F5/F6 消息卡片组件
  A4 通知中心 Layer 2 渲染

P2（G5 完整链路）
  P4 Layer 3 自动登记
  A5 修复完成回执

P3（G4 Admin 侧 + 最低感知）
  A1 Agent 凭证配置 UI
  A2 Workspace provisioning 扩展
  A3 cap-signing 集成
  F1 Agent 状态感知
  F2 Workspace 身份标识（G3 文档化）
```

---

## §5 已就绪（机制存在，beta 不新建）

| 机制 | 位置 | 覆盖的 Gap |
|:--|:--|:--|
| `Workspace.create/2` + `Store` | `workspace.ex` + `store.ex` | A2 部分（workspace 创建 OK，需扩展 provisioning） |
| `Workspace.add_member/3` | `workspace.ex` | member 管理后端 OK |
| `Workspace.Invites` (mint/list/revoke) | `invites.ex` | 邀请机制后端 OK |
| `WorkspaceUserAdmin` behavior | `workspace_user_admin.ex` | 用户管理 cap 体系 OK |
| `Ezagent.Notifications` PubSub | `notifications.ex` | Layer 2 通知通道 OK |
| `CredentialStatus` 返回格式 | `credential_status.ex` | 结构化错误消息参考格式 OK |
| `world_live` 站内通知渲染 | `world_live.ex` | Layer 2 通知可走同一条渲染链路 |
| `Router.dispatch_error` 类型 | `router.ex:57-68` | 错误码注册的框架层来源 OK |
| Agent `{:error, reason}` 约定 | 所有 `handle_<action>/2` | 错误码匹配的输入源 OK |

---

## §6 待 Lead 裁定的决策

| ID | 决策 | 影响 |
|:--|:--|:--|
| D1 | 错误码注册表放 `ezagent_domain_agent` 还是 `ezagent_core`？ | P1 模块位置 |
| D2 | Beta 第一批注册 2 条（最小路径）还是全部 24 条？ | G5 实施范围 |
| D3 | 渲染链路改造范围：仅后端改 vs 新建前端消息卡片组件？ | G5 前后端分配 |
