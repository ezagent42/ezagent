# Agent Console — 手动点击测试计划(全生命周期)

> 目的:沿 agent **完整生命周期**逐一手动点过,找 **bug** + 看 **UX 是否顺畅**。
> 基于 main `6f123b8b`(2026-06-26)。文案/路由均逐字取自当前代码。

---

## 0. 准备 & 用法

### 启动前提(已由开发起好,确认在跑即可)
- 后端服务:`http://localhost:10042`(world UI 走 host 路由)
- 前端 island:vite 在 `:5173`(**关了 UI 会白屏**)
- 浏览器:**用 Chrome / Firefox**(Safari 不自动解析 `*.localhost`)
- 入口:**`http://world.localhost:10042`** · 登录 **`admin@ezagent.chat` / `worlddev`**(admin 拥有全部 cap)

### 用法
- 每条 `[ ]` 通过打勾;不通在「实际/Bug」写现象(截图更好);UX 不顺(文案绕/跳转怪/状态滞后)写「UX 备注」。
- 负向用例(报错/拒绝)也要点,验证"**没有静默失败**"。

### ⚠️ 已知 deferred —— 看到别当 bug 报
- **repoint** 配置回滚:后端有、**UI 没做**
- **fork**(从父模板复制):Deferred
- 详情页「还没接线」区:`skills / tools / kb / lifecycle_detail / settings_mgmt`
- 创建页「executor extras(settings/mcp/model/provider)」:Pending backend approval
- **With PTY** 复选框:渲染了但当前空转
- agent console **无** start/stop/restart 控件(只能看状态;重启在会话侧)

---

## 生命周期总览(点击顺序建议)

| 阶段 | 做什么 | 章节 | console 动作 |
|---|---|---|---|
| ① 创建 Create | 建各 flavor 的 agent | §1 | `agents.create` |
| ② 查找 Find | 列表 / 按 flavor 过滤 / 进详情 | §2 | (读) |
| ③ 查看 Inspect | 运行状态 / 配置 / caps | §3 | `lifecycle_status`(读) |
| ④ 使用 Use | 拉进会话 → 参与对话 | §4 | `session.invite`(会话侧) |
| ⑤ 修改 Modify | 改配置 / API key | §5 | `config.update` / `config.delete_path` / `api_key.put` |
| ⑥ 删除 Delete | 删除 + 占用禁删 | §6 | `agents.delete` |
| ⑦ 删后验证 Verify | 确认真没了 | §6.4 | (读) |

> 建议建至少一个 **curl**(最轻、全程顺)走完整闭环,再用 cc / py 复测差异。

---

## §1 ① 创建 Create  `/identities/agents/new`

- [ ] **1.1 建 curl(最简闭环起点)**
  - Flavor 选 `curl`;Name 填 `qa-curl-1`(占位 `storefront-greeter`);cwd 留空;点 **"Create"**
  - 预期:成功 → 跳 `/identities/agents/<uri>` 详情页
- [ ] **1.2 cc 的 cwd 必填校验**
  - Flavor 选 `cc`,只填 Name,cwd 空 → `project_cwd` 标 `*`、**Create 禁用**;强提交报 **"cc 需要 project_cwd(工作目录)"**
  - [ ] 填不存在目录 → **"project_cwd 不是有效目录:{cwd}"**
