# Ezagent 架构导览（面向一般读者）

**Status**: 入门导读，不涉及代码细节
**配套**: 同目录 [2026-05-26-architecture-analysis-wser.zh_cn.md](2026-05-26-architecture-analysis-wser.zh_cn.md) 是技术细节版

---

## 1. 一句话：Ezagent 是什么

> **Ezagent 是一套"多 Agent 协同的消息路由运行时"**——把人、AI Agent、外部系统（飞书/Slack/CLI/Web）都抽象成可寻址的"实体"，让一条消息在它们之间按规则被准确、可追溯、可隔离地送达。

它不是一个聊天 App，也不是一个 Agent SDK，而是 **承载多 Agent 协同的基础设施**：
- 谁能和谁说话？（权限）
- 哪些 Agent 在同一个"房间"？（会话）
- 不同租户/团队的数据不会互相污染？（工作空间隔离）
- 重启之后还在不在？（持久化）
- 一条飞书消息怎么变成对一个 cc Agent 的调用？（适配）

这五件事就是它要解决的全部。

---

## 2. 四个基本概念（WSER）

整套系统的"名词表"只有四个核心层级，由小到大、由含到被含：

```
  workspace   ─────  租户/团队的"部署单元"   （= K8s 的 namespace）
      │
      ├── session  ─  一个聊天/任务"房间"     （多个 user + agent 在里面对话）
      │      │
      │      ├── entity (user)  ──  一个真实用户身份
      │      ├── entity (agent) ──  一台 AI Agent（cc/curl/echo/...）
      │      └── resource       ──  房间引用的资产（上传文件等）
      │
      └── ...更多 session
```

每个层级都有一个稳定的"地址"（URI），形如：

| 层 | 地址样例 | 含义 |
|---|---|---|
| Workspace | `workspace://team-alpha` | "团队 Alpha 的部署空间" |
| Session | `session://default/team-alpha/main` | "team-alpha 里 main 这个房间" |
| Entity (user) | `entity://user/team-alpha/alice` | "team-alpha 的 Alice" |
| Entity (agent) | `entity://agent/team-alpha/cc_helper` | "team-alpha 的 cc 风味助手" |
| Resource | `resource://uploads/team-alpha/file-abc` | "team-alpha 上传的 file-abc" |

注意 **workspace 名字直接写在每个地址里**——这是 Ezagent 的核心隔离手段：跨 workspace 的访问必须走专门的授权门，不可能"忘记设置 workspace context"导致数据串。

> 还有一个特殊的 `system://` 用于平台自身的横切（路由表、引导账号等），不归属任何 workspace。

---

## 3. 配方（Templates）：复用与版本

一些层级有"配方"概念——预先定义好结构，可批量实例化：

```
template (配方) ─────────────► instance (实例)
                                 │
   ┌─── AgentTemplate ──── 实例化 ───► entity://agent/... （活的 Agent）
   │     • 工作目录 / 配置
   │     • 风味 (cc / curl / ...)
   │
   └─── SessionTemplate ── 实例化 ───► session://...        （活的房间）
         • 编队 (agent_slots)
         • 路由规则
         • 编排者 (orchestrator)
         • 内容寻址 (@hash)
```

**关键观察**：

- **只有 Agent 和 Session 有"配方"**。User / Workspace / Resource 没有。
  - User 是手工开账号（管理员或注册流程）。
  - Workspace 本身就是顶层，不需要更上的配方。
  - Resource 是数据，靠上传产生。
- **SessionTemplate 是唯一带版本（@hash）的对象**。它像 Git commit：内容相同 → hash 相同；改一处就是新的版本，老房间不受影响。
- **Workspace 里的"配方清单"**：每个 workspace 自带一份 `session_templates` 清单，描述"这个空间一启动应该自动跑哪些房间"——重启后由 Loader 自动重建。

---

## 4. 旁挂能力（Behaviors）：组合而不是继承

