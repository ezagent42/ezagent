# handoff · 2026-06-26 · jjkysy — dev-together skill 改进落地

**FP6**：把 dev-together skill 改进落地（你是 skill owner）。

## 背景
6-25/26 lead 据实践给出一批 skill 改进要求，已整理成 plan：`docs/together/2026-06-26/dev-together-skill-improvement-plan.md`（含逐文件 changelist + 模版草图）。你已有同名分支 `chore/dev-together-skill-improve`——在其上落地。

## 今日交付（DoD）按 plan 实施
- [ ] **current-date flag**：`docs/together/CURRENT_DATE`（单行 YYYY-MM-DD）+ `advance_cycle_date.sh`（4 个 lead 确认前置才翻日）；命令里所有 `date +%F` 改读 CURRENT_DATE。
- [ ] **review/plan HTML 模版**：`references/review-template.html` + plan 模版（数据驱动，下周期换数据即可，**对齐 6-25 review.html / 6-26 plan.html 的版式**）；`gather_stats.sh` → 落库 `stats/cycle-data.json`。
- [ ] **contributing/ 读前置**：handoff（下发+返回）前必读 `docs/together/contributing/`；用必填 `contributing_read_through` attestation 字段做闸 + 提醒 hook。
- [ ] **团队向 scrub 规则**：plan/review 禁含 lead↔agent 讨论内容；`references/team-facing-scrub-checklist.md` + SKILL.md 硬规则。
- [ ] **归属方法论**：统计按 work-author（走 target-branch 流时按 target 分支 commit 作者，非 main 合并者）。
- [ ] **feature-point**：plan 阶段先约定 FP 口径（自 6-27 起）。
- [ ] `validate_skill.sh` 为每条新规则加断言。

## 参考
plan 已发现 jjkysy 分支与 Allen 要求是叠加关系（A–E 是其超集）。设计版式可让 `ruihuachen-designer` 提供输入。

## 约束
`.claude/skills/dev-together/**` 单一写者=你。进 main 的 PR 需 precommit+check_invariants 绿 + rebase。handoff 前读 `contributing/`。
