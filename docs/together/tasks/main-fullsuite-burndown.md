# main full-suite 真绿 burn-down — 逐红定位、逐红修复、根目录实证

- **id**: `main-fullsuite-burndown`
- **owner**: Allen 轨道(cc 协调)
- **status**: wip(分片各自绿 13/14; 残留轮换 flake → `ci-isolation-integration`)
- **历史**: started 2026-07-29 · est_done 2026-07-30 · actual —（分片阶段 2026-08-02 收口; 真绿待整合分支）
- **关联**: 已合入 #1622(红①) · #1624(红④) · #1628(红③) · 红② #1590 裁决=CLOSED · **分片阶段(08-02): #1683(arch-gate, gaga) · #1685(web) · #1686(domain) · #1687(frontend CI 镜像烘 Playwright)** · 残留: 轮换 intra-suite 隔离 flake(#184) → `ci-isolation-integration` · 修复分支 fix/main-red-releasetest-webassets

## 目标

把 main full-suite 从「系统性红」烧到真绿(根目录实证 0 failures), 作为 canary 自动放行的
前置。#189 cutover(#1621) 已把 9 个 holder_revoked 红转绿; 本任务收残量:

- 红① curl-migration fixture 与 #1621 反复活语义不齐 → **#1622 已修**(fixture 铸造 authority history)。
- 红③ provider-connection 套件健康(registry owner 生命周期 + 环境敏感) → **#1628 已修**。
- 红④ core shard 在原生 mac 上挂死(credential resolve hang + /proc 探针) → **#1624 已修**。
- 红② credential/flavor adopt(#201): 结构性 defer-writes 已由 #1604 入 main; **#1590 为
  同因平行 PR, 已裁决 CLOSED**。
- 新红 A(#1625 产): `EzagentCore.ReleaseTest:44` FleetParity ambient-fleet hermeticity。
- 新红 B(#1626 产): `ci.shard.web` 内 `mix assets.build` exit 1。
- **分片阶段(08-02)**: arch-gate 扫别的测试 tmp fixtures → **#1683 已修**(gaga);
  web 分片 cold-session listing + async/baseline drift → **#1685 已修**;
  domain 分片 creation gate + 隔离 → **#1686 已修**;
  frontend Playwright Chromium 烘入 CI 镜像 → **#1687 已修**(cc infra)。
  四分片落地后**分片各自绿 13/14**; 残留轮换 intra-suite 隔离 flake(#184: 全套连跑时
  domain 一次、web 下一次轮换红) → 系统性修复走 `ci-isolation-integration` 整合分支一次闸。

## 验收

- [x] 红① #1622 合入(evidence: merged 07-29 21:34, b2622e05c)
- [x] 红③ #1628 合入(evidence: merged 07-30 01:13, e4dd67039)
- [x] 红④ #1624 合入(evidence: merged 07-29 22:41, 9854423e1)
- [x] 红② 裁决落地: #1590 已 CLOSED(同因平行 PR, #1604 已入 main)
- [x] 分片 burn-down 四 PR 合入(evidence: #1683 0c581e2d3 / #1685 571a12ef7 / #1686 fe1fa6d0f / #1687 00f4b3f5b; 分片各自绿 13/14)
- [ ] 残留轮换 flake(#184)系统性修复随 `ci-isolation-integration` 合入(一次完整 precommit 诚实绿)
- [ ] 根目录 full-suite 实证全绿(0 failures), 无新增红 → main 真绿 → canary 放行评估

## Handoff prompt

> main full-suite 真绿 burn-down 残量。分支 `fix/main-red-releasetest-webassets`(从 main
> 65522fc03 起)。两个新红各修各的、各带 fail-before/pass-after 证据:
>
> (A) `EzagentCore.ReleaseTest:44` — #1625 的 release-runnable cutover runbook 引入
> FleetParity ambient-fleet 依赖, 测试在隔离环境无 ambient fleet 时红。修 hermeticity:
> 测试注入自己的 fleet 视图, 不读 ambient 状态(environment-shape isolation, 冷注入)。
> 不许改产品语义迁就测试。
>
> (B) `ci.shard.web` 里 `mix assets.build` exit 1 — #1626 把测试跑动与资产构建解耦后,
> web shard 的构建步骤在 fresh env 缺前置。修 shard 定义/前置链, 使 fresh checkout 直接
> `mix ci.shard.web` 绿。
>
> (C) 红②: 对比 #1590 与已入 main 的 #1604(同为 #201/#189-成因① 结构性 defer-writes),
> 枚举 #1590 独有增量; 有则 rebase 抽干净重开, 无则评论 superseded by #1604 并关闭。
>
> 完成后在根目录跑 full-suite(完整文件路径、不 cd 进 app), gate on EXIT=0 且 grep
> "0 failures"; `mix gate.arch` 基线不回退。
