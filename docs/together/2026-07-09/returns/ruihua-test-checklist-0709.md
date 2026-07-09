# canary 探索测试清单（据 origin/main `96af00d4`，2026-07-09）

> 用户视角、尽量全。每条 = 一个可点/可试的操作。标注：**[今日修复]** 重点复验 · **[已知bug Fx]** 测到即复验 · **[需admin]** 你空 caps 可能 :unauthorized（本身也是发现）。
> 环境：canary.ezagent.chat · `chen_ruihua` · workspace `ezagent/ezagent`。顶部 nav：Chat / Agents / Manage / Overview + New agent + 用户下拉 + 主题切换。⚠ canary 每次 merge 自动刷新（~5min）。

## 1. 会话 Sessions（`/sessions`, Chat）—— 今日修复重点区
- [ ] 看会话列表；用「筛选会话/模板/状态」搜/筛
- [ ] **新建 session**：填名称 → 选模板（9 个）→ 选「应用」socialware → 每个成员 Fresh/Reuse + Flavor → project_cwd（默认/自定义）→ 创建 · **[已知bug F1 超时 / F3 面板不滚动够不到按钮]**
- [ ] 打开 / 切换 session
- [ ] **发消息**（`chat.send`）· **[今日修复 A1 ✅]**；载入更早消息；`@` 提及成员
- [ ] 会话内切 tab：**对话 / Bindings / 路由 / 成员 / 预览**
- [ ] 成员面板：看成员 + 状态；**装 / 卸 socialware**（installed 行 → 卸载）· **[C2 zyli 也在测]**
- [ ] 路由：加路由规则 / 开关规则（`session.routing.add/toggle`）
- [ ] **fork**：复制配置建新 session（`session.fork_config`）· 原语已 ✅
- [ ] invite：邀请成员进同一 session（`session.invite`）
- [ ] **发布为模板 / socialware**（`session.publish_template`）
- [ ] 重启 orchestrator（`session.orchestrator.restart`）
- [ ] 打开 **PTY 终端**（`session.pty.open`）
- [ ] 切换会话视图（`session.view.switch`）；外部镜像（`external_mirror`）看/解绑
- [ ] **刷新 / 重进后会话列表还在吗** · **[今日修复 A3 ✅]**

## 2. Agents（`/identities/agents`）—— 撞了 F6/F7/F8
- [ ] 看 agent 列表
- [ ] **New agent**：选 flavor（cc 等）/ model / effort / permission mode / **tools**（⚠ **[已知bug F7 两个 tools 框]**）/ requested caps / project_cwd → Create
- [ ] agent 详情 6 个 tab：**Overview / Config / Keys / Caps / Extensions / Terminal**
  - [ ] Keys（`/api-keys`）：配 provider + API key（`agent.api_key.put`）· **[已知bug F6 :failed]**
  - [ ] Caps：看已授 caps · **[已知bug F6 :unauthorized]**
  - [ ] Extensions · **[已知bug F6 :unauthorized]**
  - [ ] Config：改配置（`agents.config.update/repoint/delete_path`）
  - [ ] Terminal：agent 终端页
  - [ ] 凭证/登录状态（logged out）· **[已知bug F8 无自助完成路径]**
- [ ] 删除 agent（`agents.delete`）

## 3. 身份 Identities · Users（`/identities/users`）· **[多为 需admin]**
- [ ] 看用户列表；新建用户（`/new`, `users.create`）
- [ ] 看某用户 / 改其 caps（`/:uri/caps`）
- [ ] 启用 / 禁用用户（`users.enable/disable`）；设密码（`users.password.set`）；改 profile（`users.profile.save`）

## 4. Workspaces（`/workspaces`, `/workspaces/:name`）
- [ ] 看 workspace 列表；切换 workspace（左上角 `ezagent / ezagent` 下拉）
- [ ] workspace 详情 → **Session templates 面板**：存模板 + 勾「**Public socialware app**」（`workspace.template.save`）—— socialware 发布入口
- [ ] 移除 workspace 成员（`workspace.member.remove`）

## 5. Plugins（`/plugins`）
- [ ] **Feishu**（`/plugins/feishu/bindings`）：绑定 / 解绑（`feishu.bind/unbind`）
- [ ] **Kanban**（`/plugins/kanban`）：建看板 / 选看板 / 加·移·改名·删节点 / claim·unclaim / 设 stage·status·metric / register PR / attach artifact·code / Miro creds + sync / board config（一大套 `kanban.*`）
- [ ] **KB 知识库**（`/plugins/kb`）
- [ ] **Auto**（`/plugins/auto/:kind`）：凭证 auto-derive —— 默认源 / credential grant（`auto_derive.default_source.set` / `credential_grant.revoke`）· **与 F8 凭证相关，值得看**

## 6. Overview（`/overview`）
- [ ] 关键状态卡：Agents / Sessions / Workspaces / 实体 / Kinds 计数
- [ ] 推荐下一步；「可继续的 Sessions」→ 打开 · **[已知bug F2 overview vs chat 不一致]**
- [ ] 浏览 Sessions / 创建 Agent / 新建 Session 快捷入口

## 7. Profile / 用户下拉（`/profile`）
- [ ] 改显示名（`profile.display_name.edit/save/cancel`）
- [ ] 右上角用户下拉：**My capabilities** · **[已知bug F5 无反应]**、其它项挨个点

## 8. Admin（`/admin`）· **[需admin，你空 caps 大概率 :unauthorized —— 本身是发现]**
- [ ] logs / registry / snapshots / templates / caps / audit·authz / routing / settings 挨个点
- [ ] SMTP 设置（`admin.smtp.save/test/update_recipient`）

## 9. 命令面板 cmdk
- [ ] 快捷键唤起命令面板（`cmdk.open`）→ 搜索 / 跳转 / 选择（试常见快捷键 ⌘K）

## 10. socialware 公开面（匿名视角）
- [ ] 发布一个 public_view session 后，用**无痕/登出**访问它的公开面：`/socialware/chat?session_uri=...`、`/socialware/external`
- [ ] 匿名能否围观 / 参与

## 11. 主题 / 响应式 / 通用体验
- [ ] dark ↔ light 切换 · **[已知bug F4 dark mode 选中项配色]**
- [ ] 窄窗口 / 缩放看响应式；长面板能否滚动（呼应 F3）
- [ ] 任意页 hover / loading / empty / 报错态是否友好（呼应 F6 裸 atom 泄露）

## 12. 官网 hello（`/hello`，stable/canary）
- [ ] hello 对话面：greeter 问候 + 真实 LLM 回复（#1243）· **[今日修复 A4]**（官网 stale 属已知）

---

## 今日修复重点（优先复验）
A1 发消息延迟 ✅ · A2/F1 新建 session ❌ · A3 列表持久 ✅ · #1243 hello · flaky 网页对话反复进出（B，未复现）

## 已知会撞到的 bug（测到即复验，见 return）
F1 建 session 超时 · F2 overview/chat 不一致 · F3 建面板不滚动 · F4 dark mode 配色 · F5 My capabilities 无反应 · F6 agent Keys/Caps/Extensions 报错 · F7 两个 tools 框 · F8 agent logged out 无自助路径
