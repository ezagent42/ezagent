# 企业自助开通 workspace：产品化计划

> 2026-07-16 · ruihua（designer）· **v3（结构重构 + §0 对齐）**
> 基于 Allen 的工程缺口清单（PR #1427）逐条撰写用户旅程、验收标准与优先级排序。
> **v3 变更：** beta（G4+G5）提至 §3；backlog（G1-G3）→ §4；post-beta（G6-G10）→ §5。
> 每条 backlog/post-beta 缺口标注**触发条件**——什么情况下重新考虑处理。
>
> **信息来源：** 本计划的事实基础（现状证据、代码位置、冷启动实测结果）全部来自
> Allen 的缺口清单（基于 main 分支 commit `eb2b56a88` 的冷启动实测 + 静态代码核查）。
> 未独立验证代码现状；如果缺口清单有过时之处，本计划会继承。

---

## §0 Allen 决策修订（2026-07-16，lead）— 覆盖下方优先级，请据此重排

> 本节由 lead 直接补入，记录 Allen 对本计划 7 项产品决策的裁定。**下方各缺口以本节为准**。

1. **workspace 创建 = admin 建后拉人（beta）。** founder 注册即得 workspace 仍作为**任务**保留，但**降为非 P0（backlog）**。→ **G1（注册开关）/G2（邀请码 UI）/G3（workspace 创建 UI）自助闸门整体移出 beta 的 P0**（beta 用 admin 手动开通+拉人）。
2. **每用户 own ≤1 workspace，可被加入多个。** → G3 收敛为「文档化单-own 行为」，不做多-workspace 创建 UI。
3. **Agent/Key 模型 = 托管 agent（不是让外部企业自带 key）。** 路线：「一个 agent 服务多企业」，**实施上每个企业 workspace 里放一个 agent 分身（fork/clone），后端数据关联到共享的真·服务 agent**（保持每-workspace 独立 agent 实体、不破跨-workspace 隔离；底层共享）。→ **这是一条新的架构主线**（对接 agent-clone / domain.agent 原语 + cap-signing 的凭证归属），应单列，不再是「founder 自配自己的 key」那种 BYOK 形态。BYOK/登录仅用于**内部开发者**。
4. **G4 不做 stub_grant，等 cap-signing 落地**（cap-signing 已 SOUND、7 轮评审通过、实现排期中）→ founder key 配置走正式 cap 路径。
5. **G1/G2 是 UI 缺口，机制已存在。** 后端 `registration_open` + `registration_require_invite` + `invite_code` + `mix ezagent.invite` **均已实现**——缺的只是开关 UI / 邀请 UI / 关门页出口，**机制不用重造**。beta 用**邀请制**。
6. **G5 = 建面向用户的可行动失败态 surface（"缺 key，找 admin"）。** 现状：`credential_status` 只面向 owner/admin，终端用户只得通用道歉；**没有通用可配置的用户侧报错机制**。→ G5 顺带做成**通用可配置错误机制**（把结构化失败态透给用户）更有价值。
7. **beta 范围 = admin 手动开通 + 只验「配 key → agent 回复」核心价值闭环。** 与 ezagent 现有的开发自举一致——beta = 把自举那条路对外 dogfood 一遍，复用同一套机制、不新造。

**重排后的 beta P0 实质** = 决策 6 的最小闭环（admin 开通 → 配 key〔待 cap-signing〕→ agent 回复）；G1/G2/G3 自助化推到「真要规模化自助」阶段；决策 3 的托管-分身架构单独立项。

---

## §1 用户画像与场景前提（按 §0 Allen 决策修订）

| 维度 | 修订前（v1） | **修订后（v3，§0 裁定）** |
|------|------------|--------------------------|
| **目标用户** | 企业 founder / 浏览器冷启动、零工程师 | **beta：被 admin 邀请加入 workspace 的企业用户。** workspace 由 admin 手动创建并拉人（决策 ①） |
| **Agent/Key 模型** | founder 自配 Anthropic/OpenAI key（BYOK） | **托管 agent**：一 agent 服多企业，每 workspace 一个分身。BYOK 仅内部开发者（决策 ③） |
| **注册方式** | 开放注册 or 邀请制（未定） | **beta 邀请制**。`registration_open`/`invite_code` 机制已存在，只缺 UI（决策 ⑤） |
| **成功定义** | 不靠工程师走完「注册 → 配 key → agent 回复」 | **beta：admin 手动开通 workspace → cap-signing 就绪后 agent 凭证就绪 → agent 回复**（决策 ⑦） |
| **已验证可自助** | 注册表单、建 session、选模板、消息路由、公开页 | 同左，但这些都不在 beta 范围——beta 只验核心闭环 |

---

## §2 缺口总览

| 阶段 | 优先级 | 缺口 | 一句话 | 依赖 |
|------|--------|------|--------|------|
| **beta（本次交付）** | P0 | G4 agent 凭证就绪 | 凭证就绪是 agent 可用的前提 | cap-signing 线 |
| | P0 | G5 可行动失败态 surface | 用户遇到错误时知道缺什么、找谁 | G4 |
| **backlog** | — | G1 注册开关 UI | 机制已存在，缺 UI | 无 |
| | — | G2 邀请码 UI | 机制已存在，缺 UI | 无 |
| | — | G3 workspace 创建 UI | 文档化单-own 即可 | 无 |
| **post-beta** | P1 | G6 UI 可读性 | UUID/atom/404/矛盾提示 | 无 |
| | P1 | G7 onboarding 向导 | 注册后无引导 | G4 |
| | P2 | G8 KB 导入 UI | 真实数据进不来 | 无 |
| | P2 | G9 企业用户文档 | 无自助文档 | 无 |
| | P2 | G10 E2E CI 锁定 | 防回退 | 前序缺口 |
| **单独立项** | — | 托管 agent 分身架构 | 决策 ③，非本计划范围 | agent-clone / domain.agent |