Ezagent 不用"类继承"的方式给对象加能力，而是 **"一个对象身上可以挂多个独立能力模块"**：

```
        ┌──────────────────────────────────────────┐
        │   一个 entity://user/.../alice           │
        │                                          │
        │   [身份能力]         [飞书接收能力]      │
        │   • 持有权限          • 接收飞书消息     │
        │   • 显示名            • 绑定 open_id     │
        │                                          │
        │   [API Key 能力]    [密码登录能力]       │
        │   • 申请/吊销         • 设置密码         │
        │                       • 验证             │
        └──────────────────────────────────────────┘
```

每个能力（Behavior）只看自己那一格"抽屉"（slice），互不串门。要让两个能力协调，必须走"再发一条消息"——不能直接读对方的状态。

**为什么这样设计**：插件作者写一个新外部集成（比如接 Slack），只需要写一个"Slack 接收能力"挂到 User 上，不用去改 User 本身。Feishu 集成就是这么接入的——它不引入 `feishu://` 这种独立地址，而是给 User/Session 加一个旁挂能力。

> **核心准则**：插件**永远不能引入新的 URI scheme**。要接外部系统，就在现有的 User/Session 上挂能力。

---

## 5. 一条消息的旅程

不管输入来自哪里（HTTP / 飞书 / CLI / 网页 / MCP），最终都被翻译成同一种"调用请求"，然后过同一条流水线：

```
  外部输入 (HTTP / 飞书 / CLI / Web / MCP)
       │
       ▼
  适配器 (Adapter)
       │   只做两件事：
       │   1. 把外部协议解析成统一的"调用请求"
       │   2. 把结果按原协议回复回去
       ▼
  ┌────────────── 调度流水线 (Dispatch) ──────────────┐
  │                                                   │
  │  ① 找到目标对象（按地址查活跃进程）              │
  │                                                   │
  │  ② ★ 权限检查                                     │
  │     "调用方有没有权限做这件事？"                 │
  │     没有 → 拒绝 (unauthorized)                   │
  │                                                   │
  │  ③ ★ workspace 隔离                              │
  │     "调用方和目标在同一个 workspace？"           │
  │     不在且没有跨空间授权 → 拒绝 (cross_ws_denied)│
  │                                                   │
  │  ④ 参数校验                                       │
  │                                                   │
  │  ⑤ 执行能力（Behavior）                          │
  │                                                   │
  │  ⑥ 状态有变化 → 落盘快照                         │
  │                                                   │
  │  ⑦ 异步审计日志                                   │
  │                                                   │
  └───────────────────────────────────────────────────┘
       │
       ▼
  按"原路返回"通道把结果回给调用方
  （邮箱 / WebSocket / HTTP / MCP / 飞书消息 ...）
```

**关键性质**：

- **只有这一条路径**——任何对象之间通信都走它，没有"快捷方式"。
- **权限和 workspace 隔离是结构性强制的**，绕不过去。
- **失败必须被看见**——给人类的入口（飞书、Web）失败时必须有反馈（emoji、错误提示），不能静默丢消息。

---

## 6. 四道安全网

Ezagent 是 router 不是请求-响应 app，意味着 **接收方可能不存在 / 还没起 / 暂时不能服务**。系统内置四道保险：

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ① 就绪门 (ReadyGate)                                       │
│     每个对象有 "未知 / 未就绪 / 就绪" 三态                  │
│     未就绪时：                                              │
│       同步调用 (call)  → 立即失败（不让调用方傻等）         │
│       异步投递 (cast)  → 进入缓冲队列等就绪                 │
│                                                             │
│  ② 缓冲队列 (PendingDelivery)                               │
│     启动窗口里的异步消息暂存这里，每个对象有上限            │
│     溢出 → 进死信队列 (DLQ)                                 │
│                                                             │
│  ③ 幂等表 (Idempotency)                                     │
│     外部 webhook 重试不会跑两次（"收到即记"）              │
│                                                             │
│  ④ 死信队列 (DLQ)                                           │
│     路由不到 / 缓冲溢出 / 重复触达 → 全部留痕               │
│     永远知道"消息去了哪 / 为啥没到"                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**核心承诺**：一条消息要么被正确处理、要么进 DLQ + 发 telemetry——**绝不会无声地消失**。

