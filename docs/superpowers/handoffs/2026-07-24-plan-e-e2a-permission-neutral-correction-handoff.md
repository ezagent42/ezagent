# Handoff：Plan E E2-A — permission-neutral workflow intent/CAS correction

> **日期：** 2026-07-24 · **From：** Plan E lead · **To：** 原 E2 worker session
>
> **状态：** confirmed pivot
>
> **现有 worktree：**
> `/home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-workflow-intent`
>
> **现有 branch：** `feat/git-provider-v1-plan-e-workflow-intent`
>
> **原 base：** `e34b45c5a6d572180af0899d24b7ce05e4267c9e`

## 1. 先完整读取

1. `/home/huangjiajia/ezagent/docs/together/2026-07-24/handoffs/git-provider-v1-permission-avoidance.md`
2. `docs/superpowers/specs/2026-07-24-git-provider-v1-plan-e-permission-neutral-pivot.md`
3. `docs/superpowers/plans/2026-07-24-git-provider-v1-plan-e-permission-neutral-implementation.md`
4. 原 E2 handoff；只保留与本 handoff 不冲突的 typed intent/CAS 要求。

新 permission-avoidance handoff 在冲突处优先。

## 2. Session 与 checkpoint

继续使用原 E2 session 和原 worktree，不重开、不 rebase、不丢弃 dirty tree。

修改任何文件前：

```bash
git status --short
git diff --stat
git log --oneline -5
```

记录最近 focused test 的命令、退出码和摘要。在 worktree 根目录、gitignored
`in-progress.md` 写：

```text
RESUME HERE: checkpoint before E2-A permission-neutral pivot
```

然后提交当前 tree：

```text
chore(git-workflow): checkpoint before permission-neutral pivot
```

返回 checkpoint SHA 后，继续同一 session 实施 E2-A。

## 3. 当前唯一目标

完成权限无关的：

- migration；
- typed binding/run/internal command；
- canonical `RepositoryRef`；
- accepted intent；
- unique insert-or-load idempotency；
- digest conflict；
- single-SQL PostgreSQL CAS；
- 真实并发/retry tests；
- secret/dependency/side-effect/no-ingress gates。

E2-A 接收 already-validated internal command，不识别 caller，不判断 capability。

## 4. 必须从当前 tree 修正

1. 修正 migration 的 custom primary key，并用 fresh partition 真实运行 migration；
   删除测试中重复 `CREATE TABLE IF NOT EXISTS` 和伪造 `schema_migrations`。
2. 通过现有 canonical URI 和 `RepositoryRef.new/1` 验证 binding。
3. 服务端生成 run id、input digest、`status: accepted`、`state_version: 1`；
   caller 不得直接控制这些字段。
4. 消除 `SELECT → INSERT` 竞态。insert conflict 后 fresh-read 并重新比较 digest。
5. 使用独立 PostgreSQL connections + 同步起跑点证明：
   - 20 个 identical accepts 返回同一 run，DB 一行；
   - concurrent different digest 只有一个成功，其他 closed conflict；
   - 20 个 same-version transitions 只有一个数据库状态推进。
6. 闭合 exact retry、stale、status 和 terminal conflict。
7. 删除或延期当前 GitWorkflow ActionSet/public registration；不得让 route、CLI、
   agent tool、socialware 或 plugin action 触达写路径。
8. 删除 fake authorization tests、placeholder principal nil-check 和
   `authenticated_principal` 当前切片要求。
9. app-local `apps/ezagent_plugin_git_workflow/plan.md` 不得提交；planning files
   只放 worktree root。

## 5. 明确禁止

- 修改 `apps/ezagent_core/lib/ezagent/cap/**`；
- 修改 `EntityCaps`、`PresenterCaps` 或 authorization gates；
- wildcard/admin fixture；
- `Cap.issue/store`；
- ActionSet/public route/CLI/agent ingress；
- test-only production bypass 或 fake-green auth tests；
- GitHub/Req/provider HTTP；
- Kind/workspace/Agent/sidecar；
- real credential、GitHub mutation 或 canary。

发现必须修改以上范围时立即停止，返回 file:line 和最小缺口，不得自行适配。

## 6. 验证

```bash
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 \
  mix test apps/ezagent_plugin_git_workflow/test/

MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix ci.fast
MIX_ENV=test MIX_TEST_PARTITION=plan_e_e2 mix precommit
git diff --check
git status --short
```

若 full gate 受 base infrastructure 阻塞，返回完整命令、退出码和 base/head 对照；
不得跨 owner 修复。

## 7. Return

必须包含：

1. worktree/branch/original base；
2. checkpoint SHA 和 final SHA；
3. commits；
4. final `git status --short`；
5. changed files/migration；
6. fresh migration 证据；
7. 真实多连接 PostgreSQL 并发证据；
8. 每条 E2-A DoD 的 PASS/FAIL + file:line + test output；
9. no-ingress/no-Cap/no-secret/no-side-effect audit；
10. 未决风险。

只允许声明：

```text
E2-A 当前切片完成，等待 lead review。
```

不得声明 Git Provider E2E、Plan E、授权闭环或 Agent-driven PR loop 完成。不得
push、开 PR、merge 或操作 canary。
