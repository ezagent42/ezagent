# socialware-receiver handoff 文档

- **id**: `socialware-receiver-handoffs`
- **owner**: Allen 轨道
- **status**: done
- **历史**: started 2026-07-27 · est_done 2026-07-28 · actual 2026-07-28
- **关联**: PR #1607(merged) · #1609(merged)

## 目标
typed-message + event-renderer + receiver 地基 handoff + LSP/ACP 协议框架。

## 验收
- [x] #1607 + #1609 — socialware-receiver foundation + origin/协议框架 handoff
      （evidence: merged 07-28）

## Handoff prompt（回溯归档）

07-28 派发，非本文件事后重构。实际派发内容摘要：

> 为「socialware receiver」这条尚未开工的结构线（typed-message 分发 + event-renderer
> 渲染 + receiver 地基）写下一份可被后续 dev 接手的 handoff 文档，同时把 LSP/ACP
> （类似 Language Server Protocol / Agent Client Protocol 的思路）协议框架的设计
> 起点记录下来，作为「plugin external = Receiver Kind」（外部集成 = 按 Kind+Behavior
> 路由的 Receiver）这条北极星方向的落地起点文档。#1607 是 foundation handoff 本体，
> #1609 补充协议框架部分。两者都是文档/设计产出，不含运行时代码改动。