---

## 7. 重启之后还在不在？

每个对象明确声明自己的持久化策略：

| 策略 | 谁用 | 行为 |
|---|---|---|
| **`:ephemeral`**（不留） | Workspace 自己、System 平台对象 | 进程死即消失，重启时由 Loader 从 DB 重建 |
| **`:on_change`**（变就存） | Session / User / Agent / Template | 状态一变同步落盘，掉电不丢 |
| **`:periodic`**（定时存） | （目前没人用） | 异步批量写，承受丢一两个事件 |
| **`:on_terminate`**（结束时存） | （目前没人用） | 进程退出时落盘 |

**额外两个持久化层**：

- **消息历史** (`messages` 表)：每条聊天消息独立保存
- **审计日志** (`invocations` 表)：每次调度调用异步记录——什么人在什么 workspace 调用了谁的什么动作

**租户隔离的结构保证**：所有"per 租户"的数据表都强制带 `workspace_uri` 列且不可为空。读数据时按这个字段过滤，写数据时按调用方的 workspace 写入——做不到"忘记加过滤条件"。

---

## 8. 路由策略：三层叠加

一条消息进到一个 Session，可能要发给"全员"，可能要发给"被 @ 的人"，可能要发给某个 User。这个决策由"路由规则"控制，规则按作用域分三层：

```
┌─────────────────────────────────────────┐
│  Global  规则（system://routing/...）   │  ◄── 例：默认 @ 触发 agent
│         在整个集群都生效                │
└─────────────────────────────────────────┘
                  ▼ 叠加
┌─────────────────────────────────────────┐
│  Workspace 规则（workspace://X/...）    │  ◄── 例：本团队额外规则
│         只在某个 workspace 生效         │
└─────────────────────────────────────────┘
                  ▼ 叠加
┌─────────────────────────────────────────┐
│  Session 规则（session://.../X/...）    │  ◄── 例：本房间临时规则
│         只在某个房间生效                │
└─────────────────────────────────────────┘
                  │
                  ▼
        合并 → 展开"魔法令牌" →
           $session_users（房间内的人）
           $mentions（被 @ 的成员）
           $session_members（房间内所有）
                  ▼
        最终的收件人列表 → 逐个投递
```

> **重要**：修改规则本身也是一次正常的调度。要改 workspace 级规则，就给 workspace 发"加规则"消息；要改 session 级规则，就给 session 发——**没有特殊的"管理员通道"**。这让权限检查在每条规则修改上自然生效。

---

## 9. 三层组装：core / domain / plugin

Ezagent 内部代码按 **"两个陌生开发者能不能不撞车地并行写"** 切成三层：

```
   ┌───────────────────────────────────────────────────┐
   │  plugin（可选扩展）                               │
   │  ─────────────────────                            │
   │  • cc / curl / echo / np   — 各种 Agent 风味      │
   │  • feishu                  — 飞书集成             │
   │  • liveview                — 管理网页 UI          │
   │  每个是一个独立 OTP app，可以独立加/拆            │
   └───────────────────────────────────────────────────┘
                          ▲ 依赖
   ┌───────────────────────────────────────────────────┐
   │  domain（必装的一类对象）                         │
   │  ─────────────────────                            │
   │  • chat       —— Session / Agent / 聊天能力       │
   │  • identity   —— User / 身份能力                  │
   │  • workspace  —— Workspace / 启动加载器           │
   │  • external_mirror —— 对外镜像（Feishu/Slack）    │
   │  • ui / pty / python ……                           │
   └───────────────────────────────────────────────────┘
                          ▲ 依赖
   ┌───────────────────────────────────────────────────┐
   │  core（基础原语）                                 │
   │  ─────────────────────                            │
   │  • 地址解析 (URI)                                 │
   │  • 调度引擎 (Dispatch)                            │
   │  • 权限模型 (Capability)                          │
   │  • 持久化 / 审计 / 快照                           │
   │  • 路由 / 就绪 / 缓冲 / 幂等                      │
   │  • 注册表（谁是谁、谁能干啥）                     │
   └───────────────────────────────────────────────────┘
```

