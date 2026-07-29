# Git Provider V1 Plan E 权限无关推进修正案

**状态：** lead 已于 2026-07-24 确认

**协调基线：** `origin/main` @
`86fd926b3297ffd50f7e81eaee1f6cae13cf0a62`

**受管控主工作区：** `/home/huangjiajia/ezagent`，固定 `main`，Plan E
worker 不得修改

## 1. 决策

Plan E 继续推进，但 Ezagent authorization integration 与权限无关的
provider/workflow 基础分离：

```text
E2-A：already-validated internal command
→ typed durable intent
→ PostgreSQL idempotent accept / digest conflict / CAS

E2-B：principal + exact action + exact target URI + workspace
→ allow | deny | authorization_unavailable
→ allow 时调用 E2-A
```

Allen/main 负责 CapBAC 收敛。Plan E worker 不修改或适配 CapBAC 内部，不创建
wildcard/admin fixture，不直接 issue/store cap，不修改 `EntityCaps` 或
`PresenterCaps`。

本修正案在冲突处取代：

- `2026-07-24-git-provider-v1-plan-e-simplified-execution-amendment.md` 中要求
  E2 当前闭合授权、public ActionSet 和 release ingress 的内容；
- `2026-07-24-git-provider-v1-plan-e-simplified-implementation.md` 中 E2 authority
  tests、ActionSet 注册和“E2 完成后直接派 E3”的顺序；
- `2026-07-24-plan-e-e2-workflow-intent-handoff.md` 中
  `authenticated_principal`、revocation、cap matching、sanctioned admin/claim
  authority 和 public action wiring 的当前切片要求。

不冲突的 typed intent、canonical DomainGit values、idempotency、digest conflict、
PostgreSQL CAS、secret/side-effect gates 继续有效。

## 2. 当前波次

| Slice | 继续内容 | 当前禁止 |
|---|---|---|
| E1 | operation-scoped GitHub App credential、exact repo/permission、secret audit | Ezagent cap construction |
| E2-A | migration、typed binding/run、internal accept、idempotency、digest conflict、CAS、真实并发测试 | public/action/route/CLI/agent ingress、CapBAC |
| E2-B | 延期到 Allen/main resume gate 后的薄授权入口 | 在 resume gate 前实施 |

E1 与 E2-A 可并行并独立验收。E3 原设计含 authority materialization，在 E2-B
验收前不得派发。

## 3. E2-A 边界

E2-A 接收已经验证的内部命令。它不负责识别 caller、解析 live dispatch ctx 或判断
capability。

E2-A 必须：

- 使用 canonical URI 与 `Ezagent.DomainGit.RepositoryRef`；
- 只持久化 provider-neutral、non-secret typed intent；
- 服务端生成 run identity、input digest、初始 `accepted/1`；
- 以数据库唯一约束和 insert/fresh-read 实现 exact retry；
- 对同一唯一键的不同 digest fail closed；
- 以单 SQL conditional update 实现 CAS；
- 使用真实多连接 PostgreSQL 竞争测试证明原子性；
- 对 secret、provider HTTP、Kind/cap/workspace/Agent/sidecar side effect
  建立静态和运行时 gate。

E2-A 不得：

- 注册 ActionSet、route、controller、CLI、Mix task、agent tool、socialware 或
  skill ingress；
- 让不可信 caller 触达 write path；
- 添加 wildcard/admin fixture、fake-green authorization tests 或 production
  bypass；
- 调用 `Cap.issue/store`，或修改 CapBAC、`EntityCaps`、`PresenterCaps`；
- 调用 GitHub adapter、Req、workspace provision、Kind spawn、Agent 或 sidecar。

`authenticated_principal` extraction、holder currency/revocation、exact cap matching
及 admin/claim authorization 全部属于 E2-B。E2-A 不以 placeholder principal
字段或 nil-check 模拟授权完成。

## 4. E2 dirty worktree checkpoint

现有 worktree：

```text
/home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-workflow-intent
```

在 pivot 前必须记录：

- `git status --short`；
- `git diff --stat`；
- 最近 focused test 命令与结果；
- root-level、gitignored `in-progress.md` 中的 `RESUME HERE`；
- checkpoint commit SHA。

checkpoint 只作恢复/取证，不单独集成。最终由 lead 审核 E2-A 的净变更，确保旧
ActionSet、authorization 模拟和无效 migration 不进入 integration tree。

## 5. E2-A 完成定义

- [ ] fresh test partition 真实执行最终 migration；
- [ ] binding/run/command 均为 typed provider-neutral values，无 arbitrary payload；
- [ ] concurrent identical accepts 返回同一 run，数据库只有一行；
- [ ] concurrent different digest 对 loser 返回 closed conflict；
- [ ] concurrent same-version CAS 只有一个数据库状态推进；
- [ ] exact retry、stale、status 和 terminal conflict 错误稳定；
- [ ] 无 secret/provider-private 字段或日志/错误泄漏；
- [ ] 无 Cap/Kind/workspace/Agent/sidecar/provider HTTP side effect；
- [ ] 无 public/action/route/CLI/agent ingress 到达写路径；
- [ ] focused tests、touched-app tests 和适用静态 gates 通过；
- [ ] Return 明确只声明 `E2-A 当前切片完成`，不得声明 Git Provider E2E 完成。

## 6. E2-B resume gate

只有 Allen/main 发布并稳定以下 sanctioned contract 后才创建新的 E2-B
worktree：

```text
principal + exact action + exact target URI + workspace
→ allow | deny | authorization_unavailable
```

`authorization_unavailable` 必须 fail closed，并产生零 workflow/provider/filesystem
side effect。E2-B 只能是调用 E2-A 的薄入口；不得重写 E2-A 的 schema、
idempotency、digest 或 CAS。

## 7. 后续顺序

```text
E1 + E2-A（并行）
→ lead 分片验收和 integration
→ Allen/main authorization resume gate
→ E2-B
→ E3 workspace/worker/authority
→ E4 create PR vertical slice
→ E5–E9 observation/projection/socialware/canary
```

真实 GitHub mutation、credential read 和 canary 仍需 E9/operator gate；当前切片
不授权这些动作。
