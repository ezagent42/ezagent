# Handoff: provision deadline —— ㊷ create_session 5s 超时(world 小 infra + 泛化提案)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** an independent developer
> **Tracking:** 开工单 v2 终版 infra 清单 #5 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(caller 一行修,样板已在 main;泛化=提案记 Allen 线**不开工**)

## 0. Mission
world UI 建会话在慢机器/冷启动下撞 5s 默认 deadline 半途崩(㊷,同 e2e bug ⑨ 的病)。修 = world caller 给 provisioning 透传管道补 `deadline_ms: 30_000`——一行,样板是 ⑨ 修(`mount.ex:169-170`)。**因 `conversation_actions.ex` 是 world 共享框架文件,按铁律归 infra 单独 PR,不进 kanban PR。**

## 1. Required reading
1. Skill `ezagent-developer`。
2. `git show ff8d44b44`(⑨ 修样板:Mount.provision 给足 30s deadline)。
3. 开工单 §四 ㊷ 行(补挖记录)。

## 2. Locked decisions
| # | Decision | Value |
|---|----------|-------|
| 1 | 修法 | caller 侧传 `deadline_ms: 30_000`,复用现成透传管道 `Provisioning.maybe_put_deadline_ms`(domain_workspace provisioning.ex:66-81)——**不改 provisioning 默认值** |
| 2 | 泛化 | 「provisioning 全线默认 deadline」属架构口径变更 → **提案记 Allen 线,本 PR 不做**(2026-07-18 用户修正段拍定) |

## 3. 现象/原因(现读锚点)
- **现象**:world 建会话(尤其带 socialware 物化的)超 5s → GenServer.call timeout 崩,留孤儿态。
- **原因**:`do_create_session`(world `conversation_actions.ex:349`)→ `Ezagent.Workspace.create_session/3` 的 ctx 没传 `deadline_ms`,吃 5s 默认;透传管道现成没人用。2026-07-18 grep:world 侧零 `deadline_ms`。

## 4. Plan
单 PR 一件事:`do_create_session` ctx 加 `deadline_ms: 30_000`;顺手 grep world 其余 provisioning caller(create_agent 等)同病同修(枚举进 PR 描述)。文末附「泛化提案」段给 Allen(默认 deadline 应否下沉 provisioning 层)。

## 5. Definition of Done
- [ ] world 建会话(含 socialware install 物化)在 >5s 场景不再 timeout——e2e:dev 栈真 UI 建带模板会话成功(agent-browser,慢路径可用 sw 物化会话复现)
- [ ] world 侧 provisioning caller 全枚举(grep 清单进 PR 描述,parity == ∅)
- [ ] 泛化提案段落在 PR 描述,@Allen
- [ ] All gates green + CI green + rebased on `main`

## 6. Discuss-first vs Deferred
**Discuss-first:** 无(方向已定,机械修)。**Deferred(有靶):** 泛化 → Allen 线。**Never deferred:** caller 枚举完整性。

## 7-9. Conflict / Merge / LOC
文件面:world `conversation_actions.ex`(+同病 caller);world 改动 → 登记 world-coordination in-flight。独立小分支 PR → `main`。~5-15 LOC。
