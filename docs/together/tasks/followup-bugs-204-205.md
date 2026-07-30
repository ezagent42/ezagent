# 追跟 bug 立项 — tracker #204 Feishu webhook 签名校验 + #205 world 路由死特性

- **id**: `followup-bugs-204-205`
- **owner**: Allen 轨道(cc 协调)
- **status**: planned
- **历史**: started 2026-07-30 · est_done 2026-07-30 · actual —
- **关联**: tracker #204 · tracker #205(tracker 编号, 非 PR 号)

## 目标

夜车过程中发现、已立 tracker 的两个跟进 bug, 今日进入排程:

- **tracker #204 — Feishu webhook 签名校验**: Feishu inbound webhook 缺签名校验
  (sig-verify), 属安全面缺口; 按 dev 期安全姿态拆分 + 确认后修。
- **tracker #205 — world 路由死特性**: world 路由面存在已死特性(dead feature)路径,
  按「死代码 → 台账 → 统一删除」纪律处置。

## 验收

- [ ] #204: 复现 webhook 无签名被接受的失败测试 → 补 sig-verify(fail-closed) →
      fail-before/pass-after
- [ ] #205: 枚举 world 路由死特性引用点(代码/路由表/文档/gate) → 一遍删除 + 全量无新红,
      或裁定保留并注明理由

## Handoff prompt

> 两个 tracker bug, 各自独立、可并行:
>
> (#204) Feishu webhook sig-verify: 先写失败测试证明当前 inbound webhook 不验签即处理;
> 然后在 adapter 入口补签名校验, fail-closed(验签失败 4xx 拒收, 不落 pipeline)。校验密钥
> 走既有凭证面, 不新增 env 旁路。注意 #1629 刚给 feishu inbound 加了契约测试 —— 在其上
> 扩展, 不平行造面。
>
> (#205) world 路由死特性: grep 全仓枚举该路由/特性的所有引用(含前端调用、文档、
> invariant allowlist), 记台账; 确认无活流量语义后一遍删除 + 根目录全量测试; 若发现
> 仍有消费方, 转「保留 + 收敛」并把结论写回 tracker。
