# 企业自助开通 workspace：产品化计划

> 2026-07-16 · ruihua（designer）
> 基于 Allen 的工程缺口清单（PR #1427）逐条撰写用户旅程、验收标准与优先级排序。
> G4 含依赖未就绪时的降级/占位方案。
>
> **信息来源：** 本计划的事实基础（现状证据、代码位置、冷启动实测结果）全部来自
> Allen 的缺口清单（基于 main 分支 commit `eb2b56a88` 的冷启动实测 + 静态代码核查）。
> 未独立验证代码现状；如果缺口清单有过时之处，本计划会继承。
>
> **产能参考：** 工程效率分析（近 8 周基线）— 人类 ~1.35 人月/月（下界，实际 2.5-4×）；
> 产品化投入占 ~45%。本计划覆盖的缺口属「产品化」类别，是当前投入主线。

---

## §0 Allen 决策修订（2026-07-16，lead）— 覆盖下方优先级，请据此重排

> 本节由 lead 直接补入，记录 Allen 对本计划 7 项产品决策的裁定。**下方 §2 优先级表与 §3 各缺口以本节为准重排**（ruihua 后续把细节对齐进各 G 段）。

1. **workspace 创建 = admin 建后拉人（beta）。** founder 注册即得 workspace 仍作为**任务**保留，但**降为非 P0（backlog）**。→ **G1（注册开关）/G2（邀请码 UI）/G3（workspace 创建 UI）自助闸门整体移出 beta 的 P0**（beta 用 admin 手动开通+拉人）。
2. **每用户 own ≤1 workspace，可被加入多个。** → G3 收敛为「文档化单-own 行为」，不做多-workspace 创建 UI。
3. **Agent/Key 模型 = 托管 agent（不是让外部企业自带 key）。** 路线：「一个 agent 服务多企业」，**实施上每个企业 workspace 里放一个 agent 分身（fork/clone），后端数据关联到共享的真·服务 agent**（保持每-workspace 独立 agent 实体、不破跨-workspace 隔离；底层共享）。→ **这是一条新的架构主线**（对接 agent-clone / domain.agent 原语 + cap-signing 的凭证归属），应单列，不再是「founder 自配自己的 key」那种 BYOK 形态。BYOK/登录仅用于**内部开发者**。
4. **G4 不做 stub_grant，等 cap-signing 落地**（cap-signing 已 SOUND、7 轮评审通过、实现排期中）→ founder key 配置走正式 cap 路径。
5. **G1/G2 是 UI 缺口，机制已存在。** 后端 `registration_open` + `registration_require_invite` + `invite_code` + `mix ezagent.invite` **均已实现**——缺的只是开关 UI / 邀请 UI / 关门页出口，**机制不用重造**。beta 用**邀请制**。
6. **G5 = 建面向用户的可行动失败态 surface（"缺 key，找 admin"）。** 现状：`credential_status` 只面向 owner/admin，终端用户只得通用道歉；**没有通用可配置的用户侧报错机制**。→ G5 顺带做成**通用可配置错误机制**（把结构化失败态透给用户）更有价值。
7. **beta 范围 = admin 手动开通 + 只验「配 key → agent 回复」核心价值闭环。** 与 ezagent 现有的开发自举一致——beta = 把自举那条路对外 dogfood 一遍，复用同一套机制、不新造。

**重排后的 beta P0 实质** = 决策 6 的最小闭环（admin 开通 → 配 key〔待 cap-signing〕→ agent 回复）；G1/G2/G3 自助化推到「真要规模化自助」阶段；决策 3 的托管-分身架构单独立项。

---

## §1 用户画像与场景前提

| 维度 | 定义 |
|------|------|
| **目标用户** | 企业 founder / 首位使用者 — 可能是业务负责人，非技术人员 |
| **场景** | 浏览器冷启动，**零工程师介入**。从打开登录页开始，一切通过点击和输入完成 |
| **形态前提** | SaaS 托管共享实例，workspace 分租户，企业用户只接触浏览器面 |
| **成功定义** | 不靠工程师走完「注册 → 配 key → 发首条消息 → 看到 agent 回复」整链 |
| **已验证可自助** | 注册表单、建 session、选模板 materialize agent、消息路由与回复闭环、匿名访客公开页 — 这些不在缺口内 |

---

## §2 缺口总览（优先级排序）

