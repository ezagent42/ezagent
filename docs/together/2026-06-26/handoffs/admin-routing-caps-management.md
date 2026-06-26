# handoff · 2026-06-26 · Admin 路由规则管理 + Caps 授权 UI(需 lead 定语义)

> **来源**:FP5 入口完善期,zyli 排查 admin 各页"只读、无动作"。其中 Routing 规则
> 管理 + Caps 授权两项触及核心/架构决策,**需 Allen 定语义后再实现**。
> **状态**:zyli 经用户(zyli-developer)授权**试做过**两者,**已回退**(未验证 + 撞 #137)。
> 本 handoff 把已摸清的后端接线 + 阻碍交给 lead,省去重复调研。
> **建议 owner**:Allen(路由/CapBAC 语义)。

## 背景

admin `/routing` 与 `/admin/caps` 当前是纯只读展示。操作员希望能**管理路由规则**
(增/删/启停)和**授予/撤销 cap**。zyli 试做后发现两者都不是"纯 UI 能独立完成"。

---

## 一、Caps 授权(`/admin/caps` 加 grant/revoke)

### 后端支持(已存在)
- `Ezagent.Identity.Grant.grant_cap(%URI{} = target, %Capability{} = cap, {:held_by, caller})`
  → 经 `Invocation` dispatch `:grant_cap`。对称的 `revoke_cap/3` 也在。
- `Ezagent.Capability.Parser.parse(spec_str, caller)` → `{:ok, [%Capability{}]}`(`agent_actions.ex:70` 已用)。

### 🔴 阻碍 —— 与 Decision #137 直接冲突
`domain_session/.../orchestrator/tools.ex:85` 明写:
> **No `:grant_cap` tool（Decision #137 — cap delegation only happens at [agent 创建]）**

即:**cap 委派被有意限定在 agent 创建时**(`grant_initial_caps`,`{:held_by, caller}` 语义 =
"我把我持有的 cap 委派下去")。**不存在"admin 给已存在实体授予任意 cap"的干净模型**。

zyli 实测:用 `grant_cap(target, cap, {:held_by, admin})` dispatch 返回 `granted` + 发了
`cap_granted` 通知,但**审计里动作记在 admin 而非 target**,语义存疑(像是 admin 自己持有/委派,
而非"授予 py_default")。加上 py/cc 的 `list_caps` 被 S5 挡住(`:unknown_action`/`:activate_timeout`),
**无法从 UI 验证 cap 真落到目标**。

### 需 Allen 决定
1. 是否要"operator 给已存在实体授予任意 cap"这个能力?若要,它**改写 #137** —— 需要新的
   授权语义(不是 held_by 委派),且要定 cap 范围/审计/可撤销性。
2. 还是维持 #137(cap 只在创建时给),admin 页 caps 保持只读参考?

---

## 二、Admin 路由规则管理(`/admin/routing` 加增/启停/删)

### 后端支持(已存在)
- dispatch 动作:`add_rule` / `enable_rule` / `disable_rule`(session 级经会话面已在用,见
  `conversation_actions.ex` `add_routing_rule`/`toggle_routing_rule`)。
- 全局 target 规范:`system://routing/default?action=add_rule`(`uri.ex:592`、`behavior/routing.ex`)。
- `Ezagent.Routing.RuleStore`:`add/4` `list/1` `delete/1`;matcher 4 型
  (`always`/`mention`/`from`/`text_contains`,见 `Ezagent.Routing.Matcher`)。
- admin 页 rules = `RuleStore.list(MentionRouting)` = **全局规则库**(含 `system_default`)。

### 🔴 阻碍 —— 全局规则高风险 + dispatch target 命名不确定
1. admin 页改的是**全局 MentionRouting**(`system_default = $session_users, $mentions`)。
   删/停它会**断掉全局 @ 投递**,正是 **#990 未决**的核心路由区。
2. **会话级**规则已有图形入口(会话页右侧 ROUTING 面板,`session.routing.add`)——低风险、已可用。
3. zyli 试做全局 toggle:`URI.with_action(system://routing/default, :routing, action)` 这个 target
   构造**没有现成范例**(session 用 `routing.<action>` 命名空间,全局用裸 `add_rule`),**未跑通**
   (toggle 后规则状态没变);加上当时 10042 端口被并发 worktree 服务争用,**无法可靠验证**。

### 需 Allen 决定
1. 全局路由规则的 operator 管理是否纳入 #990 一并设计?
2. 若做:确认全局 dispatch target 的正确命名空间 + 是否保护 `system_default`(防误删断投递)。
3. 或:只把已有的**会话级**路由管理做得更显眼,全局规则维持 seed/dispatch?

---

## zyli 已摸清的接线(实现时可直接用)

- world 侧 admin 动作白名单:`world_live.ex` `@admin_actions` + `AdminActions.handle_dispatch`。
- 前端 dispatch:`AdminSurface` 的 `onAction` → `pushEvent("world:dispatch", {action, args})`。
- 刷新 state:`AdminActions` 用 `push_event("world:state", fragment)`(见 `put_settings`)。
- caps 解析 + 授予:`Capability.Parser.parse/2` + `Identity.Grant.grant_cap/3`。
- 路由 dispatch:仿 `conversation_actions.dispatch_session_routing/4`,全局 target 待 §二.3 厘清。

## 参考
- FP5 巡检/入口清单:PR #1019、#1025
- Decision #137:`domain_session/.../orchestrator/tools.ex:85`
- #990 路由缺口:见 PR #1019 评论区 S5 handoff 关联
