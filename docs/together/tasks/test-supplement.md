# test-supplement — 测试补齐 P0(可跑性) → P1/P2(契约与行为) → P3(91 模块分诊执行)

- **id**: `test-supplement`
- **owner**: Allen 轨道(cc 协调)
- **status**: wip
- **历史**: started 2026-07-29 · est_done 2026-07-30 · actual —
- **关联**: P0 #1626(merged) · P1 #1629(merged) · P2 #1630(merged) · P3 分诊清单已交付(91 个待补测模块), 待执行排程

## 目标

系统性补齐测试覆盖, 分层推进:

- **P0 可跑性**: web 测试在 fresh env 可跑 —— 测试跑动与资产构建解耦(#1626)。
- **P1 契约**: adapters 面(protocol_api + feishu inbound)契约覆盖(#1629)。
- **P2 行为**: world 服务端 view-authz + admin-action 行为覆盖(#1630)。
- **P3 分诊→执行**: 全仓清点得出 91 个待补测模块的分诊清单(已交付); 转成分批执行排程,
  按风险/依赖排序逐批派发。

## 验收

- [x] P0 #1626 合入(evidence: merged 07-30 00:43, 908767ce1; 注: 引入 ci.shard.web
      assets.build 新红 1 个, 由 main-fullsuite-burndown 收尾)
- [x] P1 #1629 合入(evidence: merged 07-30 01:28, 2dad70896)
- [x] P2 #1630 合入(evidence: merged 07-30 01:51, 65522fc03)
- [ ] P3: 91 模块清单转执行排程(分批、每批验收 = 该批模块红转绿 + 无新红), 首批派发

## Handoff prompt

> test-supplement P3 执行排程。输入 = P3 分诊交付物(91 个待补测模块清单)。产出 =
> 分批执行计划 + 首批派发:
>
> (1) 按「风险 × 依赖」排序: 授权/身份/cap 面优先, 其次 adapters/world 面, 纯工具尾批;
> 每批 ≤ 10 模块、≤ 1 天。
> (2) 每批的验收 = 该批模块的行为测试落地(非行覆盖凑数)、根目录跑全量无新红;
> 并行派发时各 agent 用 MIX_TEST_PARTITION 隔离测试库。
> (3) 清单是 enumerator gate 的产物 —— 完成一批就在清单上勾一批, 清单烧到 0 才算
> P3 done; 不许「挑软柿子」跳过难模块, 难的显式标 blocked + 原因。