| 阶段 | 优先级 | 缺口 | 用户影响一句话 | 依赖 | 预估工程投入 |
|------|--------|------|--------------|------|-------------|
| **第一批** | P0 | G1 注册开关无 UI | 用户根本看不到注册入口 | 无 | ~1-2d |
| | P0 | G2 邀请码仅 CLI | founder 无法邀请同事 | 无 | ~1-2d |
| | P0 | G3 workspace 创建无 UI | 产品决策未定：多 workspace 还是单租户？ | 无（但需产品决策） | ~0.5-2d（取决于决策） |
| **第二批** | P0 | **G4 founder 无权自配 agent API key** ⚠️ | agent 跑不起来，用户卡在核心价值门前 | **cap-signing 线** | ~2-4d（含降级方案） |
| | P0 | G5 缺 key 失败态不可行动 | agent 坏了但用户不知道为什么、怎么修 | G4（key 能配才有意义） | ~1-2d |
| **第三批** | P1 | G6 UI 可读性 | 用户面对 UUID 和裸 atom 报错，无法识别和操作 | 无 | ~2-4d |
| | P1 | G7 onboarding 向导缺失 | 注册后不知道该干什么 | G4（配 key 是 onboarding 核心步） | ~3-5d |
| **第四批** | P2 | G8 企业资料/KB 导入无 UI | 真实业务数据进不来 | 无 | ~3-5d |
| | P2 | G9 企业用户文档为零 | 用户遇到问题无自助途径 | 无 | ~2-4d（持续） |
| | P2 | G10 浏览器 E2E CI 锁定 | 闸门可能被后续 PR 焊回 | 前序缺口落地 | ~3-5d |

> **产能校准：** 按人类 1.35 人月/月（下界），产品化 ~45% 投入比例，每月约 **0.6 人月**可用于产品化缺口。
> 第一批+第二批（P0 核心 5 条，打通注册→配 key→发消息）估计需 **7-14 工程日**（约 0.4-0.7 人月，即 2-4 周日历时间）。
> 全部 10 条估计需 **18-33 工程日**（约 0.9-1.7 人月，即 1-2 月日历时间）。

---

## §3 逐条用户旅程

---

### G1: 注册开关无 UI

**优先级:** P0（第一批） | **依赖:** 无 | **阶段:** 拆闸门

#### 现状

G1 涉及两个页面、两个角色：

**Admin 侧 — Settings 页面（`/admin/settings`）：** 当前 Settings 页面只有 SMTP 配置，没有 `registration_open` / `registration_require_invite` 开关。`registration_open` 默认值为 `false`（`app_settings.ex:97-98`），admin 无法在界面上开启注册。

**用户侧 — 关门页（`/register` 未开放时）：** 用户访问注册页，看到「当前未开放注册。」一行纯文字，没有申请入口、没有邀请码入口、没有联系方式的出口。

#### Happy path 旅程

**Admin 操作注册开关（Settings 页面）**

**Step A1 — Admin 进入 Settings。** Admin 登录后进入 `/admin/settings`，在 SMTP 配置之外看到「注册设置」卡片。

**Step A2 — 开启/关闭注册。** `registration_open` 开关（ON/OFF）+ `registration_require_invite` 开关（是否要求邀请码）。开启 → 保存 → 看到确认反馈。

**用户访问注册页（关门页 / 注册表单）**

**Step B1 — 注册开放时。** 用户访问首页/注册页，看到注册表单，可填写信息完成注册。

**Step B2 — 注册关闭时（关门页）。** 关门页不再只是纯文字，改为：
- 「当前暂未开放公开注册」
- 「申请注册」按钮 → 提交邮箱 → 「已收到申请，我们会尽快联系你」
- 或「已有邀请码？」→ 输入邀请码进入注册

**成功终点：** Admin 在 Settings 页面自主控制注册开关；注册关闭时用户有「申请注册」和「邀请码注册」两条出口，不再面对纯文字死胡同。

#### 验收标准

- [ ] AC1: `/admin/settings` 页面有 `registration_open` 开关（ON/OFF），admin 点一次即可切换
- [ ] AC2: `/admin/settings` 页面有 `registration_require_invite` 开关
- [ ] AC3: 注册开放时，未登录用户看到注册入口（按钮 / 链接）
- [ ] AC4: 注册关闭时，关门页显示申请入口（提交邮箱）+ 邀请码入口，而非纯文字「未开放注册。」
- [ ] AC5: 申请提交后有反馈（弹窗 / toast），不静默
- [ ] AC6: 冷启动实测：不靠工程师，admin 能找到并操作注册开关

#### 情绪曲线

😤 挫败（关门页没出口）→ 😊 满意（有申请入口 / 等开放通知）→ 😊 满意（admin 一键开启注册）

---

### G2: 邀请码仅 CLI

**优先级:** P0（第一批） | **依赖:** 无 | **阶段:** 拆闸门

#### 现状（用户视角）

founder 注册完想邀请同事加入 workspace，发现……根本没有界面。邀请码的生成、查看、撤销全部只存在于终端命令 `mix ezagent.invite mint`。一个不写代码的企业 founder 面对的是零操作入口。

#### Happy path 旅程

**Step 1 — 进入邀请管理。** founder 在 workspace 设置页（或成员管理页）看到「邀请成员」区域。

**Step 2 — 生成邀请码。** 点击「生成邀请码」→ 系统生成一个邀请码 + 链接 → 显示在界面上，可复制。

**Step 3 — 分享邀请。** founder 把邀请链接发给同事。链接格式：`https://<instance>/register?invite=<code>`。

**Step 4 — 同事注册。** 同事点开链接 → 注册表单预填邀请码（不可编辑）→ 填写用户名/密码 → 注册成功 → 自动进入同一 workspace。

**Step 5 — 管理邀请码。** founder 可查看「已发出邀请」列表（含状态：待使用 / 已使用 / 已过期），可撤销未使用的邀请码。

