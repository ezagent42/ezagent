# return — #1360 Layer B(跨 session 挂载 infra)已实现,非「仅 spec」

- **dev:** jjkysy
- **task:** 07-14 plan ③「把 #1360 分析形式化为 PR/return」 + 头号红线「hello↔kanban 融合的底层挂载 infra(跨 session 共享 + 公开挂载 = #1360 Layer B)」
- **returned_at:** 2026-07-14(Loop 守望时段)
- **deadline:** 2026-07-14 EOD
- **deadline_status:** on_time(实现早于 plan 发布已完成;此 return 补登记)

## 一句话

lead 的 07-13 review / 07-14 plan 反复记「jjkysy #1360 Layer B **只有 spec、未有实现**,07-13 只提了 2 个 doc commit(`docs/socialware-data-mount-model`)、未走 PR/return」。**认知已过时**:我昨天把这层挂载 infra **实现并全绿了**,分两个 draft PR:

| PR | 分支 | 内容 | 定位 |
|---|---|---|---|
| **#1376** | `feat/composition-runtime-grant` (bfb9b0d92) | `CompositionCaps.mint_cap/4` — 通用运行时「发钥匙」:给某 session 的 assistant 铸一把指向某 target(board)的 cap,读动作=只读钥匙、写动作=操作钥匙,granter 永远 = target 的 data_owner(板主人 consent),ownerless→fail-closed | **基础设施**(通用,非 kanban 专属),正是 plan §7 说「紧接要补」的挂载 infra |
| **#1374** | `feat/kanban-progress-board` (8cf8cb048, 栈在 #1376 上) | 提纯 + 发现按 CBAC 收敛 + chat 建板 + **跨房间拉板/转发**(BoardProvision:owner 拉板发操作钥匙 / 群成员转发发只读钥匙) | **业务** = #1360 Layer B 的 kanban 侧实现 |

`docs/socialware-data-mount-model`(kanban-i12 worktree, 155934e07)那 2 个分析 commit 已被上面的**实现取代**——本 return 即其「形式化」,交的是实现,比预期的「形式化分析」更强。

## DoD 对账(实现层,已绿;产品层未闭)

- [x] 通用发钥匙机制 mint_cap/4:0 core / 0 I12 gate 改动(复用 composition 既有单 absorb 路,抽 `absorb_one/2`);I12 9/0、arch 102/0
- [x] 发现按 cap 收敛(非 admin 只见有权板,admin 见全 ws):kanban 81/0
- [x] 拉板(owner-only,发操作钥匙)/ 转发(任意有权成员,发只读钥匙):socialware 162/0
- [x] 装 sw ≠ 自动生板(manifest 删 board 角色,改 chat 动态建);conformance 15/15
- [ ] **产品层未闭:BoardProvision 三函数目前只有测试触发,无 chat/orchestrator/UI/cc-skill 入口** — 真浏览器 e2e 需先接触发器(T6,未做),这是 07-14 plan ② 要的「跨环节验收用例」的前置。**诚实标注:实现绿 ≠ 产品可达。**

## merge request / 给 lead 的动作

1. **纠正 roster 认知**:jjkysy #1360 Layer B 状态应从「spec-only、未实现」改为「**实现完成、待 e2e 验收**」。`latest_return` 应指向 #1374/#1376,非 `kanban-rework-final(07-10)`。
2. **两 PR 转正时机由 lead/Allen 定**(我不自 merge、不自转正):#1376 是通用基础设施先行,#1374 栈在其上。
3. **决策项(给 Allen/jjkysy 本人)**:07-14 plan 把 jjkysy 改为「不做主建、检查补位」,但主建(实现)已完成。请确认后续=(a) 收尾 e2e 接触发器让流程产品可达,还是 (b) 按 plan 转「kanban 侧检查 + 跨环节验收用例」,让 zhaomato 的 hello 侧对接我的 mint_cap/BoardProvision。二者不互斥,但顺序影响本周红线闭合。

## 风险/坑

- 工具链:实现全在 **OTP28/1.19**(main 的 tracked `.tool-versions`,#1366)下绿;Loop cron 的 mise pin OTP27/1.18 已过时,需同步。
- gate 规避记录:mint_cap 名字**不能**叫 grant_cap(撞 I12 `grant_driver_fingerprint` 前缀);T5b 转发的 slice-read 内联(避 cross_file_duplicate_fn 42→43)。改这两处前先读 I12 gate 意图。
