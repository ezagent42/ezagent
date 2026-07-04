# Handoff → Allen · hello 迁移到「框架 session 编排器」— 架构决策请求

> **From:** zhaomato (via Claude) · **Date:** 2026-07-03
> **Branch:** `feat/hello-orchestrator-0703`(基于 concierge 工作 `b573ba6e` / PR #1134)
> **Type:** 架构决策 / research handoff —— **不是可直接 build 的 handoff**;需要 Allen 先定方向,才动手。

## 目标(诉求方:zhaomato / lead)

把 hello vertical 从「自己搞的协调」迁到**框架的 session 编排器**:
- 现状:hello 直接 `spawn` builder(`Ezagent.Entity.HelloBuilder`)+ concierge(`Ezagent.Entity.HelloConcierge`)成员,`EzagentWeb.Socialware.SessionFeedChannel.dispatch_post` 里按身份 @mention 路由(拥有者→builder、非拥有者成员→concierge)。
- 想要:让**框架编排器动态管理(增删)**这两个 agent,**用户使用感受不变**。
- lead 补充:一个 session 顶多加这两个 agent,除非以后业务扩展。

## 研究结论(两轮 Explore,已核对代码)

### 1. 编排器一定是个 LLM agent —— 没有「纯静态配置」模式
cc-orchestrator(`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/`)是**每 session 一个的 LLM agent**,读 `ezagent-session-orchestrator` skill,用 MCP 工具做决策。没有「只 seed 静态规则、不跑 LLM」的档位。
- `orchestrator_role.ex:64–129`(persona 教它调工具)、`orchestrator_bootstrap.ex:81–95`。

### 2. 路由规则表达不了「拥有者→builder、其他人→concierge」
matcher 只有 `from(uri)` / `mention(uri)` / `text_contains` / `text_matches` / `always` + 组合(`ezagent_core/.../routing/matcher.ex:49–58`)。**没有按 owner / 按角色的 matcher**;而 owner 是**运行时状态**(session slice),规则是 seed 时静态的。→ 要么编排器 LLM 在首条消息时读 owner 再动态 `define_rule_set_rule`(有 LLM 成本、且不稳),要么就表达不了。

### 3. ⛔ **BLOCKER**:managed member 只能是 `Entity.Agent`,hello 的自定义 Kind 装不进去
- `add_managed_member(source_agent_template_uri, …)`(`orchestrator/tools.ex:134–186`)+ 模板成员声明 `%{role_name, source_template_uri, in_session_template}` 都要 **AgentTemplate**。
- session creator 的模板成员 provision(`session_creator/template_team.ex:80–92`)**用预构造的 `entity://agent/<name>` URI 当成员,并忽略 Template Class 实际返回的 workers**（第 92 行 `{:ok, %{fresh?: fresh?}}` 把 `workers` 丢弃）。member URI 恒为 `Ezagent.URI.agent(ws, name)` = `entity://agent/...`。
- hello 的 builder/concierge 是**自定义 Kind**（`type_name: :hello_builder` / `:hello_concierge`，URI `entity://hello_builder/...`）—— **类型对不上**，模板成员系统认不了。（现在它们能冷启动复活，是靠 `application.ex` 的 `agent_flavors` + `template_class: nil`，那条路**不支持模板 spawn**。）

## 需要 Allen 定的架构决策 —— 两条路

### 选项 ① —— hello 本地改:builder/concierge 改成 `Entity.Agent` + flavor(带 `template_class`)+ Template Class
- **不动 core**：hello 自己注册 2 个 Template Class + 改 `agent_flavors`（`kind:` HelloBuilder → `Ezagent.Entity.Agent`，加 `template_class`）+ `template_classes/0`。
- **代价**：
  - builder/concierge 从「专属 Kind」变「通用 `Entity.Agent` 挂 hello 行为」，**丢掉 URI 类型语义**（都成 `entity://agent/...`）。
  - **必须先坐实**：`Entity.Agent` 能不能承载 hello 的**非-PTY** page-gen 行为（`Behavior.HelloBuilder` → `EzagentPluginHello.Generator` → drive Surface）。⚠️ 探查子 agent 给的实现把它塞进 cc 的 **PTY** spawn 路径 `CcAgent.Spawn.spawn_for_local_pty`，**大概率是错的**（hello builder 不是 PTY/cc agent）—— 这一步是 ① 成不成立的关键，动手前必须验证。
- 影响文件：hello 新增 2 个 Template Class；改 `application.ex`（`agent_flavors` / `template_classes`）+ `app.ex`；弃用 `entity/hello_builder.ex` / `hello_concierge.ex` 的 Kind（**behavior 文件保留**）。

### 选项 ③ —— 改 core:让 session creator 用 Template Class 返回的真实 workers
- 改 `template_team.ex`（不再丢弃 `workers`，用它当成员），这样**自定义 Kind 也能当模板成员**，hello 不用重写 agent。
- **代价**：动的是**共享的 session 创建路径**，影响所有 flavor（cc/codex/…）；风险大；属 core/架构改动 —— 正是要 Allen 拍的那类。

> 选项 ②（编排器只管别的成员、builder/concierge 仍直接 spawn）不满足诉求，略。

## 一个降风险的设计约束(无论 ① 还是 ③ 都建议照此)

为保住「UX 不变 + 零 per-message LLM」：
- **初始团队**（orchestrator + builder + concierge）**静态声明在模板 `members`**（`in_session_template: true`），建 session 时**确定性 provision** —— 框架 `default` 模板就是这么声明 orchestrator 成员的（`ezagent_domain_instance_message/application.ex:565–652`）。
- **路由仍走确定性 `dispatch_post`**（owner→builder / 其他→concierge 的 mention），**不改用编排器 LLM 路由**（规避第 2 条的坑）。
- 编排器平时**休眠**（普通消息不 mention 它 → 不跑 LLM，无成本），**只有真要动态增删 agent 时**才叫它出来。
- 这样：成员归框架编排器体系管（可增删/存模板版本/migrate），但当前 2-agent 场景行为和成本跟现在一样。

## 请 Allen 定

1. 走 **①（hello 本地重写 agent）** 还是 **③（改 core session creator）**?
2. 若 ①：接受 hello agent 丢掉自定义 Kind 类型、变 `Entity.Agent` + behavior 吗?（且需先坐实 page-gen 行为能挂上去，不走 PTY 路径）
3. 若 ③：接受动共享 session 创建路径、影响所有 flavor 的风险吗?
4. 或结论是「现在不值得迁,维持现状,等真要动态团队再上」?

## 现状锚点(前置依赖)

- builder + concierge + 确定性路由 + 「发布为模板」等,在 **PR #1134**(分支 `feat/website-hello-0702`)**未合并**。本迁移分支基于其上。
- 下方引用行号基于「当前 main + PR #1134」。

## 引用（file:line）

| 主题 | 文件 | 行 |
|---|---|---|
| BLOCKER：丢弃 workers、用预构造 agent-URI | `ezagent_domain_session/.../session_creator/template_team.ex` | 80–92 |
| Template Class 返回 `{workers, fresh?}` | `ezagent_domain_session/.../agent/template_spawn.ex` | 232–240 |
| `add_managed_member` 签名（要 AgentTemplate） | `ezagent_domain_session/.../orchestrator/tools.ex` | 134–186 |
| `define_rule_set_rule` | `ezagent_domain_session/.../orchestrator/tools.ex` | 559–614 |
| matcher 类型（无 owner/role matcher） | `ezagent_core/.../routing/matcher.ex` | 49–58 |
| 编排器一定是 LLM（role/persona） | `ezagent_plugin_cc/.../orchestrator/orchestrator_role.ex` | 64–129 |
| `default` 模板静态声明 orchestrator 成员 | `ezagent_domain_instance_message/application.ex` | 565–652 |
| hello 现有 flavor（`template_class: nil`） | `ezagent_plugin_hello/.../application.ex` | 64–80 |
| hello 现有路由 | `ezagent_web/.../socialware/session_feed_channel.ex` | 352–381 |
