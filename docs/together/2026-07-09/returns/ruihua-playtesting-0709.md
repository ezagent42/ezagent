# Return — 探索式测试 playtesting（canary，2026-07-09）

## Metadata
- **task**: 刷新后 nightly/stable 探索式测试（plan 2026-07-09 · ruihua track）+ 网页对话 flaky 复现
- **env**: canary.ezagent.chat（workspace `ezagent/ezagent`，登录 `chen_ruihua`）
- **status**: in-progress（复验 A1–A4 + 撞到几个 UI bug；flaky 未复现）——用户视角，无代码 / 无 rebase
- **汇报**: 本 return + Feishu 群；**A2/A4 + 3 个 UI bug 建议开 issue**
- **证据**: `docs/together/2026-07-09/returns/evidence/`（截图）
- **已开 issue**：F1→#1279 · F2→#1280 · F3→#1281 · F6→#1282 · F7→#1284 · F4→#1285 · F5→#1286 · F9→#1289 · F10→#1290 · F11→#1291（F8→#1283 **已关，并入 #1288**；F12 **补入 #1274**，zyli 已开）（关联 #1275 空 caps / #1278 agent 表单 / #1259 create 超时 / #396 agent onboarding）
- **查重**：**F8/#1283 = #1288（cc agent 不继承 host Claude 凭证）的重复** → UX 角度已并入 #1288、#1283 已关；其余无重复。

## 复验结果（昨日修复）

| 项 | 对应修复 | 结果 | 说明 |
|---|---|---|---|
| A1 发消息回显 | #1252 | ✅ | 连发多条基本瞬时（<0.5s），不再卡几秒 |
| A2 新建 session | #1259 | ❌ **超时报错** | 见 F1 —— **对 hello 和 default 模板都超时**，不是模板专属 |
| A3 刷新后会话列表 | #1257 | ✅ | 列表不清空、可点开唤醒 |
| A4 新版 hello | #1243 | ⚠ 未测成 | 建不出可用 hello session（受 A2 阻）；并触发 F2 的 overview/chat 不一致 |

## 发现清单

### F1 · 新建 session 5s 超时报错（重点，命中 #1259 区域）
- **严重度**：高（挡住"新建 session"这条主路径 + 连带 socialware 装/卸等）
- **复现**：Overview / Chat → 新建 session → 填名称 + 选模板 → 创建
- **两次都超时**：① `template=hello, short_name=test-new-session`；② `template=default, short_name=newtest2` → **说明不是 hello 专属，是通用 create_session 超时**
- **报错**（截图 `evidence/a2-create-timeout-default-template.png`）：
  ```
  创建会话失败：{:create_session_exit, {:timeout, {GenServer, :call,
    [#PID<0.2970.0>, {:ezagent_dispatch, %Ezagent.Invocation{
      target: workspace://ezagent?action=workspace.create_session, mode: :call,
      args: %{template_name: "default", short_name: "newtest2"},
      ctx: %{caller: entity://ezagent/user/chen_ruihua, caps: MapSet.new([])}}}, 5000]}}}
  ```
- **相关**：正是 #1259（create_session 冷 provision 超时）那一类。canary 每次 merge 自动刷新（~5min）、刷新即冷 —— 待避开刷新窗口复现，确认「每次都超时」还是「冷启后首次」。

### F2 · 超时但 session 已创建；overview / chat 两 tab 不一致
- **严重度**：中（一致性 / 迷惑用户）
- **现象**：F1 报超时后，那个 session **实际建成了** —— Overview「关键状态 Sessions = 3」，列表含 `test-new-session`（`session://ezagent/hello/test-new-session`）+ `hellotest`（截图 `evidence/a4-overview-3-sessions.png`）；但 **Chat tab 当时只显示 1 个 session**（截图 `evidence/a4-chat-only-1-session.png`）。
- = 客户端超时 ≠ 没建；且 overview 与 chat 的 session 可见性不同步。

### F3 · 新建 session 面板内容过长 + 不支持滚动 → 够不到「创建」按钮（UI blocker）
- **严重度**：中高（选某些应用时**完全无法创建**）
- **复现**：新建 session → 应用选 **Kanban 看板团队** → 面板列出多成员配置（kanban-assistant / dev-together / workspace… 每个带 Fresh/Reuse + Flavor），**内容超出面板高度、面板不滚动**，「创建」按钮在下方够不到、点不了（截图 `evidence/bug-create-panel-kanban-no-scroll.png`）。
- 建议：新建面板加纵向滚动 / 固定底部「创建」按钮。

### F4 · dark mode 下选中 session 高亮配色错误
- **严重度**：低（视觉）
- **现象**：深色模式下，左侧列表**选中的 session** 是一整块刺眼的**亮黄色**背景（`/Socialware-Install-Chat/Newest`），没适配 dark mode（浅色模式下这个黄是正常选中样式）（截图 `evidence/bug-darkmode-yellow-highlight.png`）。

### F5 · 用户下拉 >「My capabilities」点击无反应
- **严重度**：低
- **复现**：右上角用户名下拉 → 点「My capabilities」→ 无任何反应（dead menu item）。

