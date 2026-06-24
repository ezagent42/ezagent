# Return: F14 — Always 规则自环 + UI Disable noop（调查结论 + 重归属）

> **Task:** F14 — `fix/always-rule-self-loop-and-disable-noop`
> **Branch:** `fix/always-rule-self-loop-and-disable-noop`
> **PR:** (push 后补)
> **Dev:** @李震宇 (zyli) + Claude（调查）
> **returned_at:** 2026-06-24 18:?? +0800
> **deadline:** —（非当日 `plan.md` 项；派生自验证 return 的 F14 finding）
> **deadline_status:** out_of_scope（同日 follow-up 调查）

## TL;DR

**F14 路由给我（@李震宇）的「world UI Disable 更新 ETS」部分，经端到端代码核查在当前 main
已正确——无 bug 可修。** 真正的缺陷是**核心循环防护**（@林懿伦 的部分）：`Always` 规则匹配了
agent 自己的回复 → 再路由回自己 → 洪泛。本 PR 是**调查结论 + 重归属**，不含代码改动。

## 核查链路（current main `cba79e47`，且验证基线 `cd0d4067` 即如此，期间未改）

| 步 | 代码 | 结论 |
|---|---|---|
| UI toggle | `Conversation.tsx:706-709` 传 `{id, table=MentionRouting, enabled=当前值}` | ✓ 正确 |
| world action | `conversation_actions.ex:362` `toggle_routing_rule` → 当前 enabled 则派 `:disable_rule`，table 经 `safe_table_atom` 正确还原 | ✓ 正确 |
| core handler | `behavior/routing.ex:187` `handle_disable_rule` → `RuleStore.disable(id)`(DB) + `RuleStore.load_into_registry(table)` | ✓ 已调 ETS reload |
| ETS reload | `rule_store.ex` `load_into_registry` = **清表(`RoutingRegistry` `delete_all_objects`) + 只重载 `enabled` 行**（PR #127 已修 stale-entry-on-delete bug） | ✓ disable 后规则从 ETS 移除 |
| resolver | `resolver.ex:77` `@default_routing_tables = [MentionRouting]` — 与 add/disable 的 table **完全一致** | ✓ 不再匹配被禁规则 |

→ **disable 后该规则确实从 live ETS 移除、resolver 不再匹配。** F14 描述的「UI Disable 未更新
live ETS RoutingRegistry」在当前代码**不成立**。

## 那验证当时为何观察到「Disable 不停、靠重启止血」？

根因是缺**自回复循环防护**：`Always→echo` + echo 回复又匹配 `Always` → 自环洪泛（实测
800→1168+ 条/数秒）。洪泛速度远超操作员点 Disable 的人手速度，且洪泛把 LiveView/进程刷满 →
disable 这一跳「看起来无效」；「重启」是洪泛进行时的核选项。**这是 send==receiver 自回复未被排除
的问题，不是 Disable→ETS 管线的问题。**

## 重归属建议

- **F14 真正的修复 = 核心循环防护**（routing resolver 应排除「发送者==接收者自身回复」的再触发，
  或对自环加阈值/防抖）→ **owner: @林懿伦**（core routing），非 world UI。
- F14 的「@李震宇 world UI Disable 更新 ETS」子项 → **判定 already-correct，关闭**（本 note 附代码链证据）。

## Gate / 验证

- 无代码改动 → 无新 gate。
- 建议 owner 在健康 server 复跑确认：加 `Always→echo` → 触发自环 → 验证「核心防护」止环；并旁证
  「点 Disable 确实从 ETS 移除规则」（本 note 的代码链已静态证明该跳正确）。

## 同 owner 其余 finding 收尾

F3 ✅ PR #949 · F10 ✅ PR #950（持久化待健康 server）· F13 ⏸ 待决策（chat feed 只读设计）·
F9 ⏸ 待决策（CapBAC `:bind`+`FeishuAllow` provisioning）· **F14 本 note：UI 部分 already-correct，
真因重归属 @林懿伦**。