> **产能参考：** beta P0（G4 + G5）不是纯 UI 工作——G4 等 cap-signing 实现（排期中），G5 是新建通用错误 infrastructure。排期由 lead 统筹。

---

# ─── beta（本次交付）───

## G4: agent 凭证就绪 — 走 cap-signing 正式路径

**优先级:** beta P0 | **依赖:** cap-signing 线（硬依赖，不降级）

> **§0 裁定（决策 ③④）：** BYOK/登录仅内部开发者。外部企业用**托管 agent**——一 agent 服多企业、每 workspace 一个分身，平台管理凭证。**G4 不做 stub_grant**，等 cap-signing 落地后走正式 cap 路径。cap-signing spec 已 SOUND（7 轮评审通过），实现排期中。

### 现状（用户视角）

当前 agent 需要有效凭证才能调用 AI 模型。凭证管理权限（`agent.api_key.put`）走 capability 而非 role check——cap-signing 就绪前，founder 无合法的 cap 凭证，访问 Agent Keys 页面返回 `:unauthorized`。**理想模型下**（决策 ③），外部企业用户不需要自行获取或粘贴 key——agent 凭证由平台托管，但托管所需的 cap 授权链路同样依赖 cap-signing。

### Happy path（cap-signing 就绪后）

> **注意：** 托管 agent 模型下 agent 凭证就绪的具体交互形态，取决于决策 ③ 的 agent 分身架构设计——凭证可能由平台自动注入，也可能由 admin 集中配置。以下旅程描述的是 **cap-signing 就绪后、founder 有 `agent:key:write` cap 时的最小交互**，具体 UI 形态待托管 agent 架构设计确定后对齐。

**Step 1 — Workspace 创建时自动授权。** Admin 创建 workspace → entity-caps 给 founder 签发 `agent:key:write` cap（scope: workspace）。此步在 cap-signing 实现中完成，对用户透明。

**Step 2 — Agent 凭证就绪。** Workspace 中的 agent 分身已关联平台托管的 API 凭证（由 admin 在 workspace provisioning 时配置，或平台自动注入——具体机制取决于决策 ③ 的 agent 分身架构）。

**Step 3 — Agent 可用。** founder 进入 workspace → agent 状态为「就绪」→ 发送消息 → agent 正常回复。

**成功终点：** cap-signing 落地 + 托管 agent 凭证就绪后，founder 进入 workspace 即可直接使用 agent，无需自行获取或粘贴 key。

### 验收标准

- [ ] AC1: cap-signing 实现后，founder 持有 `agent:key:write` cap（由 entity-caps 在 workspace 创建时签发）
- [ ] AC2: Agent 凭证由平台/管理员配置（非 founder 自行粘贴 BYOK），具体交互形态取决于决策 ③ agent 分身架构
- [ ] AC3: founder 进入 workspace 后，agent 状态为「就绪」（凭证已就绪）
- [ ] AC4: founder 发送消息 → agent 正常回复
- [ ] AC5: 非 founder 的 member 无权修改 agent 凭证配置
- [ ] AC6: 冷启动实测：admin 开通 workspace → founder 可直接使用 agent（无需自行获取/粘贴 key）

### 情绪曲线

😤 挫败（有界面却 `:unauthorized`，无法使用 agent）→ 😊 顺利（cap-signing 落地 → agent 凭证就绪 → agent 可用）

---

## G5: 可行动失败态 surface（通用可配置错误机制）

**优先级:** beta P0 | **依赖:** G4（agent 能跑起来，失败态才有意义）