**成功终点：** founder 无需终端，纯浏览器完成「生成邀请码 → 发给同事 → 同事加入 workspace」。

#### 验收标准

- [ ] AC1: workspace 设置页有「邀请成员」区域，含「生成邀请码」按钮
- [ ] AC2: 生成的邀请码以可复制文本 + 一键复制按钮呈现
- [ ] AC3: 邀请链接在未登录状态下打开，跳转到注册页且邀请码预填
- [ ] AC4: 使用邀请码注册的用户自动进入对应 workspace（无需额外操作）
- [ ] AC5: 邀请码列表显示每条邀请的状态（待使用 / 已使用 / 已过期）
- [ ] AC6: founder 可撤销未使用的邀请码
- [ ] AC7: 冷启动实测：founder 不靠 CLI，完成邀请同事全流程

#### 情绪曲线

😤 挫败（根本没有入口，终端命令找不到）→ 😊 满意（一键生成 + 复制链接发给同事）

---

### G3: workspace 显式创建无 UI

**优先级:** P0（第一批） | **依赖:** 无（但需产品决策） | **阶段:** 拆闸门

#### 现状（用户视角）

目前「注册即得 workspace」（registration 副产品），用户没法主动创建第二个 workspace。这本身不一定是问题——取决于产品模型是「一个用户一个 workspace」还是「一个用户可拥有多个 workspace」。不管哪种选择，**产品决策没有传达给用户**：注册时不告知「你正在创建你的专属 workspace」，也看不到自己有哪些 workspace。

#### 产品决策选项

| 选项 | 描述 | 用户影响 | 工程影响 |
|------|------|---------|---------|
| **A: 明确「一注册一租户」** | 注册即 workspace，不开放 UI 创建 | 简单清晰，但 founder 无法创建多个 workspace（如测试/生产分离） | 最小（文档化现有行为） |
| **B: 开放 UI 创建** | 在 world 中加 `workspace.create` action + UI | 灵活，但增加管理复杂度 | 中等（需前后端 + cap 模型） |

**建议：** 短期选 **A**（一注册一租户），在注册成功页显式告知「你的 workspace `<name>` 已创建」+ 引导进入。中期再评估是否需要 B。这样不阻塞 G1-G2 的推进节奏。

#### Happy path 旅程（方案 A：短期）

**Step 1 — 注册成功。** 用户完成注册表单提交 → 成功页显式告知：「🎉 注册成功！你的专属 workspace `<自动生成名称>` 已创建」。

**Step 2 — 进入 workspace。** 成功页有「进入 workspace」按钮 → 点击进入 world 主界面。

**Step 3 — 感知 workspace 身份。** world 侧边栏/header 显示当前 workspace 名称。用户明确知道「我在哪个 workspace 里」。

#### Happy path 旅程（方案 B：中期）

**Step 1 — 查看 workspace 列表。** world 侧边栏有 workspace 切换器，显示当前 workspace + 「+ 新建」。

**Step 2 — 创建新 workspace。** 点击「+ 新建」→ 弹窗填写 workspace 名称 → 确认 → workspace 创建成功 → 自动切换到新 workspace。

#### 验收标准

- [ ] AC1: 注册成功页显式告知用户「你的 workspace 已创建」（含 workspace 名称）
- [ ] AC2: world 界面有 workspace 身份标识（header / 侧边栏显示当前 workspace 名）
- [ ] AC3: 用户明确知道 workspace 是「自己的独立空间」（注册成功页有简短说明）
- [ ] AC4: （方案 B 阶段）workspace 切换/创建有 UI
- [ ] AC5: 冷启动实测：注册后用户知道自己进入了 workspace，不困惑

#### 情绪曲线

😐 无感（不知道自己有 workspace，也不理解这个概念）→ 😊 明确（「我的 workspace 已创建」，有归属感）

---

### G4: founder 无权自配 agent API key ⚠️ 有依赖

**优先级:** P0（第二批） | **依赖:** cap-signing 线（agent 授权模型收口） | **阶段:** 核心价值链路

#### 现状（用户视角）

界面上的 agent Keys 配置页明明存在，但 founder 点进去操作就报 `:unauthorized`。用户不知道「我已经注册了、创建了 workspace、配了 agent——为什么我无权给我自己的 agent 配 key？」这是一个产品信任问题：连自己的 agent 都控制不了，是这个平台不让我用。

#### 长期路径（cap-signing 就绪后）

founder 在 workspace 创建时，entity-caps 自动签发 `agent:key:write` capability（scope: workspace），覆盖 founder 在自己 workspace 下的 key 管理权限。这套路径依赖：
1. cap-signing 严格签名落地（`feat/cap-strict-capstore` v11 SOUND，实现待排期）
2. entity-caps 在 workspace 创建事件上触发 `Cap.issue`（grantee = founder）
3. `agent.api_key.put` action 的 authorize 走 `EntityCaps.load` 验证（而非 role check）

#### 短期降级/占位方案（cap-signing 未就绪时）

