# #189 epoch 激活链 — runbook(#1625) → #1627 boot re-mint → canary 恢复 → epoch

- **id**: `189-epoch-activation`
- **owner**: Allen 轨道(cc 协调)
- **status**: done(链已闭环, 归档于 2026-08-03 board carryover_resolved)
- **历史**: started 2026-07-29 · est_done 2026-07-30 · actual 2026-08-02 前(epoch 已激活于 08-02 A4-2 return §2.4 记录为换源前提满足)
- **关联**: #1625(runbook, merged 07-29) · #1627(**merged 07-30, e14fda90a** —— 设计分叉裁决落地为 B1-hybrid: genesis-admin 结构性不可杀 + pre-epoch re-mint) · canary 重部后 cutover 彩排 6 个 catch 修复入 main(#1638/#1646/#1652/#1654/#1656/#1658, 07-30→08-01)

## 目标

#189 身份平面 cutover(#1621)落地后, 生产侧收尾三步:

1. **runbook**: epoch 激活路径做成 release-runnable(`bin/ezagent eval`), canary/prod 可复演
   —— **#1625 已合入**。
2. **#1627 pre-epoch boot re-mint**: 存量 DB(尚未激活 epoch)在 gen-reboot 后 admin
   self-license 为 stale-gen, 启动即 `:holder_revoked`。修复 = 受限 re-mint(重设计后口径:
   genesis-admin-only), **设计分叉待 Allen 裁决**(genesis-admin-only vs 更宽 pre-epoch
   re-mint), codex 第二轮打回后已重设计, 复审重跑中。
3. **canary 恢复 + epoch 激活**: canary 现 hard-down(reflow DB 带 stale-gen admin
   self-license, 任何 pre-#1627 镜像启动即崩溃循环; 容器已停止损, canary DB 即 #1627 的
   天然复现床)。恢复 = #1627 合入 → 重部 self-heal 启动 → 按 #1625 runbook 激活 epoch。

## 验收

- [x] #1625 release-runnable cutover runbook 合入(evidence: merged 07-29 23:20, 1b90c204d)
- [x] #1627 设计分叉裁决(evidence: 落地为 B1-hybrid —— genesis-admin-only re-mint + genesis admin 结构性不可杀)
- [x] #1627 codex 复审通过 → 合入(evidence: merged 07-30, e14fda90a)
- [x] canary 重部后 self-heal 启动(evidence: 重部后 cutover 彩排跑出 6 个 catch 并逐个修复入 main —— #1638/#1646/#1652/#1654/#1656/#1658, 07-30→08-01; 崩溃循环消失)
- [x] epoch 按 runbook 激活(evidence: 08-02 A4-2 return §2.4 记录「prod cutover epoch 已激活 → 换源前提满足」)

## Handoff prompt

> (归档 — 链已闭环, prompt 留作一次性复核指引) #1627 merged 07-30(e14fda90a,
> B1-hybrid); canary 重部彩排 6 个 catch 修复入 main; epoch 已激活(08-02 记录)。
> 剩余一次性核对(可随时做, 不阻塞):
>
> (1) 在激活后的 canary/prod 按 #1625 runbook 冒烟, 验证 stale-gen 路径 fail-closed
> —— 反复活不变量(revoked/tombstoned 重启后仍 denied)保持。
> (2) 核对结果回本 task 记录一行 evidence; 若发现 stale-gen 路径仍活, 立即开
> tracker bug 并挂回 board。
