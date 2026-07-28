# Beta 企业自助开通 · 服务蓝图（角色泳道）

> 2026-07-23 · ruihua（designer）· 基于 PR #1436 产品计划
> 范围：**beta P0（G4+G5）** — admin 手动开通 workspace → agent 凭证就绪 → agent 回复 + 可行动错误态
> 受众：ruihua + 研发（zyli）+ Allen

---

## §1 前置条件（beta 开始时已就绪）

以下机制已存在、不在 beta 交付范围，但蓝图开始前需声明：

```
Admin 通过 CLI 完成：
  mix ezagent.workspace.create "acme-corp"
  mix ezagent.workspace.add_member acme-corp user://founder
  mix ezagent.agent.create acme-corp --flavor claude
  mix ezagent.invite mint acme-corp --for user://founder

结果：
  ✓ workspace://acme-corp 已创建，DB 有记录
  ✓ founder 已是 workspace member
  ✓ agent 已创建（但凭证未就绪 — 等 G4/cap-signing）
  ✓ 邀请码已生成，可发给 founder
```

| 已有机制 | 位置 | beta 是否改动 |
|---------|------|:--:|
| `Workspace.create/2` | `workspace.ex:63` | 不改 |
| `Workspace.add_member/3` | `workspace.ex:128` | 不改 |
| `Provisioning.create_agent/3` | `provisioning.ex:53` | 不改 |
| `Workspace.Invites.mint/3` | `invites.ex` | 不改 |
| `registration_open` / `invite_code` | identity domain | 不改（UI 缺口 → backlog G1/G2） |
| `WorkspaceUserAdmin` behavior | `workspace_user_admin.ex` | 不改 |

---

## §2 角色泳道蓝图 — 正常流（beta 核心闭环）

### 阶段 2.1：Founder 接受邀请 → 首次登录 → 进入 workspace

```
Admin                Founder              ezagent 平台
│                    │                    │
│  发送邀请链接       │                    │
│──────────────────→│                    │
│                    │  点击链接           │
│                    │  完成登录           │
│                    │──────────────────→│
│                    │                    │  验证 invite_code
│                    │                    │  关联 user → workspace
│                    │                    │
│                    │  进入 workspace    │
│                    │←──────────────────│
│                    │                    │
│                    │  看到 agent 列表   │
│                    │  [Claude Agent #1] │
│                    │  status: 凭证未就绪 │
│                    │                    │
```

| Step | Admin | Founder | ezagent 平台 |
|:--|:--|:--|:--|
| 2.1.1 | 将邀请链接发给 founder（微信/邮件/飞书） | — | `invite_code` 已生成，与 workspace + user 绑定 |
| 2.1.2 | — | 点击邀请链接，进入登录页 | 验证 invite_code 有效性 |
| 2.1.3 | — | 完成登录（已有账号则登入，无账号则注册） | 关联 user → workspace，写入 `member_uris` |
| 2.1.4 | — | 进入 world 界面，看到 workspace 入口 | Workspace Kind 已 spawn，Loader 从 DB rehydrate |
| 2.1.5 | — | **当前缺口：** world 界面无 workspace 身份标识 | 平台有 workspace 数据但未渲染到前端 |

> **Gap 标注（2.1.5）：** G3（文档化 workspace 身份）虽在 backlog，但 beta 体验最低要求是用户能感知自己属于哪个 workspace。当前 world 侧边栏/header 无 workspace 名称 + 角色显示。

### 阶段 2.2：Agent 凭证就绪（G4，硬依赖 cap-signing）

```
Admin                Founder              ezagent 平台              外部依赖
│                    │                    │                        │
│                    │                    │  cap-signing 就绪      │
│                    │                    │  签发 agent:key:write  │← cap-signing 线
│                    │                    │  agent 凭证就绪         │
│                    │                    │                        │
│  （TBD）配置凭证    │                    │                        │
│  或平台自动注入     │                    │                        │
│                    │                    │                        │
│                    │  agent 状态变「就绪」│                       │
│                    │←──────────────────│                        │
│                    │                    │                        │
```

| Step | Admin | Founder | ezagent 平台 | 外部依赖 |
|:--|:--|:--|:--|:--|
| 2.2.1 | — | — | **cap-signing 就绪** → entity-caps 给 founder 签发 `agent:key:write` cap（scope: workspace） | cap-signing 实现线 |
| 2.2.2 | **（TBD）** Admin 在 provisioning 时配置 agent 凭证，或平台自动注入 | — | 凭证由平台托管，agent 关联到共享的真实服务 agent | 托管 agent 分身架构（决策 ③ 单独立项） |
| 2.2.3 | — | founder 刷新或进入 workspace → agent 状态从「凭证未就绪」变为「就绪」✅ | `CredentialStatus` 返回就绪状态 | — |

