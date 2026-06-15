# AutoService v2 合并 — review 指南(feat/autoservice-v2-merge)

> 给 reviewer(+ 其 AI)的导航。基准 = `autoservice-dev`,从 PR #731 移植特性。方向决策见 `B-minimal-direction.md`(必读,解释为什么不是"CsOrchestrator Behavior + Turn-for-everything")。

## TL;DR

以 `autoservice-dev` 为基准,**B-minimal** 方向:bot 路径沿用 dev 现状;operator 接管走 Turn(门控正确);移植 #731 的内容管理 UI、CR 崩溃恢复、发布热更新、多租户隔离测试。**我们的合并面全绿**(cr 22 / autoservice 23 / liveview 6,lifecycle gate 绿)。

## 改了什么(按 commit)

**P0 — 方向 + operator(B-minimal)**
- `49d874e7` Session spawn 改 `SocialwareSession`(Turn 可用)
- `d1041ef7` operator 回复 compose 进 Turn(`operator_only`,不经 `chat.send`,不漏)+ 客户侧 visibility 过滤
- `002bc31b` operator 角色授予 Turn caps + `TurnAdapter` 用 operator 自己权威驱动(修 `:unauthorized`)
- `e0dd322d` 方向文档 `B-minimal-direction.md`

**P1 — 移植 #731 特性**
- `ab8cb2fc` **CR 崩溃安全**:dev 的 publish 原本不是崩溃安全的(flip-before-mark + 非原子 flip),改成 mark-before-flip + 原子 rename + `repair_current` 自愈
- `84ceca85` + `5471105e` 发布热更新:重渲 slow CLAUDE.md + fast prompt configure,接进发布按钮
- `ae486a96` **TenantAdminLive**(`/autoservice/admin`):slots/skills/preview/publish,admin cap-gate(dev 此前 0%)
- `4704b04a` 多租户隔离测试(4 项隔离全过)

**P2 — 收尾**
- `8f48fb64` seed `--tenant` 参数化
- `f64a6c2b` admin 导航链接(dashboard ↔ content edit)

## Review 重点

1. **operator 门控正确性**(核心)— `apps/ezagent_plugin_liveview/.../autoservice/operator_live.ex` + `operator_takeover_gating_test.exs`。operator 回复经 Turn(`compose` operator_only → `settle` customer_visible → CustomerFeed),**绝不经 `chat.send`**(否则经 raw `{:chat_message}` 广播漏给客户——这是我们修掉的 dev 真 bug)。test 证明 settle 前隐藏、settle 后可见。
2. **operator authz** — `roles.ex` operator bundle 加了 Turn caps(`kind: :session` + `behavior: Ezagent.Behavior.Turn`,匹配器按 Kind type_name 比 `kind`);`TurnAdapter` 用 operator caps 驱动,可审计,没碰 SystemPrincipal catalog。
3. **CR 崩溃安全** — `cr_engine.ex` `publish/1` + `repair_current/1` + `cr_repair_test.exs`。确认 mark-before-flip + 原子 rename。
4. **TenantAdminLive cap-gate** — 每个 write/publish handler 服务端再查 `can_write?`(不只是禁用按钮);sandbox-only 写,release 只经 `CrEngine.publish`。
5. **§11 / 不变式** — 我们的新代码无 SnapshotStore/EventLog/StateRebuilder import;refresh 不强制重启活 PTY(文档化 deferral)。

## 已知 + flag(都不是这次合并引入的)

- ⚠️ **dev 预存红**:`ezagent_plugin_content` 的 `ContentAdminTest` 在 `autoservice-dev` 上就 **10/11 失败**(`ContentAdmin` behavior 的 `write_soul_slot` 等 dispatch 没注册上)——用 dev 原版测试文件验证过,与本合并无关。建议 dev 分支作者 / 单独 follow-up。
- ⚠️ **dev 预存 stale 链接**:`TenantDashboardLive` 的 CR/Operators quick-links 指向 `/autoservice/tenant/:tid`,但真实路由是 `/admin/autoservice/tenants/:tid`。我们新加的 [Content Edit]/[Back] 用了真实路由;dev 原有的两条 stale 链接没动(超出 scope)。
- **给 Allen 的 flag**:(1) #730 producer gap(`spawn_plan` 读 model/endpoint 但无 producer);(2) `system://turn-adapter` catalog 条目现在无 caller(dead,可清理);(3) `AgentFlavorAttributes` 通用重水化该放 core(若将来上 Option A 统一门控时会需要)。
  - **(4) creator-grant 对系统主体 creator 不对称(core 真 bug)**:`Workspace.create_agent` 的 `grant_creator_manage_cap`([workspace.ex:917](../../../apps/ezagent_domain_workspace/lib/ezagent/workspace.ex#L917))无条件把 `identity.grant_cap` 投给 `ctx.caller`。当 caller 是系统主体(如 seed 的 `system://mix-task`)时,它没有活 actor 接收 → `:no_such_actor`,整个 create 致命失败。但系统主体本就持 `Manage :agent :any` 通配 cap,这个实例 grant 是**冗余**的;且 grant 发生在 [agent_create.ex:488](../../../apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex#L488),在 `invoke_or_rollback`(已 spawn + commit template)**之后、rollback 之外**,所以 agent 其实已经建好。**建议 core 修法**:`grant_creator_manage_cap` 在 creator 是 SystemPrincipal(或已持通配 Manage)时直接 skip(return `:ok`),不 dispatch。当前在 autoservice 插件层做了 interim 容忍(commit `8ba0f70`:match `{:creator_manage_cap_grant_failed, :no_such_actor}` → 视为成功),core 修好后可移除该容忍。这也是 fast agent(走 `add_template`,不碰 grant)能成而 slow/cc agent(走 `create_agent`)在 `--with-slow` 下失败的根因。

## 明确推迟(B-minimal trade-off)

- **门控非统一**:bot 即时可见(本就正确)、operator 走 Turn 门控。"bot 也统一门控" = Option A(独立 orchestrator 实体,#731 已 live 验证),作为单独可评估的后续升级(届时 flavor-cache 大概率已被 core 修掉)。
- AgentsConfig 编译期 module-attr → 运行期 `{:ok}/{:error}` 合约:dev 现状能用,低价值,推迟。
- slow cc 活 PTY 的强制热重启:需 sanctioned cc-runtime respawn dispatch(Allen 域)。