- [ ] **1.3 config_schema 动态字段随 flavor 变**(#992 新机制,重点)
  - 把 Flavor 在 `cc`/`curl`/`py` 间切,观察 "{flavor} configuration" 字段表
  - 预期:cc 多(model/effort/permission_mode/…);curl(model/provider/api_url/system_prompt/max_history);py(script/timeout_ms);控件类型符合(enum 下拉 / text 多行 / 普通框)
- [ ] **1.4 requested caps 校验**:乱填 `abc` → 红字 **"格式:kind.behavior(逗号分隔,如 chat.send)"**,Create 禁用
- [ ] **1.5 同名**:重复 1.1 名字 → **"同名 agent 已存在:{uri}"**
- [ ] **1.6 非法名**:Name 填 `1bad name!` → **"name 不合法(字母数字开头,仅 字母/数字/-/_):{name}"**
- [ ] **1.7 建 py**(echo 替代):选 `py` 填 script/timeout → 成功;⚠️ py 子进程要 uv/python,本机没配好可能 Phase/Bridge 不活
- [ ] **1.8 只读说明区**:底部 contract coverage(soul/skills/… "Pending"、fork "Deferred")——确认是标注

---

## §2 ② 查找 / 浏览 Find  `/identities/agents`

- [ ] **2.1 列表渲染**:表头 `Name / URI`、`Flavor`、`Status`、`Actions`;右上 **"New agent"**;无数据 "No agents in this workspace."
- [ ] **2.2 按 flavor 过滤** ⚠️ **自动跑发现 F1:agents 列表当前无 flavor 过滤**(`AgentsTable` 没接 `FilterBar`)。手动确认:`/identities/agents` 顶部**是否真的没有**过滤条?若确实没有,记为 gap(FilterBar 组件 + agent_flavors 数据都在,只是没接 AgentsTable)。
- [ ] **2.3 每行操作链接**:每行 `Status` / `Caps` / `API Keys` / `Extensions` / `Config` 各跳对应页
- [ ] **2.4 进详情**:点 agent 名/Status → 到 `/identities/agents/<uri>`
- [ ] **2.5 直链/刷新**:复制详情页 URL 新开标签 → 能直达(不丢登录态、不白屏)

---

## §3 ③ 查看 / 运行状态 Inspect  `/identities/agents/<uri>`

- [ ] **3.1 基本字段**:`Phase`、`Flavor`、`project_cwd`(无→`—`)、`config_dir`(无→`—`)、`Template`(直接 spawn 显示 "direct-spawn (no template)")、`Bridge`(connected / not connected)
- [ ] **3.2 运行状态准确性**:刚建的 agent Phase 应是活的;列表 Status 对应 `live`(对照看是否一致、是否实时)
- [ ] **3.3 Configuration(按 flavor 展示)**:标题 **"Configuration(按 flavor 展示)"**;字段 + 来源徽章 `(template)`/`(cascade)`;长值截 80 字
- [ ] **3.4 Granted caps (CapBAC)**:标题 **"Granted caps (CapBAC)"**;`behavior.action` 徽章;无则 "none"(若 1.4 请求过 caps,这里应见 granted)
- [ ] **3.5 「还没接线」区**:列出 skills/tools/kb/lifecycle_detail/settings_mgmt + 原因(确认是标注非坏)

---

## §4 ④ 使用 Use(进会话 → 参与对话)

> 这是和「agent 编排会话框架」对接的环节。走**会话页** `/sessions`。
> ⚠️ agent 真回复需要其 flavor 后端可用(curl 需 provider/api_url 配好;cc 需 token;py 需 uv)。先验"能进会话/能收到",回复内容视后端而定。

- [ ] **4.1 建/开一个会话**:`/sessions` 新建或打开默认会话
- [ ] **4.2 邀请 agent 进会话**:用邀请入口把 §1 建的 agent 拉进来(`session.invite`)→ 成员列表出现该 agent
- [ ] **4.3 @ 它发消息**:在会话里 @该 agent 发一条 → 预期消息被路由到它(收到/有反应);**无人接也不该静默**(应有反馈)
- [ ] **4.4 PTY 视图**(若该 flavor 有 PTY):切到该成员的终端视图,观察 I/O
- [ ] **4.5 回到 agent 详情**:此时该 agent 处于「被一个 live session 占用」状态 → 为 §6.3 禁删做铺垫

---

## §5 ⑤ 修改 Modify

### 5A 配置编辑  `/identities/agents/<uri>/config`(用 curl agent 最顺)
- [ ] **5A.1 cascade 三层**:每个 key(如 `advisor.behavior`)下 `Workspace layer (read-only)` / `Session layer (read-only)`(有内容才显示)/ `User layer (editable)`;key 右徽章 "user layer editable"
- [ ] **5A.2 加字段 → 持久(核心)**:User layer 底部 New field name 填 `tone`(占位 `field_name`)、Value 填 `decisive`(占位 `value`)→ **"Add"** → **"Save"**;**刷新后 `tone=decisive` 仍在**(durable)
- [ ] **5A.3 改字段**:`tone` 改 `concise` → Save(**未改动时 Save 禁用**)→ 刷新为 `concise`
- [ ] **5A.4 删字段**:点字段右 `×`(提示 `Remove field tone`)→ Save → 刷新没了
- [ ] **5A.5 控件类型**(schema 覆盖到时):text→多行;enum/list(有 options)→下拉;json→多行(占位 `{"key": "value"}`);boolean→(—/true/false);integer→数字框;secret→密码框
- [ ] **5A.6 只读层不可编**:Workspace/Session 层无输入框/删除键

### 5B API Keys  `/identities/agents/<uri>/api-keys`
- [ ] **5B.1 读**:表头 `Provider`/`Masked`;无 key "No stored keys."
- [ ] **5B.2 写**:Provider 填 `deepseek`、API key 填 `sk-test123`(密码框,占位 `sk-…`)→ **"Save key"** → 表单清空、表里出现 provider + 掩码
- [ ] **5B.3 不支持的 flavor**:对应页显示 **"This agent flavor does not support API keys."**
- [ ] **5B.4 无权限**(可选,非 creator 非 admin):只读、无 Add 表单

---

## §6 ⑥ 删除 Delete + ⑦ 删后验证

- [ ] **6.1 删除确认流** `/identities/agents/<uri>`
  - 点 **"Delete agent"**(红字)→ 出现 **"确认删除该 agent?此操作不可撤销。"** + **"确认删除"** / **"取消"**
  - [ ] 点「取消」→ 不删、回初始
- [ ] **6.2 执行删除**:点「确认删除」→ 回列表,该 agent 消失
- [ ] **6.3 占用禁删(重要负向)**
  - 前置:用 §4 让某 agent 正处于一个 live session 中
  - 删它 → 被挡 + 列表红 banner **"该 agent 正在 N 个对话中(<session 名…>),先从这些对话移出再删除"**
- [ ] **6.4 删后验证(真没了)**
  - 列表里搜不到 ✅(自动跑已确认数据真删)
  - 直链旧详情 URL `/identities/agents/<uri>` ⚠️ **自动跑发现 F2:渲染"空壳详情页"**——显示 `Phase: not_found`、Flavor 从 URL 推断、config 全 `nil`,**没有清晰的"已删除/不存在"空态**。手动确认这个体验是否可接受(理想:明确的 not-found 空态)。
  - (可选,dev 协助)后台 `kind_snapshots` 该 URI 行已删除

---

## §7 其他路由(快速过)
- [ ] **7.1 Extensions** `/.../extensions` — 只读列出 config_dir 内容
- [ ] **7.2 Entity Caps** `/.../caps` — 表头 `kind / behavior / action / instance / granted by`
- [ ] **7.3 Terminal** `/.../terminal` — PTY I/O(可能 deferred,记录是否可用)

---

## §8 跨切面 UX
- [ ] **8.1 报错样式一致**:红框 banner(`role=alert`),位置显眼
- [ ] **8.2 错误滞留**:出错后导航走再回来 banner 是否还在 → 觉得 stale 记 UX
- [ ] **8.3 跳转流畅**:创建跳详情、删除回列表、各页互跳是否顺、有无白屏/卡 loading
- [ ] **8.4 live 状态时效**:建/删后列表 Status 是否实时更新(还是要手刷)
- [ ] **8.5 权限拒绝文案**(若有非 admin 账号):无 manage 权限时 config 读/写应见 "没有…权限(需要 manage 权限)"
- [ ] **8.6 flavor 创建矩阵**(逐个建,记成败)
  - [ ] cc  [ ] cc-headless  [ ] curl  [ ] py  [ ] codex  [ ] codex-remote

---

## §9 Bug / UX 记录表

> 前两条由**自动跑(2026-06-26)**预先发现,待你手动复核 + 定性。

| # | 阶段/用例 | 现象 | 期望 | 类型 | 严重度 | 截图 |
|---|---|---|---|---|---|---|
| F1 | ②查找 / `/identities/agents` | agents 列表无 flavor 过滤(`AgentsTable` 没接 `FilterBar`,组件+数据都在) | 列表可按 flavor 过滤 | Gap/UX | 低-中 | evidence/lifecycle-e2e/02-list-filter.png |
| F2 | ⑦删后 / 旧详情 URL | 渲染"空壳详情页"(`Phase: not_found` + flavor 从 URL 推断 + config 全 nil),无明确已删除空态 | 明确的 not-found / 已删除空态 | UX | 低-中 | evidence/lifecycle-e2e/07-post-delete-detail.png |
| **F3** | ④使用 / `/sessions` 建会话 | **新建会话默认模板 `advisor` 是无效模板类(`:invalid_template`),create 失败,且 UI 完全无报错(表单关掉、列表照旧)。改选 `default` 才成功。** | 默认模板应有效;失败要有报错 banner(no silent drop) | **Bug(默认流程坏 + 静默)** | **高** | 浏览器实测;console 见 `{:invalid_template, class:"session.advisor"}` |
| **F4** | ⑥.3 / 详情页删占用中的 agent | **bound-session 禁删后端生效(agent 没被删),但从详情页点删除→确认后 UI 无任何反馈**:确认框收起、什么都没发生。禁删原因 banner("正在 N 个对话中…")被 push 到 agents-list 路由,详情页看不到。 | 详情页就地显示禁删原因 | **Bug/UX(静默)** | **中-高** | 浏览器实测;console 见 delete→`EntityPresenter.display(session://…/qa-session-1)` |
| F5 | ③查看 / `/…/caps` Entity Caps | `instance` 列直接 dump 原始 Elixir 结构 `%URI{scheme: "entity", userinfo: nil, host: "system", path: "/agent/qa-browser-1", …}`,而不是干净的 `entity://system/agent/qa-browser-1` | 渲染规范 URI 字符串 | Bug(显示) | 低/cosmetic | 浏览器实测 caps 页 |
| F6 | ①创建 / py flavor | py 必填 Python script,但表单**没标 `*`、Create 不禁用**,只有提交后服务端报 `:missing_script`;且该错误是**裸 atom**(其他 create 错误都翻译成中文了) | 标必填+客户端拦截;错误翻译成友好文案 | Bug(校验+文案) | 中 | 浏览器实测;空 script→`创建失败: :missing_script` |
| **F7** | ④/⑥ 会话成员管理 | **会话页无 remove-member / 删除会话 控件** → F4 的"先移出再删除"无法照做,被占用 agent 在 UI 上**删不掉** | 补成员移除 + 会话删除/归档 | **Bug/Gap** | **中-高** | 浏览器实测;`read_page` 无移除控件 |

---

## 附:已自动验证过的(供参考,你手动复核)
开发侧 Playwright E2E 已绿(`6f123b8b`):建 curl → config 编辑器渲染 → `tone=decisive` 刷新后仍在 → 删除消失。本计划在此之上做**人工 + 全生命周期 + 全路由 + UX**覆盖。