> **Gap 标注（2.2.2）：** Admin 如何配置 agent 凭证——具体交互形态取决于托管 agent 架构设计。当前无 UI，Admin 可能需要 CLI 或独立配置页。

### 阶段 2.3：Founder/Member 发消息 → Agent 正常回复

```
Founder/Member       ezagent 平台
│                    │
│  发消息：「你好」   │
│──────────────────→│
│                    │  Router.dispatch/1
│                    │  → Agent 执行 → LLM
│                    │
│  Agent 回复        │
│←──────────────────│
│                    │
│  ✓ 核心闭环验证通过 │
│                    │
```

| Step | Founder | Member | ezagent 平台 |
|:--|:--|:--|:--|
| 2.3.1 | 选择 agent → 输入消息 → 发送 | — | `Router.dispatch/1` → Agent 执行 |
| 2.3.2 | 看到 agent 正常回复 ✅ | — | Agent → LLM → 返回结果 |
| 2.3.3 | Admin 添加 member（CLI）→ member 同流程 | 登录 → 进入 workspace → 发消息 → agent 回复 ✅ | 复用同一 dispatch 链路 |

> **✓ 核心闭环验证点。** 此步通过 = beta 交付标准达成。

### 阶段 2.4：Member 侧补充（Admin 加人后）

| Step | Admin | Member | ezagent 平台 |
|:--|:--|:--|:--|
| 2.4.1 | `mix ezagent.workspace.add_member acme-corp user://zhangsan` | — | workspace member 列表更新 |
| 2.4.2 | 发送邀请链接给 member | — | invite_code 生成 |
| 2.4.3 | — | 同 2.1 流程：点击链接 → 登录 → 进入 workspace | 复用 founder 邀请链路 |
| 2.4.4 | — | 看到 agent 列表 → 发消息 → agent 回复 | 复用 dispatch 链路 |

---

## §3 角色泳道蓝图 — 错误态（G5）

### G5 三层错误处理架构（复述产品计划 §Blueprint）

```
用户遇到错误
    │
    ▼
系统匹配错误码（ErrorMatcher.match/1）
    │
    ├─ Layer 1: 用户可自修 → 消息卡片含直达修复链接
    │   条件：有注册修复路径 + 用户有对应权限
    │   例：founder 遇到 quota_exhausted → 跳转配额管理页
    │
    ├─ Layer 2: 需他人修复 → 指名谁可以修 + 一键发送提醒
    │   条件：有注册修复路径 + 用户无权限
    │   例：普通 member 遇到 agent_credential_missing → 「请联系 workspace founder」
    │
    └─ Layer 3: 兜底 → 系统自动登记 issue
        条件：错误码未注册修复路径 / 路径不可用
        例：未注册错误 → 系统记录（错误码 + workspace + 时间戳）→ 用户无操作
```

### Layer 1 — 用户可自修

```
User                 ezagent 平台
│                    │
│  发消息             │
│──────────────────→│
│                    │  Agent 执行失败
│                    │  ErrorMatcher.match → 命中
│                    │  检查权限 → 用户有权限
│                    │
│  消息卡片           │
│  · 发生了什么       │
│  · 影响             │
│  · [修复按钮]       │
│←──────────────────│
│                    │
│  点击「修复」       │
│──────────────────→│
│                    │  跳转修复页 → 修复完成
│                    │
│  ✓ 确认            │
│←──────────────────│
│                    │
│  发消息 → 正常回复  │
│                    │
```

| Step | User | ezagent 平台 |
|:--|:--|:--|
| E1.1 | 发消息 | Agent 执行失败（如 `quota_exhausted`） |
| E1.2 | — | `ErrorMatcher.match({:error, :quota_exhausted})` → 命中注册表 |
| E1.3 | — | `ErrorRenderer.render` 检查当前用户权限 → 有权修复 → 渲染 Layer 1 消息卡片 |
| E1.4 | 看到消息卡片：「**API 配额已用完** / Agent 暂时无法回复 / [升级配额]()」 | — |
| E1.5 | 点击「升级配额」→ 跳转修复页 → 完成操作 | 系统即时校验 → 返回 ✓ 确认 |
| E1.6 | Agent 状态自动更新 → 发消息 → 正常回复 ✅ | Agent 恢复 |