### F6 · 新建 agent 详情页 Keys / Caps / Extensions 三个 tab 全部飘红原始错误 atom
- **严重度**：中高（配 key 是 agent 调 LLM 的前提；三 tab 全废 = 新建的 agent 基本没法配）
- **复现**：Agents → 新建的 agent（`entity://ezagent/agent/chenarvis`）→ 逐个点 tab：
  - **Keys** → 红字 **`:failed`**；填 Provider=`deepseek`、API key=`sk-…` 点「Save key」→ **无反应 / 没保存**（截图 `evidence/f6-agent-api-keys-failed.png`；录屏 Desktop `录屏2026-07-09 14.44.51.mov`）
  - **Caps** → 红字 **`:unauthorized`**，表格空（`evidence/f6-agent-caps-unauthorized.png`）
  - **Extensions** → 红字 **`:unauthorized`** + "No extensions available."（`evidence/f6-agent-extensions-unauthorized.png`）
- **线索**：`:unauthorized` 与 F1 create 报错里 `caps: MapSet.new([])`（调用者空 caps）呼应 —— 可能是 `chen_ruihua` 在 canary 上 caps 没配全，或 agent 详情读取的 authz 有 bug。无论哪种，**UI 都不该把 `:failed`/`:unauthorized` 原始 atom 直接飘给用户**。
- 建议：① 查调用者 caps 是否该有；② agent 详情读取 authz；③ UI 把原始 atom 换成可读错误 + 保存反馈。

### F7 · 新建 agent 表单里有两个 tools 配置框（重复/混淆）
- **严重度**：低（表单混淆）
- **复现**：新建 agent（flavor `cc`）→ CC CONFIGURATION 区里同时出现两个 tools 输入：① 右上角标 **`Tools`** 的框；② Permission mode 下面标 **`tools (comma-separated list)`** 的框 —— 不知道该填哪个 / 是否重复（截图 `evidence/f7-create-agent-two-tools-fields.png`）。
- 建议：合并成一个，或标清两者区别。

### F8 · 新建 cc agent "logged out"，UI 无自助完成凭证的路径（已并入 #1288）
- **严重度**：中高
- **现象**：新建 **cc（Claude Code）** agent 后显示 "Credential: Logged out —— 无 `.credentials.json`，agent 从未登录（`claude /login`)"。UI 上**没有自助完成登录的入口**：`claude /login` 是交互式 OAuth、托管环境无 UI 入口；Agent API Keys 路又坏（F6 `:failed`），且 cc 用 Claude OAuth 不是 provider key。→ designer 从 UI 完不成 fresh cc agent 配置。
- **处理**：与同事 **#1288**（cc agent 不继承 host Claude 凭证）重复 —— UX 角度已并入 #1288、原 #1283 已关；沾 **#396**（onboarding UX）。
- **证据**：录屏 ruihua Desktop `录屏2026-07-09 14.44.51.mov`

### F9 · canary 邮箱 magic-link 登录收不到邮件（#1289）
- **严重度**：中（email 登录这条路走不通）
- **复现**：https://canary.ezagent.chat/ → 选"邮箱接收登录链接" → 输入邮箱 → 提交 → **邮箱一直收不到登录邮件**，无法完成登录。
- **线索**：canary 可能 SMTP 未配置/未真发信（有 `admin.smtp.*` 配置面）。密码登录可能仍可用，这里专指 email magic-link 路径。

### F10 · 移除 session 成员点确认后无反应，成员仍在（#1290）
- **严重度**：中（成员管理坏了）
- **复现**：`session://ezagent/default/test` → 邀请 黄佳佳(gagameow) → 点该成员的「移除」→ 弹窗 → 确认移除 → **无反应，成员仍在 session**（仍显示 6 成员，debug `"members": 6`）。
- **线索**：确认后静默 no-op（无报错、未移除）；疑 `workspace.member.remove` 派发没接上/静默失败。
- **证据**：`evidence/f10-remove-member-noop.png`（录屏在 ruihua Desktop `录屏2026-07-09 16.48.21.mov`）

### F11 · session 视图多个控件点了没反应（#1291）
- **严重度**：中（一批功能点不动）
- **复现**：session 内点以下控件均**无反应**：**Bindings** tab · **路由** tab · **重启 agent runner** · 右上角**复制样 图标按钮**（挨着 `···`）。
- **线索**：Bindings/路由 疑 `session.view.switch`；重启疑 `session.orchestrator.restart` —— 可能同一根（派发没接）或各自独立，先合并给 triage。控件位置见 `evidence/f10-remove-member-noop.png`。

### F12 · workspace 切换器显示 "No workspaces"（补入 #1274）
- **严重度**：中（0710 续测）
- **复现**：点左上角 workspace 切换器下拉 → 列表显示 **"No workspaces"**，但你**就在 ezagent 工作区**（头部 `ezagent / ezagent`、会话标"ezagent 工作区"、右栏 工作区=ezagent）→ 当前 workspace 根本没出现在列表里。
- **处理**：**= #1274（zyli：Workspace switcher shows incorrect workspace list）的具体实例** → 已把 repro + 证据补进 #1274，不另开。
- **证据**：`evidence/f12-workspace-switcher-no-workspaces.png`

## flaky 复现（B）
- 网页对话页反复进出 + 发消息：**暂未复现**偶发不刷新 / 卡住。继续留意。

## 其余自由探索（C）
- socialware 装 / 卸等：**大半受阻** —— A2/F1 建不出新 session，很多路径走不到；F1 修后可续。

## 备注
- 官网(stable) 的 hello 属已知（旧 Definition，zhaomato 今日重建中），本轮以 canary 为准。