> **§0 裁定（决策 ⑥）：** 现状 `credential_status` 只面向 owner/admin，终端用户只得通用道歉——没有通用可配置的用户侧报错机制。G5 升级为**通用可配置错误机制**：结构化失败态透给用户，新失败 case 只需注册错误码。本节描述「错误码注册表已就绪」之后的产品体验（前期准备工作见 [待办](#g5-待办)）。

### 现状（用户视角）

用户发送消息给 agent，agent 回复一段通用道歉文案（类似「抱歉，我无法处理这个请求」），但不告诉用户为什么、缺什么、去哪修。`credential_status` 仅 owner + ws-admin 可见，普通成员完全没线索。更根本的问题：**整个平台没有一套「错误 → 结构化 → 用户可行动」的机制**——agent 缺凭证、权限不足、网络超时、配额耗尽……每种失败都是同一句道歉。

### Blueprint：角色与职责

| 角色 | 做什么 |
|------|--------|
| **用户**（workspace member） | 遇到错误 → 阅读结构化消息 → 理解发生了什么 + 影响 + 下一步 → 按指引行动 |
| **系统** | 捕获失败 → 匹配错误码 → 渲染结构化消息 → 判断用户权限 → 给出对应行动入口 → 需要时通知 admin |
| **Admin / Founder** | 收到错误通知 → 定位问题 → 修复 → 用户侧错误消除 |
| **兜底（系统自动登记）** | 错误码未注册修复路径 → 系统自动登记 issue（含错误码/workspace/时间戳），用户无操作 |

### 三层错误处理

```
用户遇到错误
    │
    ▼
系统匹配错误码
    │
    ├─ Layer 1: 用户可自修 ──→ 直达修复页面的链接
    │   （有修复路径 + 用户有权限）
    │   例：founder 遇到配额耗尽 → 跳转配额管理页升级
    │
    ├─ Layer 2: 需他人修复 ──→ 指名谁可以修 + 一键发送提醒
    │   （有修复路径 + 用户无权限）
    │   例：普通成员遇到 agent 未就绪 → 「请联系 workspace founder <name>」
    │
    └─ Layer 3: 兜底 ──→ 系统自动登记 Issue
        （错误码未注册修复路径，或路径不可用）
        用户无需操作；系统自动记录并通知团队
```

### Happy path 旅程

**场景 A — 用户可自修（Layer 1）**

**Step A1 — Agent 执行失败。** 用户发消息 → agent 操作失败（如配额耗尽）→ 不走通用道歉。

**Step A2 — 结构化错误消息。** 系统匹配错误码，渲染消息卡片：
- **发生了什么**：「Workspace 的 API 调用配额已用完」
- **影响**：「Agent 暂时无法回复消息」
- **行动入口**：「[升级配额]()」（按钮/链接）

**Step A3 — 用户修复。** 点击链接 → 跳转修复页面 → 完成操作 → 系统即时校验 → 绿色 ✓ 确认。

**Step A4 — Agent 恢复。** Agent 状态自动更新 → 用户再次发消息 → 正常回复。

---

**场景 B — 需他人修复（Layer 2）**

**Step B1 — Agent 执行失败。** 同上。

**Step B2 — 结构化错误消息。** 系统匹配错误码 + 检查当前用户权限 → 用户无权修复 → 渲染消息卡片：
- **发生了什么**：「Agent 未就绪」
- **影响**：「无法处理你的请求」
- **谁可以修**：「请联系 workspace founder 陈瑞华」
- **行动入口**：「[发送提醒给陈瑞华]()」（按钮）

**Step B3 — 发送提醒。** 用户点击按钮 → 系统发送站内通知 → 用户看到确认：「已通知陈瑞华」。

**Step B4 — Admin 收到通知。** Admin 在通知中心看到：
- 哪个 workspace：「Acme Corp」
- 哪个 agent：「Claude Agent #1」
- 什么错误：「Agent 未就绪」
- 谁发起的：「张三 请求修复」
- 行动入口：「[前往 Agent 管理]()」

**Step B5 — Admin 修复。** Admin 点击通知中的链接 → 跳转修复页面 → 完成修复。

**Step B6 — 回执。** 修复完成后，发起提醒的用户张三收到回执：「陈瑞华 已修复 Agent 未就绪问题」。

**Step B7 — Agent 恢复。** Agent 状态更新 → 张三再次发消息 → 正常回复。

---

**场景 C — 兜底：系统自动登记（Layer 3）**

**Step C1 — Agent 执行失败。** 系统匹配错误码 → 该错误码未注册修复路径（或已注册但路径不可用）。

**Step C2 — 系统自动登记 Issue。** 系统直接将此次失败登记为一条 issue（含错误码、workspace ID、agent URI、时间戳），用户无需任何操作。

**Step C3 — 兜底消息。** 消息卡片：
- **发生了什么**：「Agent 执行时遇到错误」
- **影响**：「无法完成你的请求」
- **状态**：「此问题已自动登记（登记号 #N），团队会跟进处理」

**Step C4 — 功能负责人排查。** Issue 进入 backlog → 负责人定位原因 → 补充错误码注册（修复路径 + 谁可以修 + 消息文案）→ 后续同类错误走 Layer 1/2，不再掉到兜底。

### Admin 行为总览

| Admin 动作 | 触发条件 | 界面/入口 |
|-----------|---------|----------|
| 收到修复提醒 | 有 workspace member 发起 Layer 2 提醒 | 通知中心（站内） |
| 查看错误详情 | 点击通知中的链接 | 跳转到对应修复页面 |
| 执行修复 | 在修复页面完成操作 | 各修复页面（Agent 管理、Settings、成员管理等） |
| 修复完成回执 | 修复操作成功 | 系统自动通知发起提醒的用户 |

### 验收标准

**Layer 1（用户可自修）**
- [ ] AC1: agent 失败时（缺凭证 / 权限不足 / 配额耗尽 / 网络超时），回复为结构化消息卡片（含「发生了什么 + 影响 + 行动入口」），非通用道歉
- [ ] AC2: 当前用户有权限修复时，行动入口为直达修复页面的链接，点击可跳转
- [ ] AC3: 用户修复完成后，agent 状态自动更新，无需刷新页面

**Layer 2（需他人修复）**
- [ ] AC4: 当前用户无权限修复时，消息指名谁可以修（如「workspace founder <name>」）
- [ ] AC5: 「发送提醒」按钮可点击，点击后 admin 收到站内通知（最小闭环；飞书/邮件为后续增强）
- [ ] AC6: Admin 的通知含：workspace 名、agent 名、错误描述、发起人、直达修复页的链接
- [ ] AC7: Admin 修复完成后，发起提醒的用户收到回执

**Layer 3（兜底 — 系统自动登记）**
- [ ] AC8: 错误码未注册修复路径时，系统自动登记 issue（含错误码、workspace、agent URI、时间戳），用户无需操作
- [ ] AC9: 兜底消息告知用户「此问题已自动登记（登记号 #N），团队会跟进处理」

**通用**
- [ ] AC10: 错误消息为中文（beta 范围）
- [ ] AC11: 冷启动实测：普通成员在 agent 失败时能理解发生了什么 + 知道下一步怎么做（自修 / 找谁 / 系统自动登记）

### 情绪曲线

| 场景 | 起点 | → | 终点 |
|------|------|---|------|
| A（可自修） | 😤 困惑 | → 明白缺什么 → 点击修复 → agent 好了 | 😊 自己解决 |
| B（需他人） | 😤 困惑 | → 知道找谁 → 一键通知 → admin 修好了 | 😌 有人管 |
| C（兜底） | 😤 困惑 | → 虽然暂时修不了 → 但系统已自动登记 → 有人会跟进 | 😐 至少不沉默 |

### G5 待办

- [ ] **SOP 文档**（另建）：错误码注册流程、消息文案撰写规范、链路测试指南。目标：新功能上线时，功能负责人按 SOP 即可补充错误码注册表
- [ ] **beta 阶段错误用例收集**：从现有代码中梳理已知的失败路径（`credential_status`、`:unauthorized`、validation errors、timeout 等），作为第一批注册的错误码
- [ ] **G5 与 G6 痛点 E 的重叠**：G6 痛点 E（错误裸 atom 直出 UI）在 G5 通用错误机制落地后自然解决——错误消息统一走结构化渲染，不再有裸 atom。G6 启用时该痛点可直接跳过

---

# ─── backlog（规模化自助阶段启用）───

> **触发条件：** 以下 G1/G2/G3 的机制均已存在（`registration_open` / `invite_code` / `mix ezagent.invite`），只缺 UI。
> 当平台从「beta 邀请制」转向「开放企业自助注册」时，重新考虑处理。典型信号：
> - 有非内部企业的外部用户开始使用平台，且 admin 手动拉人的频率超过可承受范围
> - 平台需要公开展示注册入口（如官网、marketplace）
> - lead 明确将「规模化自助」纳入周目标

## G1: 注册开关无 UI

**优先级:** backlog | **依赖:** 无 | **触发条件:** 平台从 beta 邀请制 → 开放自助注册

> **§0 裁定（决策 ①⑤）：** beta 走邀请制，workspace = admin 手动建后拉人。`registration_open` / `registration_require_invite` 机制已存在——只缺 UI，机制不用重造。

### 现状

G1 涉及两个页面、两个角色：

**Admin 侧 — Settings 页面（`/admin/settings`）：** 当前 Settings 页面只有 SMTP 配置，没有 `registration_open` / `registration_require_invite` 开关。`registration_open` 默认值为 `false`。

**用户侧 — 关门页（`/register` 未开放时）：** 用户访问注册页，看到「当前未开放注册。」一行纯文字，没有申请入口、没有邀请码入口、没有联系方式的出口。

### Happy path 旅程（规模化自助阶段启用）

**Admin 操作注册开关（Settings 页面）**

**Step A1 — Admin 进入 Settings。** Admin 登录后进入 `/admin/settings`，在 SMTP 配置之外看到「注册设置」卡片。

**Step A2 — 开启/关闭注册。** `registration_open` 开关（ON/OFF）+ `registration_require_invite` 开关（是否要求邀请码）。开启 → 保存 → 看到确认反馈。

**用户访问注册页（关门页 / 注册表单）**

**Step B1 — 注册开放时。** 用户访问首页/注册页，看到注册表单，可填写信息完成注册。

**Step B2 — 注册关闭时（关门页）。** 关门页不再只是纯文字，改为：
- 「当前暂未开放公开注册」
- 「申请注册」按钮 → 提交邮箱 → 「已收到申请，我们会尽快联系你」
- 或「已有邀请码？」→ 输入邀请码进入注册

### 验收标准（启用时）

- [ ] AC1: `/admin/settings` 页面有 `registration_open` 开关（ON/OFF）
- [ ] AC2: `/admin/settings` 页面有 `registration_require_invite` 开关
- [ ] AC3: 注册开放时，未登录用户看到注册入口
- [ ] AC4: 注册关闭时，关门页显示申请入口 + 邀请码入口
- [ ] AC5: 申请提交后有反馈（弹窗 / toast）

### 情绪曲线

😤 挫败（关门页没出口）→ 😊 满意（有申请入口 / 等开放通知）→ 😊 满意（admin 一键开启注册）

---

## G2: 邀请码仅 CLI

**优先级:** backlog | **依赖:** 无 | **触发条件:** 同 G1 — 平台转向开放自助注册，或 admin 手动 CLI 邀请的频率不可持续

> **§0 裁定（决策 ①⑤）：** beta 邀请制，admin 走 CLI 邀请。`invite_code` + `mix ezagent.invite` 机制已存在——只缺 UI。

### 现状（用户视角）

Admin 通过 CLI 创建 workspace 后，邀请成员只能通过终端命令 `mix ezagent.invite mint`——没有浏览器界面。当需要频繁邀请成员时，CLI 操作成为瓶颈。

### Happy path 旅程（规模化自助阶段启用）

**Step 1 — 进入邀请管理。** founder/admin 在 workspace 设置页（或成员管理页）看到「邀请成员」区域。

**Step 2 — 生成邀请码。** 点击「生成邀请码」→ 系统生成一个邀请码 + 链接 → 显示在界面上，可复制。

**Step 3 — 分享邀请。** 把邀请链接发给同事。链接格式：`https://<instance>/register?invite=<code>`。

**Step 4 — 同事注册。** 同事点开链接 → 注册表单预填邀请码（不可编辑）→ 填写用户名/密码 → 注册成功 → 自动进入同一 workspace。

**Step 5 — 管理邀请码。** 查看「已发出邀请」列表（含状态：待使用 / 已使用 / 已过期），可撤销未使用的邀请码。

**成功终点：** 不再依赖 CLI，纯浏览器完成「生成邀请码 → 发给同事 → 同事加入 workspace」。

### 验收标准

- [ ] AC1: workspace 设置页有「邀请成员」区域，含「生成邀请码」按钮
- [ ] AC2: 生成的邀请码以可复制文本 + 一键复制按钮呈现
- [ ] AC3: 邀请链接在未登录状态下打开，跳转到注册页且邀请码预填
- [ ] AC4: 使用邀请码注册的用户自动进入对应 workspace（无需额外操作）
- [ ] AC5: 邀请码列表显示每条邀请的状态（待使用 / 已使用 / 已过期）
- [ ] AC6: 可撤销未使用的邀请码
- [ ] AC7: 冷启动实测：不靠 CLI，完成邀请成员全流程

### 情绪曲线

😤 挫败（没有界面，终端命令找不到）→ 😊 满意（一键生成 + 复制链接发给同事）

---

## G3: workspace 显式创建无 UI

**优先级:** backlog | **依赖:** 无 | **触发条件:** 产品需要支持一个用户拥有多个 workspace（当前裁定：每人 own ≤1）

> **§0 裁定（决策 ①②）：** 每用户 own ≤1 workspace，可被加入多个。founder 注册即得 workspace 降为非 P0 任务。G3 收敛为「文档化单-own 行为」——不做多 workspace 创建 UI。以下用户旅程仅在产品决策翻转（允许用户创建多个 workspace）后启用。

### 现状（用户视角）

beta 下 workspace 由 admin 手动创建，workspace 与用户的关系（own ≤1、可被加入多个）未在产品界面中传达。用户在 world 界面看不到自己属于哪些 workspace。

### 收窄为文档化（beta 即可做）

在 world 界面中明确显示当前 workspace 名称 + 用户的角色（如「Acme Corp · Founder」）。不需要 UI 创建流程——只需要把已有的 workspace 身份信息可见化。

### Happy path 旅程（仅文档化部分）

**Step 1 — 感知 workspace 身份。** world 侧边栏/header 显示当前 workspace 名称 + 用户角色。用户明确知道「我在哪个 workspace 里」「我是什么角色」。

### 原方案 B（多 workspace UI 创建）— 已由决策 ② 否决

每用户 own ≤1 workspace，不做多 workspace 创建 UI。原方案 B（world 侧边栏 workspace 切换器 + 新建按钮）不再适用。

### 验收标准

- [ ] AC1: world 界面有 workspace 身份标识（header / 侧边栏显示当前 workspace 名 + 用户角色）
- [ ] AC2: 用户明确知道自己在哪个 workspace、是什么角色

### 情绪曲线

😐 无感（不知道自己在哪个 workspace）→ 😊 明确（「Acme Corp · Founder」，有归属感）

---

# ─── post-beta（后续阶段）───

> **触发条件：** beta 核心闭环（admin 开通 → agent 凭证就绪 → agent 回复）验证通过并稳定运行后，按产品优先级依次启动。

## G6: UI 可读性

**优先级:** P1（post-beta） | **依赖:** 无 | **触发条件:** beta 稳定运行，开始有非 admin 的普通用户日常使用

> **§0 裁定（决策 ⑦）：** beta 范围外——beta 期间 admin 可绕过大部分可读性问题（admin 认识 UUID、理解 atom）。

> **与 G5 重叠：** 痛点 E（错误裸 atom 直出 UI）在 G5 通用错误机制落地后自然解决。G6 启用时该痛点可跳过。

### 现状（用户视角）

**痛点 A — Agent 列表裸 UUID。** agent 列表里每个 agent 显示的是 `a1b2c3d4-...` 这样的 UUID，用户无法区分哪个 agent 是干什么的。唯一线索是 `flavor` 列（如 `claude` / `python`）。

**痛点 B — 首登 PAT interstitial 噪音。** 首次登录后弹出 Personal Access Token 管理界面。对不写代码的企业用户来说，PAT 是陌生概念。

**痛点 C — 登录后 Continue 落 404。** 用户在某个页面登录后，点「Continue」跳转到 404。

**痛点 D — 会话名校验矛盾。** 创建会话时，提示文案说「支持中文名称」，但用户输入纯中文名后却被拒绝。

**痛点 E — 错误裸 atom 直出 UI。** 操作失败时，页面显示 `:invalid_session_name` 或 `:unauthorized` 这样的 Elixir atom，而非人类可读的中文错误提示。**（G5 通用错误机制落地后此痛点自然解决）**

### Happy path 旅程

**痛点 A — Agent 可识别**

**Step 1:** 用户进入 agent 列表 → 每个 agent 显示**名称**（而非 UUID）。名称由用户在创建 agent 时指定（如「我的客服助手」），未指定时用 `{flavor} Agent #{序号}`（如「Claude Agent #1」）。

**Step 2:** 列表每行包含：名称、flavor 标签（中文：「Claude 对话」「Python 执行」）、状态指示（就绪 / 未配置凭证 / 离线）。UUID 降级到详情页。

**痛点 B — 首登体验干净**

**Step 1:** 用户注册后首次登录 → 看到 workspace 主界面（agent 列表 / 模板选择），**不弹出 PAT 管理**。

**Step 2:** PAT 管理入口移至 Settings → Developer（或「API 访问」），面向开发者用户。

**痛点 C — Continue 不死路**

**Step 1:** 用户在任意页面点击登录 → 登录成功后 → 跳回**登录前所在页面**（而非固定跳 `/`）。

**Step 2:** 如果原页面不再存在或无权访问 → 跳 `/`，并 toast 说明「原页面已失效，已为你跳转到首页」。

**痛点 D — 校验提示一致**

**Step 1:** 用户创建会话，名称输入框下方实时显示规则：「可包含中文、英文、数字、下划线，2-30 个字符」。

**Step 2:** 输入不符合规则时，输入框变红 + 行内提示具体原因（如「名称至少需要 2 个字符」），而非提交后才弹错误。

**Step 3:** 实际校验规则与提示文案一致（纯中文名被允许）。

**痛点 E — 错误提示人类可读**（G5 落地后自然解决，此处保留作为验收补充）

**Step 1:** 任何操作失败 → 错误提示使用中文，描述「发生了什么 + 建议做什么」。例如 `:invalid_session_name` → 「会话名称不符合规则：可包含中文、英文、数字、下划线，2-30 个字符」。

**Step 2:** 权限错误提示给可行建议：`:unauthorized` → 「你没有权限执行此操作。如需访问，请联系 workspace founder `<name>`。」

### 验收标准

- [ ] AC1: agent 列表显示 agent 名称（非 UUID），可区分不同 agent
- [ ] AC2: 首登后不弹出 PAT interstitial（PAT 入口移至 Settings → Developer）
- [ ] AC3: 登录后「Continue」不落 404（回到登录前页面 or 首页 + toast）
- [ ] AC4: 会话名输入框的提示文案与实际校验规则一致（中文名被正确允许）
- [ ] AC5: 所有面向普通用户的错误提示为中文 + 可行动建议（非 Elixir atom）
- [ ] AC6: agent 列表行含状态指示（就绪 / 未配置凭证 / 离线）

### 情绪曲线

😤 困惑+不信任（UUID、atom、404、矛盾提示）→ 😊 清晰（agent 有名字、错误能看懂、跳转不迷路）

---

## G7: onboarding 向导 + 应用 gallery 缺失

**优先级:** P1（post-beta） | **依赖:** G4 | **触发条件:** 平台开始面向外部企业用户开放，用户不再由 admin 当面引导

> **§0 裁定（决策 ⑦）：** beta 范围外——beta 用户由 admin 手动拉入 + 当面引导，不需要 onboarding 向导。

### 现状（用户视角）

用户进入 workspace 后面对空的 world 界面，没有任何引导。socialware 模板存在（`DefinitionRegistry.list/1` 有 API），但前端没有展示面。

### Happy path 旅程

**Step 1 — onboarding 向导。** 用户首次进入 workspace → 3-4 步向导（每步可跳过）：
- **步骤 1：「创建你的第一个 Agent」。** 展示模板 gallery（卡片式，含名称、描述）。推荐默认模板。
- **步骤 2：「配置 API 凭证」。** 引导到凭证配置页（具体交互取决于托管 agent 架构）。
- **步骤 3：「发送第一条消息」。** 引导到 agent 聊天页，预设欢迎消息。
- **步骤 4：「了解你的 workspace」。** 快速 tour：agent 列表、设置、邀请成员。

**Step 2 — 应用 Gallery。** world 侧边栏有「应用 Gallery」入口 → 浏览可用 socialware 模板 → 一键添加。

**Step 3 — 向导可跳过、可重访。** 每步有「跳过」按钮。完成后在 Settings 中有「重新开始向导」入口。

### 验收标准

- [ ] AC1: 首次进入 workspace 后自动进入 onboarding 向导（含 3-4 步）
- [ ] AC2: 向导步骤 1 展示模板 gallery，至少含 2-3 个可选模板
- [ ] AC3: 每步显示进度指示（如「步骤 2/4」）
- [ ] AC4: 每步有「跳过」按钮
- [ ] AC5: 向导完成后可在 Settings 中重新开始
- [ ] AC6: world 侧边栏有「应用 Gallery」入口
- [ ] AC7: gallery 卡片含模板名称、一句话描述、flavor 标签

### 情绪曲线

😐 空白（面对空界面）→ 😊 引导（一步步知道在做什么）→ 🎉 惊喜（「agent 回复我了！」）

---

## G8: 企业资料/KB 导入无 UI

**优先级:** P2（post-beta） | **依赖:** 无 | **触发条件:** 有企业用户开始在 agent 中使用真实业务场景，demo 数据不够用

> **§0 裁定（决策 ⑦）：** beta 范围外。

### 现状（用户视角）

`kb.ingest` 只能通过 API / MCP 协议逐条提交——没有上传界面、没有批量导入、没有任何 UI 通道。真实业务数据进不来，agent 只能跑 demo 数据。

### Happy path 旅程

**Step 1 — 进入知识库管理。** 用户在 workspace 设置 → 「知识库」→ 看到当前已导入的知识条目列表。

**Step 2 — 添加知识。** 点击「添加知识」→ 选择方式：
- **粘贴文本：** 直接粘贴文字内容 + 标题
- **上传文件：** 拖拽/选择 `.txt` `.md` `.pdf` 文件（单文件或批量）
- **网页链接：** 输入 URL，系统抓取内容

**Step 3 — 导入反馈。** 上传后显示处理状态：解析中 → 已入库（N 条片段）→ 可检索。失败的文件标红 + 原因（格式不支持 / 文件太大 / 内容为空）。

**Step 4 — agent 使用知识。** 在 agent 配置中可选择「关联知识库」→ agent 回复时可检索知识库内容作为上下文。

### 验收标准

- [ ] AC1: workspace 设置中有「知识库」管理页
- [ ] AC2: 支持粘贴文本添加知识（含标题 + 正文）
- [ ] AC3: 支持上传 `.txt` `.md` 文件（单文件 or 批量拖拽）
- [ ] AC4: 上传后有处理状态反馈（解析中 → 已入库 / 失败）
- [ ] AC5: 失败的文件显示具体原因（格式 / 大小 / 内容问题）
- [ ] AC6: agent 可关联知识库，并在回复中使用知识库内容

### 情绪曲线

😐 无从下手 → 😊 便捷（拖拽上传 → agent 能回答业务问题了）

---

## G9: 企业用户文档为零

**优先级:** P2（post-beta） | **依赖:** 无 | **触发条件:** 有外部企业用户开始使用，且出现重复性的使用问题

> **§0 裁定（决策 ⑦）：** beta 范围外。

### 现状（用户视角）

`docs/guide/` 下所有文档面向运营/开发者——IEx 命令、mix task、Elixir 配置。纯浏览器用户遇到问题，能看的文档是 0。

### Happy path 旅程

**Step 1 — 产品内嵌帮助入口。** world 界面右下角有「？」帮助按钮 → 点击弹出帮助面板。

**Step 2 — 帮助内容。** 面向企业用户的文档至少覆盖：
- **「第一天上手」**：创建 agent → 发首条消息（对应 onboarding 向导，作为随时可查的文档版）
- **「常见问题」**：agent 不回复怎么办 / 怎么邀请同事 / 会话和 agent 的关系
- **「错误排查」**：常见错误提示的含义 + 解决方法（对应 G5 错误机制，文档作为补充）

**Step 3 — 文档可被搜索。** 帮助面板顶部有搜索框，输入关键词即时筛选。

### 验收标准

- [ ] AC1: world 界面有产品内嵌帮助入口（如右下角「？」按钮）
- [ ] AC2: 帮助内容覆盖「第一天上手」「常见问题」「错误排查」三个类别
- [ ] AC3: 帮助内容可被搜索（关键词即时筛选）
- [ ] AC4: 帮助内容为中文，面向非技术用户（不含 IEx/mix 命令）
- [ ] AC5: 首次使用用户能看到指向帮助入口的提示

### 情绪曲线

😤 无助（卡住了，找不到任何说明）→ 😊 自助（点 ? → 搜索 → 找到答案 → 自己解决）

---

## G10: 无浏览器级 E2E 锁定

**优先级:** P2（post-beta） | **依赖:** G4+G5 落地后 | **触发条件:** beta 闭环稳定、开始有持续交付的 PR 流

> **§0 裁定（决策 ⑦）：** beta 范围外。E2E 场景改锚 beta 闭环：admin 开通 → agent 凭证就绪 → agent 回复。

### 需要什么（非用户旅程，为工程验收规格）

把 beta 闭环脚本化进 CI：

1. **Admin 开通 workspace → 创建 agent 分身**（验证 workspace provisioning）
2. **Agent 凭证就绪 → 状态变为「就绪」**（验证 G4）
3. **发送消息 → agent 正常回复**（验证核心价值链路）
4. **Agent 执行失败 → 结构化错误消息（含发生了什么 + 影响 + 行动入口）**（验证 G5 Layer 1/2）
5. **未注册错误码的失败 → 系统自动登记 issue**（验证 G5 Layer 3）
6. **登录后 Continue 回到原页面**（验证 G6-C，post-beta 启用）
7. **会话名中文输入 → 创建成功**（验证 G6-D，post-beta 启用）

### 验收标准

- [ ] AC1: CI 中有至少 1 条浏览器级 E2E 测试覆盖 admin 开通 → agent 回复整链
- [ ] AC2: E2E 测试在 PR gate 中运行（非手动触发）
- [ ] AC3: E2E 测试失败时能指出具体哪一步断裂（而非笼统超时）
- [ ] AC4: 测试使用隔离的测试 workspace（不影响生产数据）
- [ ] AC5: beta P0 缺口（G4+G5）每条有至少 1 条 E2E 覆盖其 happy path

### 情绪曲线

（面向团队而非用户）😰 不安（不知道闸门有没有被焊回）→ 😌 放心（每次 PR 自动验证 beta 闭环完整）

---

# ─── 附 ───

## §4 优先级排序说明（按 §0 修订）

### 排序逻辑

v3 排序基于 §0 Allen 的 7 条裁定：**beta 范围 = admin 手动开通 → agent 凭证就绪（cap-signing 正式路径）→ agent 回复**。

| 用户想做的事 | 对应缺口 | beta 状态 |
|-------------|---------|-----------|
| Admin 能开通 workspace 并拉人 | G1/G2/G3 机制已存在，缺 UI | **backlog**（beta 由 admin 手动操作） |
| Agent 凭证就绪，agent 能跑 | **G4 — cap-signing 正式路径** | **beta P0** |
| 遇到失败知道缺什么、找谁 | **G5 — 通用错误机制** | **beta P0** |
| 界面能看懂 | G6 — UI 可读性 | post-beta |
| 导入数据 / 自助文档 / E2E… | G7–G10 | post-beta |

### v1 → v3 关键变化

| v1 假设 | §0 裁定 | 影响 |
|---------|---------|------|
| 企业用户浏览器冷启动自助注册 | beta = admin 手动建 workspace + 邀请制 | G1/G2/G3 移出 beta P0，标 backlog + 触发条件 |
| Founder 自配 BYOK | 托管 agent，一 agent 服多企业、每 workspace 一个分身 | BYOK 仅内部开发者；G4 改 agent 凭证就绪（非 founder 粘贴 key） |
| G4 做 stub_grant 降级 | 不做 stub，等 cap-signing 正式路径 | G4 硬依赖；§7 降级方案标记为废弃 |
| G5 = agent 缺 key 提示 | G5 = 通用可配置错误机制（infrastructure） | 三层错误处理 + admin 行为 + 系统兜底 |
| 10 条缺口 4 批排期 | beta 只含 G4+G5，其余标 backlog/post-beta + 触发条件 | 文档重构为 beta / backlog / post-beta 三大段 |

---

## §5 工程效率参考

v1 的产能估算（人类 1.35 人月/月下界、产品化 ~45%）不再适用于 v3——beta P0 的两条（G4 + G5）都不是纯 UI 工作：
- **G4** 依赖 cap-signing 实现（排期中，不是本计划能估的）
- **G5** 是新建通用错误 infrastructure（无现成机制，需设计 + 实现）

实际排期由 lead 统筹 cap-signing 实现排期 + G5 设计评审后定。

---

## §6 G4 降级方案 — 已废弃

> **§0 裁定（决策 ④）：G4 不做 stub_grant。** 原 v1 的「Founder PAT Auto-Provision + Stub Grant」降级方案被否决。G4 走 cap-signing 正式路径（spec 已 SOUND，7 轮评审通过，实现排期中）。cap-signing 落地前 G4 为硬阻塞。本节仅保留作为决策记录。

v1 降级方案摘要（已否决，仅供参考）：注册时自动生成 workspace-scoped PAT → `agent.api_key.put` 加 `:stub_grant` 分支 → cap-signing 落地后切换。否决理由：cap-signing 已 SOUND 且排期中，不值得为临时路径增加 authz 复杂度。

---

## §7 验证 Checklist

- [ ] beta 段只含 G4 + G5
- [ ] backlog 段（G1-G3）每条标注了触发条件
- [ ] post-beta 段（G6-G10）每条标注了触发条件
- [ ] G4 走 cap-signing 正式路径（不做 stub_grant）
- [ ] G4 不含 BYOK 假设（founder 不粘贴 key）
- [ ] G5 为三层错误处理 blueprint（用户 / 系统 / admin + 兜底）
- [ ] G5 示例不含 BYOK 语言
- [ ] G3 方案 B 已删除（决策 ② 否决）
- [ ] G6 痛点 E 标注了与 G5 重叠
- [ ] G10 E2E 场景锚定 beta 闭环
- [ ] 托管 agent 分身架构单独立项

---

## §8 不在此计划内

| 项 | 原因 |
|----|------|
| G0（bootstrap 断点） | 运营侧缺口，目标用户不是企业用户 |
| 托管 agent 分身架构 | 决策 ③ 单独立项，对接 agent-clone / domain.agent |
| 组织/中枢-成员层级 | 单企业自助不需要（原缺口清单已标注） |
| 计费/配额/运营 dashboard | 归商业化/稳定性轨道 |
| self-host 自助安装器 | 归中枢客户交付轨道 |
| UI 开发实施 | designer track 做产品计划，不写代码 |
| #1388 DealScout 合并 | 等 lead 操作 |

---

## §9 下一步

1. **本计划交 lead 确认** — §0 已由 lead 裁定，本次 v3 完成结构重构 + backlog 触发条件标注 + BYOK 残留清除。确认后可锁版
2. **G4 不单独行动** — 等 cap-signing 实现排期，不发明降级路径
3. **G5 通用错误机制** — 需独立设计评审（错误码注册表 schema + 前端渲染契约 + 首批注册的错误码清单）。另建 SOP 文档（错误码注册流程 + 链路测试指南）
4. **G6 UI 可读性** — post-beta，但痛点 E（错误裸 atom）G5 落地后自然解决；痛点 A-D 可单独和 zyli 讨论
5. **托管 agent 分身架构** — 单独立项，不在本计划内追踪
6. **backlog 缺口** — G1/G2/G3 在「规模化自助」触发条件满足时，按本计划中的用户旅程和 AC 执行
