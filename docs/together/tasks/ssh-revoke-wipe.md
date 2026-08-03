# 撤销即擦除 follow-up —— feat/ssh-revoke-wipe (:cap_revoked → wipe)

- **id**: `ssh-revoke-wipe`
- **owner**: codex
- **status**: wip(分支就绪, #1688 已合 → 解除阻塞, 待评审合入)
- **历史**: started 2026-08-03 · est_done 2026-08-04 · actual —
- **关联**: 前置 `agent-ssh-credential-b2`(#1688 merged 08-03, 8ad5d3795) · branch `feat/ssh-revoke-wipe`(head 868ba5cba) · commits: K3 84dba69b6 · K5+K6 85fb6414e · K4 868ba5cba
- **依赖**: #1688 已合入(08-03) —— 原排序约束已满足, 应尽快评审合入以关闭撤销不即擦除窗口

## 目标

补齐 #1688 的撤销面: `:cap_revoked` 触发 `GitIdentityRuntime.wipe` hook, agent 物化的
SSH 凭据在撤销时即擦除; 钉住 Sandbox 两处 destroy 入口的 git-identity 清理、指纹值、
`read_ssh_public_key` value 走私防护。

## 验收

- [x] K3 — 钉住 Sandbox 两处 destroy 入口的 git-identity 清理(evidence: 84dba69b6)
- [x] K5+K6 — 指纹值钉死 + read_ssh_public_key value 走私防护(evidence: 85fb6414e)
- [x] K4 — spec/moduledoc "已被取代"说法订正(evidence: 868ba5cba)
- [ ] cc 评审 → 合入 main(#1688 已落地, 窗口开着, 优先跟上)

## Handoff prompt

codex 按 K3/K4/K5+K6 子步执行完毕(子步口径见当日 codex 派发记录)。剩余为 cc 评审 +
合入; 评审关注: wipe 触发面是否覆盖所有物化凭据的 destroy 路径、`:cap_revoked` 到达
时序(撤销与 wipe 的原子/顺序保证)。