**核心思路：** 不等到 cap-signing 整条线落地，先打一条临时通道让 founder 能配 key。用 `:stub_grant` telemetry 标记，与现有 stub 模式一致（参考 `authz_check/2` 的 `:stub_grant` 先例）。

**具体方案：**

1. **注册时生成 admin PAT。** founder 注册时，系统自动生成一个 workspace-scoped Personal Access Token（scope: `workspace:admin`），存入 founder 的 credential store。
2. **Agent Keys 页面向 founder 开放。** 在 `agent.api_key.put` 的 authz 路径上，加一个 `:stub_grant` 分支：如果 caller 是 workspace founder + target workspace 是 caller 自己的 workspace → grant，同时打 `:stub_grant` telemetry 事件。
3. **用户旅程不变。** founder 进入 Agent Keys 页 → 填入 API key → 验证通过 → agent 可用。用户感知不到 stub_grant 和正式 cap 的区别。
4. **切换条件。** cap-signing 落地 + entity-caps 在 workspace 创建时签发 `agent:key:write` 给 founder → `agent.api_key.put` 的 authorize 切换到 `EntityCaps.load` 路径 → 移除 `:stub_grant` 分支 → `:stub_grant` telemetry 归零。

**风险与缓解：**

| 风险 | 缓解 |
|------|------|
| stub_grant 期间 founder 权限比最终模型宽 | 范围限于自己 workspace，且 `:stub_grant` telemetry 持续监控，可审计 |
| 切换时遗忘移除 stub 分支 | `:stub_grant` telemetry 归零 = 切换成功的信号；加入 G10 E2E 验证 |
| workspace founder 角色变更（转移 founder）时 stub 仍生效 | stub 校验 caller == workspace.original_founder（不可转移字段），而非动态 role |

#### Happy path 旅程（降级方案下的用户体验）

**Step 1 — 进入 Agent Keys 页。** founder 在 workspace 设置 → 「Agent Keys」→ 页面正常加载，不再报 `:unauthorized`。

**Step 2 — 填入 API key。** founder 看到「添加 API Key」表单：选择 provider（Anthropic / OpenAI / …），粘贴 key，点击「验证」。

**Step 3 — 即时校验反馈。** 系统验证 key 有效性 → 绿色 ✓「Key 有效，已保存」或红色 ✗「Key 无效：<具体原因>」。

**Step 4 — Agent 可用。** 回到 agent 页面 → agent 状态从「未配置 key」变为「就绪」→ 发送消息 → agent 正常回复。

**成功终点：** founder 在浏览器里独立完成 agent key 配置，无需工程师介入，agent 能正常回复消息。

#### 验收标准

- [ ] AC1: founder 能访问自己 workspace 的 Agent Keys 页面，不报 `:unauthorized`
- [ ] AC2: founder 能填入 API key 并保存
- [ ] AC3: key 填入后有即时校验反馈（有效 / 无效 + 原因）
- [ ] AC4: key 配置成功后，agent 状态变为「就绪」
- [ ] AC5: `:stub_grant` telemetry 事件在 founder 访问 Agent Keys 页时被触发（可审计）
- [ ] AC6: 非 founder 的 workspace member 访问 Agent Keys 页仍被正确拒绝
- [ ] AC7: 冷启动实测：founder 从注册到 agent 正常回复，全流程无 `:unauthorized` 阻断

#### 情绪曲线

😤 挫败（明明有界面却 `:unauthorized`，感觉平台不让我用）→ 😊 顺利（填 key → 验证通过 → agent 能用了）→ 😊 信任（「我能控制我的 agent」）

---

### G5: 缺 key 失败态不可行动

**优先级:** P0（第二批） | **依赖:** G4（key 能配才有意义） | **阶段:** 核心价值链路

#### 现状（用户视角）

用户发送消息给 agent，agent 回复一段通用道歉文案（类似「抱歉，我无法处理这个请求」），**但不告诉用户为什么、缺什么、去哪修**。用户只能猜测：是 agent 坏了？是我问的问题不对？只有 workspace owner/admin 能在另一个页面看到 `credential_status`，普通成员完全没有线索。

#### Happy path 旅程

**Step 1 — 用户发消息给 agent。** 消息发送正常。如果 agent 缺 key → 不走通用道歉文案。

**Step 2 — agent 回复显式化。** agent 回复：「⚠️ 我还没有配置 API Key，无法调用 AI 模型。请前往 [Agent Keys 设置] 配置 Anthropic / OpenAI API Key。」（含直达链接，可点击跳转）。

**Step 3 — 跳转配置。** 用户点击链接 → 跳转到 Agent Keys 页（如无权限则显示「请联系 workspace founder `<name>` 配置 Agent Key」，并给出一键 @founder 或发送提醒的入口）。

**Step 4 — 配置完成。** founder 配好 key 后，agent 状态自动感知（poll 或 push），用户再次发消息 → agent 正常回复。

**成功终点：** 任何用户遇到 agent 无法回复时，都能从 agent 的回复中知道**缺什么 + 去哪配**，且有一条可操作的路径。

#### 验收标准

