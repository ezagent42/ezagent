# Re-route 实施发现:编辑 UI 是 per-page LV(不是 tenant_admin_live)

**日期:** 2026-06-17(夜间自主推进,goal:坐实 #819)
**前置:** [reroute plan](./2026-06-17-admin-ui-reroute-implementation-plan.md) · [phase1-3 execution](./2026-06-17-reroute-phase1-3-execution.md)

## 关键发现(写 E2E 测试时暴露)

为 Phase 2 写端到端测试时发现:**`tenant_admin_live`(`/autoservice/admin`)现在只是一个 overview 页**(render 667–756:侧栏 + 欢迎卡 + lint + `!can_write?` 横幅,**无任何编辑表单**)。它那 12 个写 handler(`save_soul` 等)**没有表单触发,是死代码** —— 佳哥近期重构(`e83eab6c layout tabs`、`e6f30856 persistent sidebar across all pages`)把编辑拆到了 per-page LV。

所以 **Phase 2(#819 `8acef41f`)re-route 的是死 handler**;真正带直接写/`can_write?` 缺口的是侧栏链接的那批 per-page LV。

## 真实写面 per-LV 状态

| LV | 路由 | 当前写法 | scope | re-route 状态 |
|---|---|---|---|---|
| **`fast_agent_live`** | `/…/agent/fast` | `File.write!` fast prompt,**无 cap 检查**(任何 admin 写任何租户)| 租户 | ✅ **已 re-route + E2E 测试**(本次)|
| `init_wizard_live` | `/…/init` | `File.write!` soul/slots/**glossary** + `KbStore.*` | 租户 | ⏳ 可做,但 **glossary 写 ContentAdmin 没有对应 action**(要补)|
| `platform_soul_live` | `/platform/soul` | `PlatformSoulStore.write_soul` | **平台** | ⚠️ 平台 scope,**不在 workspace/ContentAdmin 范围** → 需另一个平台 Behavior(可能 Allen)|
| `platform_skill_live` | `/platform/skills` | `PlatformSkillStore.write_skill` | **平台** | ⚠️ 同上 |
| `version_timeline_live` | `/…/versions` | rollback:`cp_r`(release→sandbox 恢复)+ 符号链接翻转 | 租户 | ⚠️ **语义不匹配**(见 ④)|

## ① 已做:`fast_agent_live` re-route(proof-of-concept)

- 新增 `EzagentPluginLiveview.Admin.ContentAdminClient` —— 共享客户端(`dispatch/5` + `writable?/2` + `load_caps/1` + `error_msg/1`),给所有 admin 编辑 LV 复用,避免每个 LV 重抄 dispatch/cap 逻辑。
- `fast_agent_live` 的 `save` 从 `File.write!` 改为 `ContentAdminClient.dispatch(..., :write_fast_prompt, ...)`,mount 加 `can_write?`(cap 检查)。**关掉了"任何 admin 写任何租户"的缺口**(原来零 workspace cap 检查)。
- E2E 测试 `fast_agent_dispatch_test.exs`(`@umbrella_only`,自带 seed):有 cap 的 admin 经 dispatch 写盘成功 / 无 cap 的 admin 被拒(不写盘)/ 直接 dispatch 解析+授权成功。

这条证明了 re-route 模式在**真实 live LV** 上端到端可行。剩下的 LV 照 `ContentAdminClient` 接即可。

## ④ revert/rollback:语义不匹配,需决策

`version_timeline_live` 的 `rollback` 干两件事:**(1)** 把 release/version 的 souls/slots/skills/kb/config `cp_r` 回 sandbox(恢复 sandbox 到该版本);**(2)** 翻转 `_current` 符号链接。
而 `ContentAdmin.rollback_version` → `CrRollback.rollback` **只做 (2)**(符号链接翻转)。
1:1 接上会**丢掉 (1) 的 sandbox 恢复** —— 真实语义变更,不能糊。
**需定:** rollback 到底该不该恢复 sandbox?要么扩 `rollback_version`(改契约 + 测试),要么新增一个动作。`revert`(单文件)在本 LV 没有,可能在 CR dashboard,另查。

## ③ 提案(不实现):operators → IdentityAdmin

`operators_live` 的 add/toggle/disable 是**授/撤 operator 权限**,不是文件写。照 ContentAdmin 模式应有个 `IdentityAdmin` Behavior,但它的 action 要走 **#814 `Ezagent.Identity.Grant.grant_cap_effect`**(identity/CapBAC 核心,Allen 地盘),比 ContentAdmin 的文件写复杂。**建议** re-route 方向被 endorse 后再建,且 design 先过 Allen。

## 结论

re-route 方向(UI 写 → Behavior dispatch + CapBAC)**在 fast_agent 上验证可行**。但 per-LV 现实比 #813 评估更碎:overview LV 是死的、平台 LV 是另一个 scope、rollback 语义要对齐、glossary action 缺失、operators 踩 CapBAC 核心。建议明天和佳哥(他的重构)+ Allen(平台 scope / CapBAC)一起定每个 LV 的处置,再逐个照 `ContentAdminClient` 接。
