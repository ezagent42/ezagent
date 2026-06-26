# Return — Deploy: durable secrets home + runner decouple + prod→lower reflow

> **Task:** deploy-secrets-reflow(deploy-flow 的两个跟进能力:#2 secrets 持久化 + runner 解耦;#1 prod→beta/nightly 数据回流)
> **Branch:** `feat/deploy-secrets-reflow`(off `feat/deploy-flow` @ `3332dc2e`)
> **PR:** **#1010**(base `feat/deploy-flow` —— stacked on #996;合 #996 后自动 retarget 到 main)
> **Dev:** Claude(agent)
> **returned_at:** 2026-06-26 (+0800)
> **deadline:** n/a(无 dev-together `plan.md`)
> **deadline_status:** out_of_scope(用户直接发起的 deploy-flow 跟进)
> **依赖:** PR #996(deploy-flow 三环境)—— 本 PR 基于其分支,**#996 先合**。

## What's done

deploy-flow(#996)落地后用户提了两个运维需求,本 PR 实现并实机验证:

### #2 — secrets 持久家 + runner ephemeral-checkout 解耦
- secrets 迁到**主 checkout** `/Users/h2oslabs/Workspace/esr-ng/docker/`(worktree 清掉不丢)。
- `deploy.sh`/`backup.sh` 从 **`EZAGENT_SECRETS_HOME`(绝对路径,默认主 checkout)** 读 `.env.*`,**code(compose/脚本)仍从当前 checkout** —— 这样 runner 用自己的 ephemeral `_work` checkout 跑也能拿到持久 secrets(否则 `git push beta/release` 触发的自动部署会缺 `POSTGRES_PASSWORD`/`.env.infra` 而失败)。`.env.<channel>` 的 `SECRETS_DIR` 也改绝对。
- 保护:`docker/.gitignore`(自包含,**任何分支**生效,不依赖 root .gitignore 合并)+ 仓库 `.git/info/exclude`(即时、跨 worktree)。
- **实测**:`deploy.sh nightly` 从 follow-up worktree 读 durable secrets → recreate nightly **healthy**;`/secrets` mount source = `/Users/h2oslabs/Workspace/esr-ng/docker/secrets-nightly`(主 checkout 路径)。

### #1 — `reflow.sh`:prod→beta/nightly 数据回流(测迁移)
- **单向**:source 固定 `stable`,target 只能 `beta`/`nightly`(脚本显式拒绝 `stable` 作 target,绝不写 stable)。
- 流程:保存目标 credentials(**DB 11 张敏感表** data-only + **agent-FS `default/credentials`** 子树)→ `stable` 全量覆盖目标 DB + `*_home` → 目标(更新的)代码 `Release.migrate()`(=**测试迁移 against prod 数据**)→ 盖回目标 credentials。**prod 真实凭据永不落到低环境。**
- **修了一个真 bug**:DB 盖回若用 `TRUNCATE … CASCADE` 会误删 FK 依赖的**非凭据表**(`email_thread_state` 经 `email_inbound_binding` 被级联清空)。改用 `DELETE` + `session_replication_role=replica`(关 FK 触发,只清凭据表本身)。
- 敏感表 / FS 路径可经 `EZAGENT_CRED_TABLES` / `EZAGENT_CRED_FS_PATH` 覆盖。
- **实测 stable→beta**(seed 标记验证三性质):① stable 非凭据数据(`app_settings` marker)回流进 beta ✓ ② beta 自己的 `protocol_api_keys`(`beta_own_key`)**存活**、未被 stable 覆盖 ✓ ③ 迁移后 beta **healthy** ✓。测试标记已清理。

文档:`docs/guide/deploy-mac-stack.md` 加 §secrets 持久家 + §6.1 reflow。

## DoD 对账

| 条目 | 状态 | 证据 |
|---|---|---|
| #2 runner 能用持久 secrets | **met** | deploy.sh nightly 读 `EZAGENT_SECRETS_HOME` recreate healthy;mount source = 主 checkout |
| #2 secrets 不随 worktree 丢 + 不误提交 | **met** | 主 checkout 持久;`docker/.gitignore` + `.git/info/exclude`,`git check-ignore` 绿 |
| #1 reflow 回流 prod 数据(DB+FS) | **met** | stable 非凭据数据进 beta(`app_settings` marker) |
| #1 目标凭据存活、prod 凭据不落地 | **met** | `beta_own_key` 存活;DELETE+replica scrub,不级联误删 |
| #1 回流后迁移可跑 | **met** | beta `Release.migrate()` 后 healthy |
| #1 单向(prod 不被低环境污染) | **met** | 脚本拒绝 `stable` 作 target;只读 stable |

## Gate status

纯 infra/脚本(无 `.ex` 应用代码)→ `mix` 门禁不适用。`bash -n` 三脚本绿;reflow/secret-path 均实机跑通。

## Merge request

- **PR #1010**,base `feat/deploy-flow`(stacked)。**合并顺序:#996 → main 先合,#1010 再合(GitHub 会把 base 自动 retarget 到 main)。** 由 lead 按 dev-together `close` 合。
- 改动全 additive:`docker/{deploy.sh,backup.sh,reflow.sh,.gitignore}`、`docs/guide/deploy-mac-stack.md`、本 return。
- 运行态副作用:**`beta` 现带 stable 数据**(reflow 测试结果,符合预期;`nightly` 未动)。

## Leftovers / 后续

- **定时回流**:launchd timer 跑 `reflow.sh beta`(夜间 stable→beta),按需。
- **GitHub branch protection(beta/release)+ Environments(stable required reviewers)**:见 #996 return §Leftovers,建议合并后配,自动 promotion 才安全。
- reflow 的 FS 回流目前覆盖整个 `*_home`(含 agent 工作目录/node_modules,较重);如需只回流"数据相关"子集可后续优化。
- 跨域(DB+FS)一致性快照(quiesce+LSN)仍是迭代项(同 #996)。
