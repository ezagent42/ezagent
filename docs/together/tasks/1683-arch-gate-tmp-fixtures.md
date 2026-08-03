# #1683 arch-gate 不再扫别的测试的 tmp fixtures

- **id**: `1683-arch-gate-tmp-fixtures`
- **owner**: gaga
- **status**: done
- **历史**: started 2026-08-01 · est_done 2026-08-02 · actual 2026-08-02
- **关联**: PR #1683(merged 08-02 00:53 CST, 0c581e2d3) · 主线: `main-fullsuite-burndown` 分片之一(arch-gate)

## 目标

architecture gates(`gate.arch` 静态扫描)在 full-suite 连跑时会扫到**别的测试**留下的
tmp fixtures, 产生轮换红 —— gate 与 fixture 目录隔离是结构解, 不是重试。

## 验收

- [x] #1683 合入: gate 扫描面与测试 tmp fixture 目录隔离(evidence: merged 08-02 00:53 CST, 0c581e2d3)
- [x] arch-gate 分片各自转绿(evidence: 08-02 分片 burn-down 后 main 13/14)

## Handoff prompt

> (归档 — 已合入, prompt 留作可复演任务简报) 原任务: architecture gates
> (`gate.arch` 静态扫描)在 full-suite 连跑时扫到**别的测试**留下的 tmp fixtures,
> 产生轮换红。修复方向 = gate 扫描面与测试 tmp fixture 目录做结构隔离(不是重试、
> 不是加宽 allowlist); 改前 fail-before、改后 pass-after 各跑一次为证。
> 方法沉淀(已写回 08-03 board review): flake 归因到结构 —— 目录隔离是结构解,
> 不打补丁式重试。