### Layer 2 — 需他人修复

```
Member               ezagent 平台                    Admin/Founder
│                    │                               │
│  发消息             │                               │
│──────────────────→│                               │
│                    │  ErrorMatcher.match → 命中    │
│                    │  用户（member）无修复权限      │
│                    │                               │
│  消息卡片           │                               │
│  · 发生了什么       │                               │
│  · 谁可以修         │  站内通知 ──────────────────→│
│  · [发送提醒]       │                               │  收到通知
│←──────────────────│                               │  · workspace / agent
│                    │                               │  · 错误 / 发起人
│  确认：「已通知」    │                               │  · [前往配置]
│←──────────────────│                               │
│                    │                               │  点击 → 修复页
│                    │                               │  完成修复
│                    │  回执 ←──────────────────────│
│  收到回执 ✅        │                               │
│←──────────────────│                               │
│                    │                               │
```

| Step | User | ezagent 平台 | Admin/Founder |
|:--|:--|:--|:--|
| E2.1 | 发消息 | Agent 执行失败（如 `agent_credential_missing`） | — |
| E2.2 | — | `ErrorMatcher.match` → 命中 → 当前用户（member）无修复权限 | — |
| E2.3 | — | 渲染 Layer 2 消息卡片 + 站内通知 | — |
| E2.4 | 看到消息卡片：「**Agent 未配置凭证** / 无法调用 AI 模型 / 请联系 workspace founder 陈瑞华 / [发送提醒]()」 | — | — |
| E2.5 | 点击「发送提醒」 | `Notifications` PubSub 广播 | — |
| E2.6 | 看到确认：「已通知陈瑞华」 | — | 收到通知：「Acme Corp / Claude Agent #1 / Agent 未配置凭证 / 张三请求修复 / [前往配置]()」 |
| E2.7 | — | — | 点击通知 → 跳转配置页 → 完成修复 |
| E2.8 | 收到回执：「陈瑞华已修复 Agent 未配置凭证」✅ | 系统自动发回执 | — |

### Layer 3 — 兜底 · 系统自动登记

```
User                 ezagent 平台                    团队
│                    │                               │
│  发消息             │                               │
│──────────────────→│                               │
│                    │  ErrorMatcher.match → 未命中  │
│                    │  自动登记 issue                │
│                    │  (错误码/workspace/时间戳)     │
│                    │                               │
│  兜底消息           │                               │
│  · 发生了什么       │                               │
│  · 已登记 #N        │                               │
│←──────────────────│                               │
│                    │  进入 backlog ───────────────→│  负责人排查
│                    │                               │  补充错误码注册
│                    │                               │
```

| Step | User | ezagent 平台 | 团队 |
|:--|:--|:--|:--|
| E3.1 | 发消息 | Agent 执行失败，错误码未注册修复路径 | — |
| E3.2 | — | 系统自动登记 issue（含错误码、workspace ID、agent URI、时间戳） | — |
| E3.3 | 看到兜底消息：「**Agent 执行时遇到错误** / 此问题已自动登记（登记号 #N），团队会跟进处理」 | — | — |
| E3.4 | — | — | 负责人排查 → 补充错误码注册 → 后续同类走 Layer 1/2 |

---

## §4 情绪曲线

| Touchpoint | 角色 | 起点 | → | 终点 |
|:--|:--|:--|:--|:--|
| 收到邀请链接 | Founder | 😐 被动等待 | 收到链接 | 😊 有人管 |
| 首次登录进入 workspace | Founder | 😊 | 看到 agent 列表 | 😐 不确定下一步 |
| 看到 agent「凭证未就绪」 | Founder | 😐 | 不能立刻用 | 😤 卡住（G4 未就绪前） |
| cap-signing 就绪 → agent 可用 | Founder | 😤 | 切换为就绪 | 😊 顺利 |
| 首次发消息 → agent 正常回复 | Founder | 😊 | 成功 | 🎉 核心闭环达成 |
| Member 加入 → 同样发消息成功 | Member | 😐 | 重复 founder 路径 | 😊 能用了 |
| 遇到错误 Layer 1（可自修） | User | 😤 困惑 | 看卡片 → 点击修复 → 好了 | 😊 自己解决 |
| 遇到错误 Layer 2（需他人） | Member | 😤 困惑 | 知道找谁 → 一键通知 → admin 修好 | 😌 有人管 |
| 遇到错误 Layer 3（兜底） | User | 😤 困惑 | 虽然没修好 → 但已登记 → 有人会跟 | 😐 不沉默 |
