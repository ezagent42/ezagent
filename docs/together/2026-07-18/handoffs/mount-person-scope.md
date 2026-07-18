# Handoff: MountRow person-scope 扩展(domain_session infra,㊵ 人本位前置)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** an independent developer
> **Tracking:** 开工单 v2 终版 infra 清单 #3 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** brainstormed —— **过 Allen 后开工**(新 infra 决策,非 D1-D6 已拍范围)

## 0. Mission
分享接收要从「发给目标会话的 assistant」改成「发给点击者本人」(人本位,㊵),但挂载表 `MountRow` 自然键含 session——**没有 person-scoped 挂载行的位置**。给 Mount infra 定一个 person-scope 约定(零 kanban 字面),让「个人持有的板钥匙」也有 SoT 行,删板撤钥匙链路不悬空。

## 1. Required reading
1. Skill `ezagent-developer` + `ezagent-socialware`。
2. `docs/notes/2026-07-17-xy-review.md` §1(㊵ 三层根因,尤其 ②「前置(新工作项)」段)。
3. `apps/ezagent_domain_session/lib/ezagent/socialware/mount.ex` moduledoc(mount=mint+落表 两块拼装)。

## 2. Locked decisions(上游已定,本 handoff 不重开)
| # | Decision | Value |
|---|----------|-------|
| 1 | 人本位方向 | 用户钉死:分享=钥匙给点击者本人(㊵/allen-decisions 语境),本 handoff 只定**载体** |
| 2 | 不许绕表 | **禁止**绕开 MountRow 只 `CompositionCaps.mint_cap` 裸发——⑲ `delete_board` 靠 `unmount_all_for_target`(mount.ex:100-128)按行撤钥匙,裸发的 person cap 删板后悬空 |
| 3 | 零 kanban 字面 | infra-vs-business 铁律:domain 改动通用参数化,kanban 语义留 plugin |

## 3. 现象/原因(现读锚点)
- **现象**:`ShareReceive.receive_shared_board/3` 只能把只读钥匙发给目标会话的 `kanban-assistant`(share_receive.ex:79 `Mount.mount(session_uri, board_uri, assistant_uri, ...)`),点击者本人拿不到钥匙;人本位 tab(=持钥板集合)无从谈起。
- **原因**:`MountRow` 自然键 = `(session_uri, target_uri, grantee_uri, behavior)`(mount_row.ex:42-46,**含 session**),`Mount.mount/6` 第一参就是 session——个人(跨会话)持钥没有表位置。
- **波及**:join 补发(D1)读 `MountRow.list_for_session/1` 按行补发;person 行的 scope 语义必须让 reconcile(`reconcile_session_mounts`,mount.ex:197)与 join 补发都能正确区分「会话行」vs「个人行」。

## 4. Design(两案,请 Allen 择一)& plan
- **案 a(哨值)**:person 挂载行 `session_uri` 放哨值(= grantee 本人 URI)。零 migration,但语义靠约定,`list_for_session` 需过滤哨值。
- **案 b(scope 列)**:`socialware_mounts` 加 `scope` 列(`:session` | `:person`,默认 `:session`),person 行 `session_uri` 可空或留来源会话作审计。一次 migration,语义显式,查询各走各。**倾向 b**(显式优于哨值,查询/审计不易错)。
- **将来折 CompositionBinding 时平移**:mount 折 `CompositionBinding`(挂载与声明式 composition 双轨合一)已挂 D6/#1394 永久线。scope(session/person)是**挂载概念自身的维度**,不是 MountRow 载体的私货——届时 person-scope 语义随行平移进新载体,不重开设计。案 b 的显式 `scope` 列正好让这次平移是机械搬迁(列对列),这也是倾向 b 的加分项。
- Plan:单 PR——migration(若 b)+ `Mount` API 扩展(如 `mount_for_person/5` 或 opts `scope:`)+ `unmount_all_for_target` 覆盖 person 行 + reconcile/list 语义划清 + 单测。

## 5. Definition of Done
- [ ] person-scope 挂载可落行、可按 target 撤(`unmount_all_for_target` 单测覆盖 person 行——删板后 person cap 不悬空,goal-derived 自 ⑲ SoT 约束)
- [ ] `list_for_session/1` / `reconcile_session_mounts/1` 语义不被 person 行污染(现有测试零回归 + 新增区分测试)
- [ ] 零 kanban 字面(grep `kanban` 在 diff 中为 0——arch 铁律)
- [ ] 消费面验证:kanban `ShareReceive` 改 person mount 后,点击者 tab 见板(此 e2e 在 PR-K 侧勾,这里登记为跨 PR parity 项)
- [ ] All gates green(arch.scan/doc.scan/uri_query.scan/check_invariants/format/test/:ezagent_plugin_check)
- [ ] CI green + rebased on `main`

## 6. Discuss-first vs Deferred
**Discuss-first(开工闸):** 案 a vs 案 b——Allen 择一;person 行的 `granted_by`/workspace 语义确认(仍=target data_owner,#154 不变?)。
**Deferred:** person 挂载的到期/清理策略(无属主会话消亡时)——挂 #1394 线;mount 折 CompositionBinding 本体(D6 永久线,届时 person-scope 平移,见 §4)。
**Never deferred:** SoT 约束(决策 2)。

## 7. Conflict-avoidance / 8. Merge model / 9. LOC
文件面:mount.ex / mount_row.ex / migration;与 D1 helper 有读依赖(先合本 PR 更顺)。独立分支 PR → `main` Allen 审。估 ~120-200 LOC。开放问题见 §6。
