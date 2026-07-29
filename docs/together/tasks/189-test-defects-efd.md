# #189 test-defects E/F/D 验证（剩余项 —— A 已随 #1599/#1610 落 main）

- **id**: `189-test-defects-efd`
- **owner**: Allen 轨道
- **status**: wip
- **历史**: started 2026-07-28 · est_done 2026-07-29 · actual —
- **关联**: 承接 07-28 板「★ #189 test-defects A/E/F + CLI(D) 隔离」；A(member_cap sync) 已由
  #1599（两个 full-suite 时序 flake 转绿）+ #1610（node-global-teardown 拆 CI leg）覆盖并
  merged 07-28（见 task `189-precursors-pr1`）。本卡是未覆盖的剩余三项。

- **依赖**: 当前 main（含 #1599/#1610/#1604/#1615）

## 目标
验证 4 个测试缺陷里未随 07-28 三连落地的 E(predicate-A layer) / F(customer-concept
topology) / D(CLI 隔离) 在当前 main 上是否已转绿；未绿则定位修复，直到 main full-suite
在这三项上无残留红。

## 验收
- [ ] E（predicate-A layer）在当前 main 上验证绿
- [ ] F（customer-concept topology）在当前 main 上验证绿
- [ ] CLI（D 隔离）在当前 main 上验证绿
- [ ] 三项均绿后，在 `189-identity-cutover` 卡的「无新增红」验收项里同步勾选

## Handoff prompt

> #189 test-defects 剩余三项验证（A 已被 #1599/#1610 覆盖，不在本卡范围）。在当前 main
> （含 #1604/#1599/#1610/#1615）上跑 full-suite，定位以下三类是否仍红：
> 1. **E — predicate-A layer**：07-28 板标注为排查中，未见独立 PR 落地；先确认是否
>    已被身份平面 PR-1/写平面的 additive 改动顺带修复（dual-write 期间 predicate
>    判定可能已经改变），fail-before/pass-after 各跑一次隔离验证。
> 2. **F — customer-concept topology**：同上，先隔离复现红，再定位是结构性缺陷还是
>    fixture/测试拓扑问题。
> 3. **CLI(D) 隔离**：确认 CLI 相关测试是否已从主套件正确隔离（07-27 板标注为「隔离」
>    而非「修复」，含义是防串扰，不是消红——需要先确认隔离是否已落地）。
>
> 若三项在当前 main 上已经绿（因为身份平面改动顺带修了 predicate/topology 相关代码），
> 本卡收敛为「验证 + 记录」，不需要新 PR；若仍红，按 systematic-debugging 流程
> reproduce-first 定位根因，开小 PR 修复，回到 `189-identity-cutover` 的「无新增红」
> 验收线勾选证据。
