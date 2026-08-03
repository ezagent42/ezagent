# 追跟 bug 立项 — tracker #204 Feishu webhook 签名校验 + #205 world 路由死特性

- **id**: `followup-bugs-204-205`
- **owner**: Allen 轨道(cc 协调)
- **status**: wip(#204 已处置; #205 待排期)
- **历史**: started 2026-07-30 · est_done 2026-07-30 · actual —(#204: 2026-07-31)
- **关联**: tracker #204(**已处置: #1657 移除公开 HTTP webhook 路由, merged 07-31 08:52 CST, 6d6654517** —— 未签名面整体删除, 优于补验签) · tracker #205(tracker 编号, 非 PR 号; 仍未排期)

## 目标

夜车过程中发现、已立 tracker 的两个跟进 bug:

- **tracker #204 — Feishu webhook 签名校验**: ✅ 已处置 —— #1657 直接移除公开 HTTP
  webhook 路由(死面 + 未签名面一并删除), merged 07-31。
- **tracker #205 — world 路由死特性**: world 路由面存在已死特性(dead feature)路径,
  按「死代码 → 台账 → 统一删除」纪律处置。**仍待排期**(焦点在 CI 隔离整合)。

## 验收

- [x] #204: 公开 webhook 路由移除(evidence: #1657 merged 07-31, 6d6654517; 处置方式
      从「补 sig-verify」改为「删除无签名死面」)
- [ ] #205: 枚举 world 路由死特性引用点(代码/路由表/文档/gate) → 一遍删除 + 全量无新红,
      或裁定保留并注明理由

## Handoff prompt

> (#204 已闭环, 见验收区; 无需再做。)
>
> (#205) world 路由死特性: grep 全仓枚举该路由/特性的所有引用(含前端调用、文档、
> invariant allowlist), 记台账; 确认无活流量语义后一遍删除 + 根目录全量测试; 若发现
> 仍有消费方, 转「保留 + 收敛」并把结论写回 tracker。
