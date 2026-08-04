# Group-B 接线前置 —— A5 四 follow-ups + 匿名页渲染组件 + kanban 纯化 #1474

- **id**: `group-b-wiring`
- **owner**: jjkysy
- **status**: planned(08-04 新开 —— Group-A 八条原语闭合后 Group-B 前置 blockers 立案)
- **历史**: started 2026-08-04 · est_done 2026-08-04 · actual —
- **关联**: Group-A 闭合(#1619 merged 08-04 10:32 CST, 129b2facf) · codex 评审 MERGE-WITH-NITS 4 follow-ups(含 issue **#1694**) · 匿名页产品级渲染组件(开发级 JSON 占位 → 插件组件, 已裁决归 Group B) · kanban 纯化 **#1474**(OPEN draft, 07-27 更新) · return 证据 `docs/together/2026-08-03/returns/share-a5-anon-link.md`
- **依赖**: Group-A 闭合(已达成 08-04); #1694 与整合线 #1684 per-grant revocation 同域 —— 立案时不排期到整合线合入前

## 目标

Group-A(#1594→#1619 八条原语)闭合后, 把 Group-B 开工前的**前置 blockers** 逐条立案成
可派发的 handoff, 并把 #1474 kanban 纯化从 draft 推成 plan。三块:

1. **A5 四 follow-ups 立案**(codex MERGE-WITH-NITS 评审产物): 逐条写成单 PR 可验收的
   handoff; 含 issue #1694(冷成员 remove 跳过撤销 + 在途 absorb 复活回 roster ——
   F2, Allen 在 #1655 合并 review 点名; 与 #1684 per-grant revocation 同域, 注意顺序)。
2. **匿名页产品级渲染组件**: 当前是开发级 `<pre>` JSON 占位(证明数据带钥匙走通到
   浏览器); 产品级应渲染插件自己的组件 —— 已裁决归 Group B, 设计接 A5 的资源投影面。
3. **kanban 纯化 #1474**: 从 draft 起 plan(Group-A 闭合后够格开工), 切片为单日粒度。

## 验收

- [ ] A5 四 follow-ups 逐条立案 handoff(含 issue #1694; 每条 = 单 PR 可验收粒度, 走 clarify_first → build)
- [ ] 匿名页产品级渲染组件接线(归 Group B, 已裁决; 设计接 A5 资源投影 + born-with 读钥匙)
- [ ] kanban 纯化 #1474 从 draft 起 plan + 切片(单日粒度, 依赖序)
- [ ] 每片单 PR gate 绿, cc 评审 + 合入按 dev-together 常轨

## Handoff prompt

> Group-A 八条原语已闭合(#1619 merged 129b2facf)。Group-B 开工前置 = 三块:
>
> (1) **A5 四 follow-ups 立案**: 从 #1619 的 codex MERGE-WITH-NITS 评审 + return doc
> (`docs/together/2026-08-03/returns/share-a5-anon-link.md`)取四条 follow-ups, 逐条写成
> 独立 handoff(单 PR 可验收, 走 clarify_first → build); issue #1694(冷成员撤销面 F2)
> 必须包含 —— 与 #1684 per-grant revocation 同域, 立案时不排期到整合线合入前。
> (2) **匿名页产品级渲染组件**: 匿名页当前渲染开发级 JSON 占位, 产品级应渲染插件自己的
> 组件(已裁决归 Group B); 设计接 A5 的资源投影 + born-with 读钥匙, 不另造读路径。
> (3) **kanban 纯化 #1474**: 从 draft 起写 plan, 切成单日粒度模块(依赖序), 每片独立
> PR、gate 绿、cc 评审合入。
> 每片落地后在 ezagent board `group-b-wiring` 卡回勾并附 PR/issue 链接。
