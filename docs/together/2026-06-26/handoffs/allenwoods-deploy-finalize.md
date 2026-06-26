# handoff · 2026-06-26 · allenwoods — deploy-flow 收口 + 端到端验证

**FP1**：deploy flow 三环境（nightly/beta/stable）端到端晋级跑通、可对外日用。

## 背景
6-25 off-plan 完成了 deploy-flow 子环节：#996（三环境晋级阶梯 + CI/CD + 备份）+ #1010（secrets 持久家 + runner 解耦 + prod→低环境 reflow，已实机跑通 stable→beta）。两者仍 OPEN。本日把它收口并做整体 E2E（**E2E 归本人——deploy context 在你身上，闭环原则**）。

## 今日交付（DoD）
- [ ] **#996 → main 合**（base main）；**#1010 retarget 到 main 后合**（base 自动切）。
- [ ] **三环境端到端晋级 E2E**：nightly→beta→stable 一条龙跑通（含 secrets 持久、reflow、迁移），附证据。
- [ ] 协调 **agent 层集中回归**（地基大改后）：跑全量 `mix precommit` + check_invariants，确认 agent 运行时不回归。
- [ ] **清理**：关闭 #964 + #985（kanban 旧方案，已被 #1004/#1007 取代，评论指向新 PR）；关闭 #911（陈旧 stack PR）。

## 顺延 6-27
py-agent **P3（world e2e）+ P4（np→py-role）+ #108（flake 根治）**。P1+P2 已合 main（2bed5961）。

## 涉及
`docker/` deploy.sh/backup.sh/reflow.sh · `feat/deploy-flow` / `feat/deploy-secrets-reflow` · CI/CD workflows。

## 约束
进 main 的 PR 需 precommit+check_invariants 绿 + rebase；branch protection（beta/release）+ Environments（stable）合并后配。handoff 前读 `docs/together/contributing/`（尤其 P0/P5）。
