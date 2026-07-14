# Together Return: Session view tab actions

- Task: 优化 Session Detail 中无响应的 Bindings 和 Routing 标签
- Branch: `codex/fix-session-view-tabs`
- PR: https://github.com/ezagent42/ezagent/pull/1389
- Dev: zyli
- returned_at: `2026-07-14 17:08 +0800`
- deadline: not provided (out-of-scope request)
- deadline_status: out_of_scope

## DoD reconciliation

| DoD | Status | Proof |
| --- | --- | --- |
| 从最新远程 `main` 开新分支 | done | 分支已 rebase 到 `origin/main` `22d966b041cdccc621bee8b112fe361b18cb5f63` |
| Bindings 点击后进入当前 Session 的 ExternalMirror | done | `Conversation.tsx` 将 Bindings 渲染为包含当前 `sessionUri` 的内部管理链接 |
| Routing 点击后展示已有路由配置入口 | done | 点击 Routing 会打开成员侧栏并展开 Advanced Rules |
| 增加回归测试 | done | `world_navigation_test.mjs` 和 `world_ui_structure_test.mjs` 覆盖新行为 |
| 前端相关验证通过 | done | World IA、navigation、UI structure 测试及生产构建通过；`git diff --check` 通过 |
| 完整仓库门禁通过 | done | 最终 PR head 的 deterministic gate、gitleaks、Return Advisory 与 dev-together 保护检查均通过 |
| 创建 PR 并提交远程 | done | Draft PR #1389，远程分支已更新 |

## What changed

- Bindings 不再发送没有对应原生视图的切换事件，而是直接进入当前 Session 的 ExternalMirror 页面。
- Routing 不再停留在聊天视图，而是打开成员面板并展开 Advanced Rules。
- Routing 的选中态与抽屉开关保持同步，切换 Session 时会重置。

## Proofs and gates

- Rebase base: `22d966b041cdccc621bee8b112fe361b18cb5f63`
- Code head: `7521545fe3c23cd4e300299f21d5a5e6e9e8bfcd`
- PR: https://github.com/ezagent42/ezagent/pull/1389
- CI run: https://github.com/ezagent42/ezagent/actions/runs/29320758884 (`success`)
- Dev Together Return Advisory: https://github.com/ezagent42/ezagent/actions/runs/29320758915 (`success`)
- Protect dev-together skill: https://github.com/ezagent42/ezagent/actions/runs/29320758883 (`success`)

## Follow-up notes

- 本地 `POSTGRES_PORT=5432 mix precommit` 在 600 秒后超时，并暴露未修改文件 `world_live.ex:216` 的既存 URI query scan finding，以及本机 WSL 缺少 `pg_dump`；最终远程 deterministic gate 已通过。
- 上述本地环境/既存项不阻塞本 PR，但可另行收口以改善本地全量门禁体验。

## Method friction

- 工作开始后远程 `main` 新增提交，因此在创建 PR 前重新 rebase 并使用 `--force-with-lease` 更新专用分支。
- 完整本地门禁耗时超过 10 分钟，且被仓库既存扫描项和宿主工具缺失影响；前端目标测试与构建均已独立验证。

## Merge request

最终 PR head 的必需 CI 已全绿，分支已 rebase 到当前 `main`，本 Return 有效。PR 当前按发布流程保持 Draft，可由维护者转为 Ready for review 后合并。
