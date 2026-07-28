> **Task:** #1436 — 对齐 §0 Allen 7 项裁定，完成 v3 结构重构
> **Branch:** `docs/workspace-self-service-product-plan`
> **PR:** https://github.com/ezagent42/ezagent/pull/1436
> **Dev:** ruihua（designer）
> **returned_at:** 2026-07-17 15:30 +0800
> **deadline:** 2026-07-17
> **deadline_status:** on_time

## DoD reconciliation

Handoff = Allen 的 7 条裁定（已写入 §0），要求「把各 G 段细节对齐重排」。

| # | DoD line | status | proof |
|---|----------|--------|-------|
| ① | G1/G2/G3 移出 beta P0 → backlog | met | §2 总览表 backlog 行；§4 backlog 段（G1/G2/G3 各标触发条件）；§4 排序逻辑 |
| ② | G3 收敛为文档化单-own，不做多 workspace UI | met | G3 标题 + 现状反映 beta 现实（admin 创建 workspace）；**方案 B 已删除**（标「已由决策 ② 否决」） |
| ③ | Agent/Key = 托管 agent，单独立项；BYOK 仅内部开发者 | met | §1 Agent/Key 模型；§2 单独立项行；§8；G4 不含 BYOK 假设；G5 示例不含 BYOK 语言 |
| ④ | G4 不做 stub_grant，等 cap-signing | met | G4 标题「硬依赖，不降级」；**§6 降级方案标记为废弃**；§4 v1→v3 变化表 |
| ⑤ | G1/G2 机制已存在，只缺 UI；beta 邀请制 | met | §1 注册方式；§2 G1/G2 说明列；G1/G2 各自 §0 裁定引用；backlog 段触发条件首段 |
| ⑥ | G5 = 通用可配置错误机制 | met | G5 Blueprint + **三层错误处理**（Layer 1/2/3）+ Admin 行为总览表 + 12 条 AC |
| ⑦ | beta 范围 = admin 开通 + agent 回复 | met | §1 成功定义；§2 总览表（beta 只含 G4+G5）；§4 排序逻辑；G10 E2E 改锚 beta 闭环 |
| — | 文档结构：beta / backlog / post-beta 三大段 | met | v3 重构：§3 beta（G4+G5）、§4 backlog（G1-G3）、§5 post-beta（G6-G10）、§6-§9 附录 |
| — | backlog 缺口标注触发条件 | met | G1：「平台从 beta 邀请制 → 开放自助注册」；G2：「同 G1，或 CLI 邀请频率不可持续」；G3：「产品决策翻转（允许用户 own 多个 workspace）」 |
| — | post-beta 缺口标注触发条件 | met | G6：「beta 稳定 + 普通用户日常使用」；G7：「外部企业用户开放 + admin 不再当面引导」；G8：「真实业务场景出现」；G9：「重复性使用问题出现」；G10：「beta 闭环稳定 + 持续 PR 流」 |

## v1 → v3 演进

| 版本 | 主要变化 |
|------|---------|
| v1 | 10 条缺口 4 批排期，含 BYOK 假设 + stub_grant 降级方案 |
| v2 | 对齐 §0：G1-G3 降 backlog，G4 删 stub，G5 升级，G6-G10 标 post-beta。但结构仍混排，G5 示例残留 BYOK，G3 未删方案 B |
| v3 | 结构重构为 beta/backlog/post-beta 三大段；backlog/post-beta 缺口标注触发条件；清除全部 BYOK 残留（G4/G5/G10）；G3 方案 B 删除；G5 示例替换为通用场景；G10 E2E 改锚 beta 闭环 |

## Method friction

1. **v2 修订不彻底。** §0 裁定写在了 G 段头部，但细节（示例、AC、E2E 场景）仍有 v1 残留。教训：裁定对齐需要逐段审计——不只是标题和第一段，示例和验收标准也要查。
2. **backlog 缺口只标了优先级标签，没有触发条件。** v2 把 G1-G3 标为 "backlog" 但没有说明什么情况下重新考虑。v3 补充了触发条件——读文档的人知道「现在不用管，等 X 发生时再说」而不是「被放弃了」。
3. **G5 与 G6 的重叠未被发现。** G5 通用错误机制落地后，G6 痛点 E（裸 atom）自然解决。v3 在两处标注了重叠，避免重复工作。

以上已补充进 `ezagent-productize-gaps` skill。

## Merge request

PR #1436 保持 draft。v3 已完成 7 条裁定逐条对齐 + 结构重构 + backlog 触发条件标注。lead 审核后可锁版。
