> **Task:** #1436 v2 — 对齐 §0 Allen 决策修订
> **Branch:** `docs/workspace-self-service-product-plan`
> **PR:** https://github.com/ezagent42/ezagent/pull/1436
> **Dev:** ruihua（designer）
> **returned_at:** 2026-07-17 11:00 +0800
> **deadline:** 2026-07-17
> **deadline_status:** on_time

## DoD reconciliation

Handoff = Allen 的 7 条裁定（§0），要求「把各 G 段细节对齐重排」。

| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | G1/G2/G3 移出 beta P0 → backlog | met | §2 重排；G1/G2/G3 标为 backlog，注明「机制已存在、缺 UI」 |
| 2 | G3 收敛为文档化单-own，不做多 workspace UI | met | G3 删除方案 B，标注「已裁定：每用户 own ≤1」 |
| 3 | Agent/Key = 托管 agent（非 BYOK），单独立项 | met | §1 用户画像更新；§2 新增「单独立项」行；G4 删除 BYOK 假设 |
| 4 | G4 不做 stub_grant，等 cap-signing | met | G4 删除全部降级方案；§5 标记为「已废弃」+ 否决理由 |
| 5 | G1/G2 机制已存在、只缺 UI | met | G1/G2 标注「机制已存在（`registration_open`/`invite_code`）」 |
| 6 | G5 升级为通用可配置错误机制 | met | G5 重写：从「缺 key 提示」→ 错误码注册表 + 结构化失败消息 |
| 7 | beta 范围 = admin 开通 + 配 key → agent 回复 | met | §2 重排为 beta P0（G4+G5）+ backlog（G1-G3）+ post-beta（G6-G10）；§4 优先级逻辑重写 |
| — | v1→v2 变化可追溯 | met | §4 新增 v1→v2 对照表；文档头部标注 v2 |

## 变更概要

- **§1** 用户画像：beta = admin 手动建 workspace + 邀请制；Agent = 托管（非 BYOK）
- **§2** 优先级表：beta P0 = G4+G5；backlog = G1-G3；post-beta = G6-G10；单独立项 = 托管 agent 分身
- **§3** G1-G3：降 backlog，保留用户旅程供规模化阶段启用
- **§3** G4：删 stub_grant，改为硬依赖 cap-signing
- **§3** G5：升级为通用错误机制（infrastructure 级）
- **§3** G6-G10：标 post-beta
- **§4**：优先级逻辑重写 + v1→v2 对照
- **§5**：原降级方案标记为「已废弃」
- **§8**：下一步更新

## Method friction

v1 被 §0 打回，暴露了三个流程问题：

1. **工程缺口清单 ≠ 产品决策已定。** 缺口清单列的是「代码里缺什么」，不是「产品应该什么样」。我在缺产品决策的地方自己填了假设（BYOK、自助注册、降级路径），而不是先标「待 lead 裁定」。
2. **没确认 beta 范围就写了全量计划。** 10 条缺口的用户旅程都写完了，但 beta 实际只需要 G4+G5。应该先问「beta 范围是哪几条」再写。
3. **对外部依赖设计了降级方案，但没验证依赖本身是否快落地了。** cap-signing 已 SOUND 且排期中——这种情况下 stub_grant 的投入产出比是负的。应该在设计降级方案前先确认依赖的实际排期。

以上已补充进 `ezagent-productize-gaps` skill（见本次 commit）。

## Merge request

PR #1436 保持 draft。v2 已对齐 §0，lead 审核后可锁版合并。