- [ ] AC1: agent 缺 key 时，回复消息明确说明缺的是什么（API Key），而非通用道歉
- [ ] AC2: 回复中含直达 Agent Keys 页的链接（可点击跳转）
- [ ] AC3: 如果当前用户无权配 key（非 founder），回复说明「请联系谁」（指名 founder）+ 可操作入口（一键发送提醒 / @founder）
- [ ] AC4: key 配置完成后，agent 状态自动更新，无需用户刷新页面
- [ ] AC5: key 填入时有即时校验反馈（有效/无效/网络错误/格式错误）—— 而非静默保存后 agent 仍不能用
- [ ] AC6: 冷启动实测：新注册用户在无 key 状态下发消息 → 看到明确指引 → 按指引操作 → agent 最终能回复

#### 情绪曲线

😤 困惑（agent 不说话，不知道为什么）→ 😌 明白（agent 告诉了我缺什么 + 去哪配）→ 😊 解决（配好 key，agent 能用了）

---

### G6: UI 可读性

**优先级:** P1（第三批） | **依赖:** 无 | **阶段:** 体验打磨

#### 现状（用户视角）

当前 UI 有多个可读性痛点，每条独立但叠加后让用户感觉「这个产品还没做完」：

**痛点 A — Agent 列表裸 UUID。** agent 列表里每个 agent 显示的是 `a1b2c3d4-...` 这样的 UUID，用户完全无法区分哪个 agent 是干什么的。唯一线索是 `flavor` 列（如 `claude` / `python`）——但这对非技术用户来说也不直观。

**痛点 B — 首登 PAT interstitial 噪音。** 首次登录后弹出一个 Personal Access Token 的管理界面。对不写代码的企业用户来说，PAT 是陌生的概念——「我为什么要创建 token？token 是什么？」这是面向开发者的功能，不应该成为普通用户的首登体验。

**痛点 C — 登录后 Continue 落 404。** 用户在某个页面登录后，点「Continue」想回到刚才的页面，结果跳转到 404。死路页让人感觉产品坏了。

**痛点 D — 会话名校验矛盾。** 创建会话时，提示文案说「支持中文名称」，但用户输入纯中文名后却被拒绝。用户被误导 → 困惑 → 挫败。

**痛点 E — 错误裸 atom 直出 UI。** 操作失败时，页面上直接显示 `:invalid_session_name` 或 `:unauthorized` 这样的 Elixir atom，而非人类可读的中文错误提示。

#### Happy path 旅程

**痛点 A — Agent 可识别**

**Step 1:** 用户进入 agent 列表 → 每个 agent 显示**名称**（而非 UUID）。名称由用户在创建 agent 时指定（如「我的客服助手」），未指定时用 `{flavor} Agent #{序号}`（如「Claude Agent #1」）。

**Step 2:** 列表每行包含：名称、flavor 标签（中文：「Claude 对话」「Python 执行」）、状态指示（就绪 / 未配置 key / 离线）。UUID 降级到详情页。

**痛点 B — 首登体验干净**

**Step 1:** 用户注册后首次登录 → 看到 workspace 主界面（agent 列表 / 模板选择），**不弹出 PAT 管理**。

**Step 2:** PAT 管理入口移至 Settings → Developer（或「API 访问」），面向开发者用户。普通用户首登不应接触。

**痛点 C — Continue 不死路**

**Step 1:** 用户在任意页面点击登录 → 登录成功后 → 跳回**登录前所在页面**（而非固定跳 `/`）。

**Step 2:** 如果原页面不再存在或无权访问 → 跳 `/`，并 toast 说明「原页面已失效，已为你跳转到首页」。

**痛点 D — 校验提示一致**

**Step 1:** 用户创建会话，名称输入框下方实时显示规则：「可包含中文、英文、数字、下划线，2-30 个字符」。

**Step 2:** 输入不符合规则时，输入框变红 + 行内提示具体原因（如「名称至少需要 2 个字符」），而非提交后才弹错误。

**Step 3:** 实际校验规则与提示文案一致（纯中文名被允许）。

**痛点 E — 错误提示人类可读**

**Step 1:** 任何操作失败 → 错误提示使用中文，描述「发生了什么 + 建议做什么」。例如 `:invalid_session_name` → 「会话名称不符合规则：可包含中文、英文、数字、下划线，2-30 个字符」。

**Step 2:** 权限错误提示给可行建议：`:unauthorized` → 「你没有权限执行此操作。如需访问，请联系 workspace founder `<name>`。」

#### 验收标准

- [ ] AC1: agent 列表显示 agent 名称（非 UUID），可区分不同 agent
- [ ] AC2: 首登后不弹出 PAT interstitial（PAT 入口移至 Settings → Developer）
- [ ] AC3: 登录后「Continue」不落 404（回到登录前页面 or 首页 + toast）
- [ ] AC4: 会话名输入框的提示文案与实际校验规则一致（中文名被正确允许）
- [ ] AC5: 所有面向普通用户的错误提示为中文 + 可行动建议（非 Elixir atom）
- [ ] AC6: agent 列表行含状态指示（就绪 / 未配置 key / 离线）

#### 情绪曲线

