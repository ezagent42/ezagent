# Handoff: D1 — join 补发:shared caller-side confirmed grant helper(infra PR-B)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** an independent developer (human + cc/codex)
> **Tracking:** 开工单 v2 终版 infra 清单 #1 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(记录型 handoff——D1 方向 Allen 已拍,此文档备案现象/原因/plan 供过目)

## 0. Mission
新成员 join 一个已挂看板的会话后,既看不到 kanban tab、也没有本会话已挂板的钥匙(要人肉刷新/管理员代发)。修法 = 实现 todo.md「#161 A2 deferrals」推荐的 **shared caller-side confirmed grant helper**(唯一补发供给点),join 路径接入:member-cap confirmed grant 之后,按 MountRow `:operate` 行给新成员补 person keys + member view caps。

## 1. Required reading
1. Skill `ezagent-developer`(必)+ `ezagent-socialware`。
2. `docs/futures/todo.md` §「2026-07-05 — #161 A2 deferrals」(:55-85 附近)——helper 的形态约束权威。
3. `docs/together/2026-07-16/handoffs/allen-decisions.md` §D1(拍板原文)。
4. `docs/notes/2026-07-17-xy-review.md` §3(join 补发现状核对+人本位下范围重算)。
5. `dev-together` skill(工作流+本标准)。

## 2. Locked decisions(已拍,勿重开)
| # | Decision | Value |
|---|----------|-------|
| 1 | 补发形态 | **caller-side** confirmed grant(join handler 内 sync grant 死锁,5s timeout 实证——`Materializer.join_session_members` GenServer.call 超时) |
| 2 | 供给点 | **一个 shared helper**,不另起 grant 真相源(I12 paradigm-lock;fix-plan X2「第 N 个 grant 点=第 N 个不同步真相源」;ShareReceive 撞过,share_receive.ex:25-34 moduledoc 记录) |
| 3 | helper 做三件事 | member-cap confirmed grant + member view caps + mount `:operate` person keys(幂等;MountRow `:read` 行**不**扩散) |
| 4 | rule tag | `{:rule, :socialware_member_views, member}` ——名字请 Allen 补 Decision Log 条目 |
| 5 | 永久形态 | 仍归 #1394;本 PR 是 join 缺口修复 |

## 3. Architecture primer
- 死锁背景:join 内 sync grant 会卡死 session 创建(materialization-confined);唯一 deadlock-free 的 CONFIRMED grant 是 **caller-side**(`mount_participation_caps` + established-member revoke 已证),代价是散布 **~8 个 add-site chokepoint**。
- 已点名 4 个 add-site:**World LV**(`apps/ezagent_plugin_world/.../world_live` join 入口)/ **orchestrator participants** / **anon admission**(identity)/ **SessionCreator**(`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`);另 `approve_admission/3` 同病(重跑 do_join,同 async best-effort)。**实施第一步 = 盘出完整清单**。
- mount 补发数据源:`Ezagent.Socialware.MountRow.list_for_session/1`(domain_session mount_row.ex);铸钥走 `Ezagent.Socialware.CompositionCaps.mint_cap/4`(唯一 mint chokepoint)——helper 只是**驱动点**,不是新铸造口。
- view caps 现状:只有 installer(`Installation.grant_installer_view_caps/2`,installation.ex:348-385,session_creator.ex:725 调)和 anon(`anon_view_caps/1`)两路;登录后加入的普通成员两路都不覆盖——这就是 ㉜/㉟ 深层坑。

## 4. Design & phased plan
1. **Phase 0(研究)**:grep 全部 join/admission 驱动点,产出 ~8 add-site 完整清单(交 Allen 过目后进 Phase 1)。
2. **Phase 1**:helper 落 domain_session(单模块,幂等,abort/compensate on failure);SessionCreator + World LV 两个 add-site 先接。
3. **Phase 2**:剩余 add-site 接入(orchestrator participants / anon admission / approve_admission)。
4. **同车半件**:D3 render-cap baseline 发放走同一 helper(见 `D3-render-cap-baseline.md`)。

## 5. Definition of Done
- [ ] add-site 清单 = grep 盘出的全集(非手挑),文档化在 PR 描述——parity 证明:清单外零 join 驱动点
- [ ] 新成员 join 后**零刷新**见 tab + 本会话已挂板钥匙——agent-browser e2e(真 UI 两账号:A 挂板 → B join → B 即见)+ 截图为伴
- [ ] helper 单测:幂等(重复调用不重复发)/ `:read` 行不扩散 / 失败 compensate
- [ ] join handler 内零 sync grant(死锁红线)——代码 review 断言 + 现有 materialization 测试不回归
- [ ] All gates green: arch.scan, doc.scan, uri_query.scan, check_invariants, format, test, :ezagent_plugin_check(尤其 I12 `cap_self_store_paradigm_lock_test` / `cap_check_only_at_chokepoint_test`——helper 必须以**收编**而非**新增** grant 点的姿势过闸)
- [ ] CI green on PR head + rebased on `main`

## 6. Discuss-first vs Deferred
**Discuss-first:** add-site 完整清单(Phase 0 产出)交 Allen 确认;rule tag 名进 Decision Log。
**Deferred(lead-adjudicated):** 永久形态(#1394);orchestrator/anon add-site 若量大可拆 Phase 2 后续 PR。
**Never deferred:** caller-side 形态、单 helper 供给点、幂等性。

## 7. Conflict-avoidance
拥有:domain_session join/creator 路 + helper 新模块;碰 World LV join 入口(world)→ 按 `docs/guide/world-coordination.md` 登记 in-flight。与 PR-K 零文件交集;与 D3 半件同车。

## 8. Merge model
独立 infra 分支(如 `feat/join-replay-helper`),PR → `main` 由 Allen 审;PR-K 的 `applies_to?` 翻转排它之后。

## 9. Gates, LOC, open questions
新模块 1 + add-site 改 ~4-8 处,估 ~200-350 LOC。开放问题:① rule tag 定名;② approve_admission 是否并入 Phase 1(同病同修)。
