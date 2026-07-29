# 插件 owner-bypass 债务清零

- **id**: `owner-bypass-1593`
- **owner**: Allen 轨道
- **status**: done
- **历史**: started 2026-07-27 · est_done 2026-07-28 · actual 2026-07-28
- **关联**: PR #1593(merged) · CapBAC 债务 · follow-up issue #1592(open)

## 目标
枚举出的 plugin owner-bypass 全部烧到 0。

## 验收
- [x] #1593 — owner-gated executor + workspace facades，枚举债务→0
      （evidence: merged 07-28）

## Handoff prompt（回溯归档）

07-28 派发，非本文件事后重构。实际派发内容摘要：

> 承接更早枚举出的 10 处 plugin owner-bypass 债务清单（每处域代码直接绕过 owner
> 校验访问资源的调用点），把它们全部收敛到 `OwnerGatedExecutor`/`OwnerGatedWorkspace`
> 两个 facade 后面——facade 保留 `(uri, pid)` 签名（因为 registries 是 plugin-local，
> codex 提议的「registry-resolve」方案在当前架构下不可行）。10 处全部改造完成，
> 债务枚举计数烧到 0。残余的「AST-scan 任意 GenServer receiver + gate `Kind.spawn`」
> 属于更大范围的静态扫描升级，落 follow-up issue #1592（open，未在本次范围内）。