😤 困惑+不信任（UUID、atom、404、矛盾提示——「产品没做完」）→ 😊 清晰（agent 有名字、错误能看懂、跳转不迷路）

---

### G7: onboarding 向导 + 应用 gallery 缺失

**优先级:** P1（第三批） | **依赖:** G4（配 key 是 onboarding 核心步） | **阶段:** 体验打磨

#### 现状（用户视角）

用户注册成功后进入 workspace，面对一个空的 world 界面。没有任何引导告诉 ta「接下来做什么」。socialware 模板和应用是存在的（`DefinitionRegistry.list/1` 有 API），但前端没有展示面——用户不知道有哪些模板可用、每个模板能做什么。注册成功 → 空白界面 → 用户流失。

#### Happy path 旅程

**Step 1 — 注册成功 → onboarding 向导。** 注册成功页后，用户进入 3-4 步的 onboarding 向导（可跳过、可随时返回）：

- **步骤 1：「创建你的第一个 Agent」。** 展示模板 gallery（卡片式，含名称、描述、预览图）。推荐「Claude 对话」作为默认模板。点击「使用此模板」→ agent 创建完成。
- **步骤 2：「配置 API Key」。** 引导到 Agent Keys 页，填入 Anthropic / OpenAI key。含「为什么需要 Key？」的简短说明（1-2 句，不吓人）。
- **步骤 3：「发送第一条消息」。** 引导到 agent 聊天页，预设一条欢迎消息（如「你好！我是你的 AI 助手，有什么可以帮你的？」）。
- **步骤 4：「了解你的 workspace」。** 快速 tour：这是你的 agent 列表、这是设置、这是邀请成员。

**Step 2 — 随时可访问 gallery。** world 侧边栏有「应用 Gallery」入口 → 浏览所有可用 socialware 模板 → 一键添加到自己的 workspace。

**Step 3 — 向导可跳过、可重访。** 「跳过向导」在每步都可见。完成后在 Settings 中有「重新开始向导」入口。

**成功终点：** 注册后 5 分钟内，用户完成「选模板 → 配 key → 发消息 → agent 回复」整链，感受到产品价值。

#### 验收标准

- [ ] AC1: 注册成功后自动进入 onboarding 向导（含 3-4 步）
- [ ] AC2: 向导步骤 1 展示模板 gallery，至少含 2-3 个可选模板
- [ ] AC3: 每步显示进度指示（如「步骤 2/4」）
- [ ] AC4: 每步有「跳过」按钮（不强制走完）
- [ ] AC5: 向导完成后（或 skip 后）可在 Settings 中重新开始
- [ ] AC6: world 侧边栏有「应用 Gallery」入口，可随时浏览和添加模板
- [ ] AC7: gallery 卡片含模板名称、一句话描述、flavor 标签
- [ ] AC8: 冷启动实测：注册后用户走完向导并收到 agent 回复，全程 ≤ 5 分钟

#### 情绪曲线

😐 空白（注册成功后面无表情地看着空界面）→ 😊 引导（一步步知道自己在做什么）→ 🎉 惊喜（「agent 回复我了！」）

---

### G8: 企业资料/KB 导入无 UI

**优先级:** P2（第四批） | **依赖:** 无 | **阶段:** 业务闭环

#### 现状（用户视角）

企业有真实的业务文档、FAQ、产品说明想让 agent 学习，但目前 `kb.ingest` 只能通过 API / MCP 协议逐条提交——没有上传界面、没有批量导入、没有任何 UI 通道。真实业务数据进不来，agent 只能跑 demo 数据。

#### Happy path 旅程

**Step 1 — 进入知识库管理。** 用户在 workspace 设置 → 「知识库」→ 看到当前已导入的知识条目列表（可能为空）。

**Step 2 — 添加知识。** 点击「添加知识」→ 选择方式：
- **粘贴文本：** 直接粘贴文字内容 + 标题
- **上传文件：** 拖拽/选择 `.txt` `.md` `.pdf` 文件（单文件或批量）
- **网页链接：** 输入 URL，系统抓取内容

**Step 3 — 导入反馈。** 上传后显示处理状态：解析中 → 已入库（N 条片段）→ 可检索。失败的文件标红 + 原因（格式不支持 / 文件太大 / 内容为空）。

**Step 4 — agent 使用知识。** 在 agent 配置中可选择「关联知识库」→ agent 回复时可检索知识库内容作为上下文。

**成功终点：** 企业用户能通过浏览器上传业务文档，agent 能基于这些文档回答问题。

#### 验收标准

- [ ] AC1: workspace 设置中有「知识库」管理页
- [ ] AC2: 支持粘贴文本添加知识（含标题 + 正文）
- [ ] AC3: 支持上传 `.txt` `.md` 文件（单文件 or 批量拖拽）
- [ ] AC4: 上传后有处理状态反馈（解析中 → 已入库 / 失败）
- [ ] AC5: 失败的文件显示具体原因（格式 / 大小 / 内容问题）
- [ ] AC6: agent 可关联知识库，并在回复中使用知识库内容

#### 情绪曲线

😐 无从下手（知道 agent 能学但不知道怎么喂数据）→ 😊 便捷（拖拽上传 → agent 会了 → 能回答业务问题了）