**判定规则**："这段代码读的是什么数据？"
- 读通用结构（调度请求、消息、注册表）→ 放 core
- 读插件特定数据（飞书卡片格式、Slack thread_ts）→ 放 plugin
- 读业务概念但不依赖某个插件 → 放 domain

**北极星**：未来的插件作者**不需要碰 core**——他只写一个新的插件 OTP app，声明自己的能力，框架会自动接上。这是这套架构存在的根本理由。

---

## 10. 一张全景图

```
                外部世界
      HTTP    飞书    Slack    CLI    Web    MCP
        │      │       │       │      │      │
        └──────┴───────┴───────┴──────┴──────┘
                       │
                       ▼ 适配器把任何输入翻译成统一请求
        ┌─────────────────────────────────────┐
        │     统一调度流水线 (Dispatch)        │
        │                                     │
        │   找对象 → 检查权限 → 检查 workspace │
        │      → 校验参数 → 执行 → 落盘 → 审计 │
        └─────────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
   业务对象（WSER）              横切基础设施
   ─────────────────             ─────────────
   workspace://                  • 就绪门
       └── session://            • 缓冲 / 死信
            ├── entity (user)    • 路由解析
            ├── entity (agent)   • 审计 / 快照
            └── resource         • 对外镜像 (Feishu/Slack)

       template://    （配方，给 Agent 和 Session 用）
       system://      （平台横切）

                  ── 工程实现分三层 ──
                  core (原语 / 不依赖任何具体业务)
                       ▲
                  domain (必装：聊天、身份、工作空间)
                       ▲
                  plugin (可选：cc、curl、echo、飞书、Web UI ……)
```

---

## 关键设计取舍（一句话原则）

为什么 Ezagent 长成现在这样，背后的设计原则可以浓缩成几句：

| 原则 | 通俗说法 |
|---|---|
| **少发明、多装配** | 能用现成的 Phoenix/OTP 就不要自己造轮子 |
| **单一真相** | 每一条事实只在一处保存，其他都是镜像或缓存 |
| **结构性正确** | 让规则在数据结构里就是对的，而不是靠"记得加过滤" |
| **失败必须被看见** | 给人的入口失败要有反馈；系统内部失败要进死信 |
| **插件作者别碰核心** | 加新功能 = 写一个独立 OTP app，不动 core |
| **干净重建，不留 shim** | 改 URI 形态或 schema 就推倒重建，不留向后兼容补丁 |

---

## 想深入哪一块？

| 想了解 | 看哪儿 |
|---|---|
| 可编辑的可视化图（Excalidraw） | [excalidraw/architecture-primer.excalidraw](excalidraw/architecture-primer.excalidraw) — 在 [excalidraw.com](https://excalidraw.com) 打开 |
| 详细技术映射、模块名、CI gate | [2026-05-26-architecture-analysis-wser.zh_cn.md](2026-05-26-architecture-analysis-wser.zh_cn.md) |
| URI 规范（地址形态、6 scheme、3 段 authority） | [uri-design.md §5](uri-design.md) |
| 完整设计原则（P1-P27） | [.claude/skills/ezagent-developer/references/design-principles.md](../../.claude/skills/ezagent-developer/references/design-principles.md) |
| 17 条架构不变式 + CI gate | [.claude/skills/ezagent-developer/references/architecture-invariants.md](../../.claude/skills/ezagent-developer/references/architecture-invariants.md) |
