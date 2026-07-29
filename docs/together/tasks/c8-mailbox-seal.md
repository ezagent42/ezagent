# C8 — v5 use-side Kind-mailbox seal / pid 纪律（暂缓至 #189 落地）

- **id**: `c8-mailbox-seal`
- **owner**: Allen 轨道
- **status**: planned(暂缓至 #189)
- **历史**: started - · est_done - · actual —
- **关联**: branch feat/v5-use-side-mailbox(+32/−23) · codex spec: NEEDS-REVISION→已修订待 re-review

- **branch**: `feat/v5-use-side-mailbox`（+32/−23 vs main）
- **依赖**: #189 一次合入 main

## 目标
`EzagentActor.Signal` 密封投递 + `Kind.Server` H3 fail-loud 邮箱封口（防漂移，非认证）落到 main。

## 验收
- [ ] rebase 到当时 main；`mix ci.fast` + 私有分区 `mix ci.local` 全绿（封口 ACTIVE，0 UnsanctionedMailboxError）
- [ ] B1 合并序回归：snapshot commit → identity dual-write → projection emit → sealed self-signal → cascade 五步顺序断言
- [ ] B2 owner-gated resolver：Codex-sidecar 两个 status 读恢复 OwnerGatedExecutor 语义 + 跨 workspace 回归
- [ ] 封口 fail-before/pass-after：fixture raw send → dev/test raise / prod 遥测+丢弃

## Handoff prompt
完整 dev spec（含 codex 评审两 blocker + 修订 + 合并计划）见
`scratchpad/spec-C8-v5-use-side-mailbox-seal.md`（#189 落地后随 dispatch 附全文）。