---

### G9: 企业用户文档为零

**优先级:** P2（第四批） | **依赖:** 无 | **阶段:** 业务闭环

#### 现状（用户视角）

目前 `docs/guide/` 下所有文档面向运营/开发者——IEx 命令、mix task、Elixir 配置。一个纯浏览器用户注册后遇到问题，能看的文档是 0。用户只能猜测或放弃。

#### Happy path 旅程

**Step 1 — 产品内嵌帮助入口。** world 界面右下角有「？」帮助按钮 → 点击弹出帮助面板，显示当前页面的关联帮助条目。

**Step 2 — 帮助内容。** 面向企业用户的文档至少覆盖：
- **「第一天上手」**：注册 → 创建 agent → 配 key → 发首条消息（对应 onboarding 向导，作为随时可查的文档版）
- **「常见问题」**：agent 不回复怎么办 / key 在哪获取 / 怎么邀请同事 / 会话和 agent 的关系
- **「错误排查」**：常见错误提示的含义 + 解决方法（对应 G5+G6 的 UI 修复，文档作为补充）

**Step 3 — 文档可被搜索。** 帮助面板顶部有搜索框，输入关键词即时筛选。

**成功终点：** 用户遇到问题，在界面内能找到答案，不需要联系工程师。

#### 验收标准

- [ ] AC1: world 界面有产品内嵌帮助入口（如右下角「？」按钮）
- [ ] AC2: 帮助内容覆盖「第一天上手」「常见问题」「错误排查」三个类别
- [ ] AC3: 帮助内容可被搜索（关键词即时筛选）
- [ ] AC4: 帮助内容为中文，面向非技术用户（不含 IEx/mix 命令）
- [ ] AC5: 首次注册用户能看到指向帮助入口的提示（如 toast：「有疑问？点右下角 ?」）

#### 情绪曲线

😤 无助（卡住了，但找不到任何说明）→ 😊 自助（点 ? → 搜索 → 找到答案 → 自己解决）

---

### G10: 无浏览器级 E2E 锁定

**优先级:** P2（第四批） | **依赖:** 前序缺口落地后 | **阶段:** 防回退

#### 现状（用户视角）

用户感知不到这条缺口——但产品团队需要它。目前 CI 只有 ExUnit + markdown 剧本测试，没有浏览器级 E2E 验证「注册 → 配 key → 发消息 → agent 回复」整链。一旦前序缺口被后续 PR 意外焊回（如某个重构改了 authz 路径），没有人会立刻发现——直到下次冷启动实测。

#### 需要什么（非用户旅程，为工程验收规格）

把冷启动整链脚本化进 CI：

1. **注册 → 邮箱验证 → 登录**（验证 G1 注册开关未闭合）
2. **生成邀请码 → 邀请链接 → 受邀者注册 → 进入同一 workspace**（验证 G2）
3. **进入 Agent Keys 页 → 填入测试 key → 校验通过 → agent 状态变为「就绪」**（验证 G4+G5）
4. **创建 agent → 发送消息 → agent 正常回复**（验证核心价值链路）
5. **登录后 Continue 回到原页面**（验证 G6-C）
6. **会话名中文输入 → 创建成功**（验证 G6-D）
7. **错误操作 → 中文提示而非 atom**（验证 G6-E）
8. **agent 缺 key → 回复含指引 + 链接**（验证 G5）

#### 验收标准

- [ ] AC1: CI 中有至少 1 条浏览器级 E2E 测试覆盖注册→配 key→发消息→agent 回复整链
- [ ] AC2: E2E 测试在 PR gate 中运行（非手动触发）
- [ ] AC3: E2E 测试失败时能指出具体哪一步断裂（而非笼统超时）
- [ ] AC4: 测试使用隔离的测试 workspace（不影响生产数据）
- [ ] AC5: 前序缺口（G1-G9）中每条有 UI 面的，至少 1 条 E2E 覆盖其 happy path

#### 情绪曲线

（面向团队而非用户）工程视角：😰 不安（不知道闸门有没有被焊回）→ 😌 放心（每次 PR 自动验证冷启动链完整）

---

## §4 优先级排序说明

### 排序逻辑

按「**用户冷启动能走到第几步**」排列：

| 用户想做的事 | 被哪个缺口卡住 | 阶段 |
|-------------|--------------|------|
| 1. 看到注册入口 | G1 — 关门页没出口 | **第一批：拆闸门** |
| 2. 邀请同事加入 | G2 — 邀请码无 UI | |
| 3. 知道自己在哪个 workspace | G3 — workspace 身份不可见 | |
| 4. 让 agent 能跑起来 | **G4 — 无权配 key** | **第二批：核心价值** |
| 5. agent 不工作时知道怎么修 | G5 — 失败态不可行动 | |
| 6. 能识别和管理 agent | G6 — UUID/atom/404 | **第三批：不再迷路** |
| 7. 知道接下来做什么 | G7 — 无 onboarding | |
| 8. 导入真实业务数据 | G8 — KB 无 UI | **第四批：真实使用** |
| 9. 遇到问题能自己解决 | G9 — 无用户文档 | |
| — 团队防回退 | G10 — 无 E2E 锁定 | |

