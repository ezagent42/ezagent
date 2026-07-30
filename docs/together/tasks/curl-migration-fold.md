# curl 迁移收尾 — retired-Kind 迁移机器删除

- **id**: `curl-migration-fold`
- **owner**: Allen 轨道(cc 协调)
- **status**: done
- **历史**: started 2026-07-29 · est_done 2026-07-29 · actual 2026-07-29
- **关联**: PR #1623(merged 07-29 21:56, d483d2293) · 前置 #1622(fixture 对齐 #1621 反复活语义)

## 目标

curl fold 之后, retired-Kind 迁移机器成为死代码。按「死代码 → 台账 → 统一一遍删除」纪律,
把 curl 相关迁移机器 + 枚举出的 dead compat 一次性删除并全量验证, 不留渐进残根。

## 验收

- [x] retired-Kind 迁移机器 + 枚举 dead compat 删除, 全量测试无新红
      (evidence: #1623 merged 07-29, d483d2293)

## Handoff prompt（回溯归档）

07-29 派发, 实际内容摘要:

> curl fold 已完成、#1622 已把迁移 fixture 对齐 #1621 的 authority-history 语义。现在
> 删掉 retired-Kind 迁移机器: 先枚举(grep 全仓所有引用点, 含脚本/文档/gate allowlist),
> 记台账; 然后一遍删除 + 全量测试。删除类改动必须一次成套(delete+test in ONE pass),
> 不做「注释掉先留着」。gate/invariant allowlist 若引用被删符号, 同 PR 内清理并给
> justification。
