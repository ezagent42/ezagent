# #189 前置三连 + 身份平面 PR-1 入 main

- **id**: `189-precursors-pr1`
- **owner**: Allen 轨道
- **status**: done
- **历史**: started 2026-07-27 · est_done 2026-07-28 · actual 2026-07-28
- **关联**: PR #1604(merged) · #1599(merged) · #1610(merged) · #1615(merged, main bc1b9fb74)
  · #1590 为 #1604 的冗余开口 PR，待关闭

## 目标
把 #189 的三个已确认成因逐个落地，并为身份平面 cutover 打好 additive 地基。

## 验收
- [x] #1604 — #201 成因① credential/flavor adopt-clobber 结构性 defer-writes
      （evidence: merged 07-28；#1590 为冗余开口 PR，待关闭）
- [x] #1599 — 两个 full-suite 时序 flake 转绿（member_cap roster sync + world LiveView
      mailbox barrier）（evidence: merged 07-28）
- [x] #1610 — node-global-teardown 侵略者拆独立 CI leg（消 ~510 分片级联）+ enumerator gate
      （evidence: merged 07-28）
- [x] #1615 — 身份平面 PR-1：统一 EntityCaps.Store + dual-write(additive)，全套验证
      zero-new-reds（evidence: merged 跨夜，main bc1b9fb74）

## Handoff prompt（回溯归档）

07-28 当日/跨夜派发，非本文件事后重构。实际派发内容摘要：

> #201 credential-path race（`fix/201-structural-defer-writes`）此前已 code-complete
> 并独立验证 117/0（见 07-27 板卡片），07-28 完成 codex 复评审并合入为 #1604；同批次
> 顺带清掉两个 full-suite 时序 flake（#1599：member_cap roster sync + world LiveView
> mailbox barrier）和一个 CI 基建问题（#1610：node-global-teardown 拆独立 CI leg，
> 消掉级联失败）。四者之外，身份平面 cutover 的第一段（PR-1：统一
> `EntityCaps.Store` + dual-write，additive、向后兼容）同批完成验证并跨夜合入
> main（bc1b9fb74）。四个 PR 全部走 codex 对抗评审 + 独立验证后合入，无一 admin-merge。
>
> 遗留：`#1590`（#201 的早前开口 PR）在 `#1604` 落地后成为冗余重复 PR，需要显式关闭
> 并注明「被 #1604 取代」，不要留着造成两个 PR 都开着的误导。