### 为什么 G4 在第二批而非第一批

G4 依赖 cap-signing 线。即使降级方案就位，也需要 2-4d 工程投入。而 G1/G2/G3 都是无依赖、低投入（1-2d each）的纯 UI 缺口——先拆这些闸门，用户可以「进门」（能注册 + 能邀请人 + 感知 workspace）。进门后再解决「做事」（配 key → 发消息 → 看价值）。

### 工程效率参考

| 参考维度 | 数值 | 对规划的指导 |
|---------|------|------------|
| 人类月均投入（下界） | ~1.35 人月/月 | 全队每人月可用于产品化缺口的约 0.6 人月 |
| 实际人类投入（估计） | 2.5-4 人月/月 | 单个缺口（1-2d）在多人并行下可快速收敛 |
| 产品化占比 | ~45% | 这批缺口天然属于产品化类别，与当前投入结构吻合 |

> 注意：以上数字为**聚合层面产能参考**，不用于排定「哪天做完哪条」的精确时间表。实际排期由 lead 统筹各 track 后定。

---

## §5 G4 降级方案详述

### 依赖链

```
cap-signing 严格签名 (feat/cap-strict-capstore v11 SOUND, 实现待排期)
  └─ entity-caps 在 workspace 创建时签发 agent:key:write cap
       └─ agent.api_key.put 的 authorize 走 EntityCaps.load
            └─ founder 能配 key ✅
```

当前状态：cap-signing 的 spec 已 SOUND（v11，11 轮对抗评审），但**实现排期未定**。no-tail 自愈路径已废（#1424 draft 搁置）。严格签名实现可能是数周级的工作。

### 短期降级方案（本计划建议）

**方案名：** Founder PAT Auto-Provision + Stub Grant

**流程：**

1. **注册时**：系统在 `registration.ex` 的 workspace 创建步骤中，自动生成一个 workspace-scoped PAT（scope: `workspace:admin`），存入 founder credential store。
2. **Agent Keys 访问时**：`agent.api_key.put` 的 authz 路径新增 `:stub_grant` 分支：
   - 条件：`caller == workspace.original_founder AND target_workspace == caller.workspace`
   - 行为：grant → 打 `:stub_grant` telemetry（`[:ezagent, :authz, :stub_grant]`）
   - 非 founder 的访问仍走原路径（正确拒绝）
3. **切换时**：cap-signing 落地后 → entity-caps 签发 `agent:key:write` 给 founder → authz 切换到 `EntityCaps.load` → 移除 stub 分支 → `:stub_grant` telemetry 归零 = 切换确认信号。

### 为什么不直接修 role check

当前 authz 模型的 role check 有意不覆盖 key 管理——这是架构决策，不是 bug。直接加 role check 会让「key 管理权限」的语义散落在两处（role + cap），增加后续清理难度。stub_grant 的优点是：
- **显式标记为临时**：`:stub_grant` telemetry 本身就是「这个分支待移除」的标记
- **对齐最终模型**：stub_grant 的语义是「模拟 cap」，而非「新增 role 规则」
- **可审计**：每次 stub_grant 触发都记录，切换后归零 = 证据

---

## §6 验证 Checklist

- [ ] 每条缺口有「用户旅程」（Step 1 → Step N，描述用户做什么 + 系统响应什么）
- [ ] 每条缺口有「验收标准」（逐条可验证的 AC，含冷启动实测视角）
- [ ] 每条缺口有「优先级」（P0/P1/P2）和「阶段归属」（第一批/第二批/第三批/第四批）
- [ ] 每条缺口有「依赖标注」（无 / 依赖哪个缺口 / 依赖外部线）
- [ ] G4 含长期路径 + 短期降级方案 + 切换条件 + 风险与缓解
- [ ] 优先级排序有明确的「用户走到第几步」逻辑
- [ ] 工程效率分析作为产能参考被引用（附读数纪律）
- [ ] G0 标注为运营侧，不写用户旅程

---

## §7 不在此计划内

| 项 | 原因 |
|----|------|
| G0（bootstrap 断点） | 运营侧缺口，目标用户不是企业用户；用户旅程不适用 |
| 组织/中枢-成员层级 | 单企业自助不需要（原缺口清单已标注） |
| 计费/配额/运营 dashboard | 归商业化/稳定性轨道 |
| self-host 自助安装器 | 归中枢客户交付轨道 |
| UI 开发实施 | designer track 做产品计划，不写代码 |
| #1388 DealScout 合并 | 等 lead 操作 |
| W29 demo 产品完善 | 周目标已变更为 dev-loop 自举 |

---

## §8 下一步

1. **本计划交 lead review** — 确认优先级排序和 G4 降级方案是否与工程现实对齐
2. **与 zyli UI 对齐** — 拿本计划中的 G6（UI 可读性）和 G7（onboarding）作为 UI 优先级的讨论起点
3. **G3 产品决策** — lead 拍板「一注册一租户」vs「开放 UI 创建」，锁定后 G3 的验收标准可去重
