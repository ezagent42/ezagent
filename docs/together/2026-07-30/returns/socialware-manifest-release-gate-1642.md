> **Task:** socialware-manifest-release-gate-1642
> **Branch:** `ci/socialware-manifest-release-gate`
> **PR:** [#1642](https://github.com/ezagent42/ezagent/pull/1642)
> **Dev:** zyli
> **returned_at:** 2026-07-30 14:40 +0800
> **deadline:** 2026-07-30 23:59 +0800
> **deadline_status:** out_of_scope

## 已完成

- 在既有 CI `gate` job 中增加 Socialware manifest release contract：PR 修改任一 deploy package 的 `manifest.yaml` 或 `recipes.yaml` 时，必须同步修改该 package 的 `release.yaml`。
- gate 失败时输出 `mix ezagent.socialware.import_remote` 的 dry-run 与实际导入命令；CI 不持有也不连接线上节点凭证。
- 为 gate 添加 shell 回归用例，覆盖无关改动、缺失 marker、recipes 变更、匹配 marker 和错误 package marker。
- 已在本地运行节点将 Hello manifest 通过受治理 RPC 导入，结果为 `socialware hello → upgraded`；新建 session 验收成员 `front-desk`、`llm` 由产品侧执行。

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | 未同步 `release.yaml` 的 manifest/recipes 改动会被阻止 | met | `.github/scripts/socialware-manifest-release-gate_test.sh` 覆盖两个缺失-marker 场景；本地通过。 |
| 2 | 合法改动不会被误阻止 | met | 同一回归脚本覆盖无关源码改动与同 package marker 场景；本地通过。 |
| 3 | 使用既有必需 CI gate | met | `.github/workflows/ci.yml` 将 contract 放入现有 `gate` job；无新增 job。 |
| 4 | PR CI 全绿并完成评审 | deferred | PR #1642 当前 CI 排队/运行中；frontend、gitleaks 等检查尚无结论。合入前须由 CI 结果与审查确认。 |

**Method friction:** 此任务并非当日 board 预先计划项，因此标记为 `out_of_scope`；同时，完整 `mix precommit` 在未改动的 `Ezagent.Invariants.EntityCapsMutationBoundaryTest` 上发生 60 秒超时，不能作为本 PR 已全绿的证据。与本次改动直接相关的 gate 回归和 `mix ci.fast` 已通过。

## 验证证据

- `bash .github/scripts/socialware-manifest-release-gate_test.sh`：通过。
- `mix ci.fast`：通过。
- `mix ezagent.socialware.import_remote apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml --dry-run`：manifest 解析通过。
- 运行节点导入：`socialware hello → upgraded`。
- 当前 PR 头：`ac82b649c7918ebfac50d861beac36459eca4aa4`，基于 `origin/main` `7536fd23540c6ad2ee23296377e9eee5ee49c645`。
- CI 状态（14:40 +0800）：frontend、gitleaks、dev-together skill guard 排队；Return file advisory 运行中。

## 延后项与开放决策

- **CI/评审结论**：待 PR #1642 的 GitHub checks 全绿后，lead 决定是否从 draft 转为可合入状态。
- **旧 session 迁移**：不在本 PR 范围；已创建 session 固定已安装的 definition revision，应另行设计显式迁移，不应通过重启隐式修改。

## Merge request

- Branch: `ci/socialware-manifest-release-gate`
- PR: [#1642](https://github.com/ezagent42/ezagent/pull/1642)
- Rebase base: `7536fd23540c6ad2ee23296377e9eee5ee49c645` (`origin/main` at branch creation)
- 该 PR 仅含 release gate 与本 return/task 记录；不包含 Hello workspace 刷新修复或 pnpm 生成文件。
