# 撤销即擦除 follow-up —— feat/ssh-revoke-wipe (:cap_revoked → wipe)

- **id**: `ssh-revoke-wipe`
- **owner**: allen(执行: codex agent)
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

> 评审 + 合入 `feat/ssh-revoke-wipe`(head 868ba5cba; K3/K4/K5+K6 已由 codex 按子步
> 执行完毕)。步骤与闸:
>
> (1) cc 评审三个关注点: ① wipe 触发面是否覆盖所有物化凭据的 destroy 路径
> (Sandbox 两处 destroy 入口, K3 钉住); ② `:cap_revoked` 到达时序 —— 撤销与 wipe
> 的原子/顺序保证(撤销先入 ledger 再触发 wipe, 不允许 wipe 先于撤销可见);
> ③ 指纹值钉死 + `read_ssh_public_key` value 走私防护(K5+K6)无绕过面。
> (2) 评审过后: rebase 到含 #1688 的当前 main → 根目录 precommit 绿 → 开 PR →
> 正常 merge(不打补丁式重试、不 mask)。
> (3) 合入后回勾 `agent-ssh-credential-b2` 验收第 4 条 —— 撤销不即擦除窗口自此关闭,
> 并在 08-03 board 把本卡移入 DONE。
