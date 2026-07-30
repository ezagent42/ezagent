# #189 epoch 激活链 — runbook(#1625) → #1627 boot re-mint → canary 恢复 → epoch

- **id**: `189-epoch-activation`
- **owner**: Allen 轨道(cc 协调)
- **status**: review
- **历史**: started 2026-07-29 · est_done 2026-07-30 · actual —
- **关联**: #1625(runbook, merged 07-29) · #1627(open, fix/pre-epoch-boot-remint @ f9b2eab3f, codex 第二轮 DO-NOT-MERGE 后重设计, 复审重跑中) · canary hard-down(止损中)

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
- [ ] #1627 设计分叉裁决(待 Allen: genesis-admin-only re-mint vs 更宽 pre-epoch re-mint)
- [ ] #1627 codex 复审通过 → 合入
- [ ] canary 重部后 self-heal 启动(崩溃循环消失, boot 全绿)
- [ ] epoch 按 runbook 激活, 激活后反复活不变量保持(revoked/tombstoned 依然 denied)

## Handoff prompt

> #189 生产收尾链, 按序推进、每步有闸:
>
> (1) #1627 `fix/pre-epoch-boot-remint`: 只允许 **pre-epoch**(epoch 未激活)且
> **genesis-admin** 的 self-license 在 gen-reboot 后 re-mint; epoch 激活后此路径必须
> 死(fail-closed), 反复活不变量(revoked/tombstoned 重启后仍 denied)不许打洞。设计分叉
> (genesis-admin-only vs 更宽)是 Allen 的裁决点 —— 出双方案对比即可, 不擅自定。
> codex 复审必须过, 第二轮 DO-NOT-MERGE 的每条 finding 有回应。
>
> (2) canary 恢复: #1627 合入后重部 canary(容器现已停), 观察 boot self-heal; 不许
> 对 canary DB 做破坏性迁移或手工改行 —— canary DB 是 #1627 的复现床, 修复必须以
> 代码路径自愈证明。
>
> (3) epoch 激活: 严格按 #1625 runbook(`bin/ezagent eval` 包装)执行, 激活前确认
> fleet-parity barrier(写静默)前置满足; 激活后跑冒烟 + 验证 stale-gen 路径已死。
