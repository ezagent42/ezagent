# Together Return: P2 逐授权持久撤销

> **Task:** P2 per-grant durable revocation — clean-slate sole mechanism
> **Branch:** `feat/p2-per-cap-revocation`
> **PR:** [#1684](https://github.com/ezagent42/ezagent/pull/1684)
> **Dev:** Codex
> **returned_at:** 2026-08-02 17:45 +0800
> **deadline:** not provided
> **deadline_status:** out_of_scope

## 返回结论

P2 已在一个 target branch 中实现，并通过一次 rebase 收敛到
`origin/main@00f4b3f5bac39694a241d73c954f1a351420ff43`。实现代码 head 为
`60f46675315a7170993bfd78bcf27b752ccbc190`；其远端 deterministic CI 已通过。

最终交付边界符合最新指令：只保留一个
`feat/p2-per-cap-revocation -> main` PR；[#1684](https://github.com/ezagent42/ezagent/pull/1684)
保持 draft、open、未合并。实现者没有合并 `main`，也没有合并最终 PR。

本 return 同时保留一个不能抹去的验证例外：本地整包 `mix precommit` 曾完整运行，
但因跨 application 共享状态污染而非零退出；所有报告失败的文件在新的 BEAM 进程中
独立复跑均通过。远端 code-head deterministic gate 为 green，但 full-suite/canary
按 workflow 条件 skipped。详见“验证证据”和“开放决策”。

## 业务问题与最终设计

原业务问题不是“如何升级权限格式”，而是“撤销一个具体授权后，旧 artifact 还能否
从其它载体复活”：即使从 capability Store 删除，旧授权仍可能存在于 live identity
projection、待处理 delivery outbox、snapshot 或其它持久 carrier 中。#195 的 authority
generation 撤销解决的是一代 authority 的整体失效，不能精确表达“只撤销这一把钥匙，
但允许随后重新授予同一逻辑权限”。

最终模型因此只保留一个内核：

- 每次签发都覆盖调用方输入并生成新的 UUID `grant_id`；
- `grant_id` 是 canonical signed payload 的无条件字段；
- insert-only revocation ledger 按具体 `grant_id` 记录撤销；
- authorize、Store 写入、delivery、snapshot/recipe/provider/event-log 等 carrier
  边界都对整个 grant artifact 做 all-or-nothing、fail-closed 校验；
- 对同一逻辑 capability 再次 grant 会得到新的 `grant_id`，不受旧 marker 影响；
- `IdentityCaps.Store` 是唯一 durable authority，live identity slice 只是可重建 projection。

应用尚未进入生产环境，没有客户权限数据需要迁移。开发数据库是 disposable 的，采用
“删除并从空库重新 migrate/seed/bootstrap”的部署前提。因此最终运行时没有 `v1/v2`、
`signing_version`、revocation epoch、dual read/write、remint、maintenance cutover 或
legacy decoder。authority key generation 与 `key_id` 版本仍保留，因为它们属于密钥轮换，
不是 capability 协议兼容机制。

## 决策过程

### 初始 handoff

`/Users/h2oslabs/P2_KIMI_HANDOFF.md` 最初要求 P2a-P2d：先以 inactive epoch 发布
v1/v2 兼容的逐授权撤销，再在维护窗口 remint Store、做双向 semantic diff、原子激活，
最后进入生产 smoke；同时完成 `EntityCaps -> IdentityCaps` 改名。

### 用户决策覆盖

后续决策改变了约束，而不是只改实现细节：

1. 系统尚未生产化，不需要保护旧权限数据；旧权限可以删除并重新生成。
2. 清空开发数据库后重新初始化，不做数据兼容迁移。
3. 删除全部迁移兼容机制，不命名 `v2`；这就是未来唯一机制。
4. 设计先进行最多三轮对抗性评审，确定后直接自驱开发。
5. 子 phase PR 在测试通过后可自行合入 target branch；最终必须保留一个
   target-branch 到 `main` 的 PR，且实现者不得合并它。
6. rebase `origin/main`，解决六处测试/架构门禁冲突，验证后使用
   `git push --force-with-lease`。

上述决策由 clean-slate 设计文档正式覆盖原 handoff 中的协议版本、epoch、remint、
production cutover 与“不得开最终 PR”部分；原 handoff 的逐授权 ledger、原子撤销、
边界封堵、测试纪律和 branch identity 仍然有效。

### 三轮对抗性评审

| 轮次 | 对抗问题 | 收敛决策 | 对实现的约束 |
|---|---|---|---|
| 1 | 没有生产数据时，为什么仍维护两套协议和 activation 状态？ | 删除 capability 协议版本、epoch、remint 和 production cutover，只保留 signed `grant_id` + ledger。 | runtime 不得出现兼容 decoder、按版本分支或 activation fallback。 |
| 2 | 删除一个 cutover 是否仍留下第二个权限真理源或半合法 artifact？ | 同时删除旧 Identity cutover plane 和 `users.caps_json`；`IdentityCaps.Store` 成为唯一 durable authority；carrier 必须整体 canonical 校验。 | Store-first mutation；live slice 只做 projection；任一字段 malformed/stale/revoked 时整批 fail closed。 |
| 3 | “空库重建”如何成为可执行证据，而不是运维口号？最终分支如何交付？ | 加入独立随机数据库的 migrate/seed/first-boot/revoke/regrant/cold-boot gate，以及精确 source ratchet；固定最终 open PR 契约。 | `ci.clean_per_grant` 必须证明空库和跨进程持久性；PR #1684 保持 open，禁止实现者 merge main。 |

三轮结果已折叠进设计提交 `deb08456b`。完整设计权威是：

- [English design](../../../superpowers/specs/2026-08-01-per-grant-durable-revocation-clean-slate.md)
- [中文设计](../../../superpowers/specs/2026-08-01-per-grant-durable-revocation-clean-slate.zh_cn.md)
- [执行计划](../../../superpowers/plans/2026-08-01-per-grant-durable-revocation-clean-slate.md)

### 实现后的 rebase 收敛决策

rebase 到最新 `origin/main` 后，不采用“让冲突测试先过”的兼容回退，而是继续服从
Store-only authority：

- `Identity.read_held_caps` 改为从 `IdentityCaps` 的持久 authority 读取；
- delivery 场景只对“Store row 确实不存在”解释为空集，以允许首个授权进入；损坏、
  查询错误或 readiness 错误仍 fail closed；
- MemberCap 使用 delivery-aware persisted resolver，避免首 grant 与严格 Store read
  形成自锁；
- SelfAdd 使用 durable effective view，把已提交但尚未 applied 的 outbox grant 纳入
  幂等判定；
- system target authority anchor 接受 `workspace_uri: :any`，保持 current-main 的
  系统 authority 语义；
- 增加 live projection 落后于 Store 时的回归测试，固定 Store 优先级。

## 已完成的工作

- 新增 canonical `GrantArtifact` 校验、签名绑定和无条件 UUID `grant_id`。
- 新增 core-owned、insert-only revocation ledger；撤销、Store、outbox、grantee index
  在事务中收敛 exact-artifact 语义。
- 在 authorize、held-cap Store、delivery outbox、recipe binding、provider callback、
  snapshot 与 EventLog carrier 上补齐 fail-closed gate。
- 把 capability 持久真理源统一为 `IdentityCaps.Store`；cold load 用 Store 替换并修复
  live projection，而不是从 snapshot 或 user row 恢复权限。
- 删除 capability cutover、Identity cutover、backfill/remint/fleet-parity、dual
  read/write、`users.caps_json` 和相应 release/Mix/runbook/test surface。
- 完成 `EntityCaps -> IdentityCaps` 改名，并更新架构 ratchet/safe list。
- 新增真实随机空库 gate，覆盖 migrate、seed、first boot、revoke/re-grant、cold boot、
  schema 检查和临时数据库清理。
- 将开发环境契约固定为 destructive rebuild：旧库、旧 snapshot 和旧 unsigned artifact
  不做修复或导入；采用本分支前必须对精确开发库执行 drop/create/migrate/seed。
- 完成 latest-main rebase、冲突修复、lease-protected force push 和最终 PR。

## DoD reconciliation

以下以“原 handoff + 后续用户决策 + clean-slate design”为闭集。`superseded` 表示要求
被明确取消并由同表中的 clean-slate 验收替换，不表示遗漏。

| # | DoD line | status | proof / decision |
|---|---|---|---|
| 1 | 每个已签发 artifact 有 fresh、signature-covered `grant_id`。 | met | `capability_protocol_test.exs`、`grant_artifact_test.exs`、`authority_verify_against_current_test.exs`。 |
| 2 | 同一逻辑 capability re-grant 得到新 ID，旧 revoke 不伤新 grant。 | met | `identity_caps/store_test.exs`；clean-start task 也执行 revoke/re-grant。 |
| 3 | missing、malformed、被篡改或 stale-authority artifact 被拒绝且不 raise。 | met | `grant_artifact_test.exs`、`authority_anchor_validation_test.exs`。 |
| 4 | Store 写入在事务中拒绝 revoked artifact。 | met | `IdentityCaps.Store` validator 与 `identity_caps/store_test.exs`。 |
| 5 | authorize 立即拒绝 live projection 中已撤销 artifact。 | met | `authorize_test.exs`、`autonomous_current_removal_test.exs`。 |
| 6 | logical revoke 解析真实 stored grant；随机/错误 grant 不可伪造撤销。 | met | `identity_caps/store_test.exs` exact-artifact cases。 |
| 7 | exact artifact 暂不在 Store 时仍可安全写 marker；随机 artifact 不可。 | met | authority + canonical artifact 验证和 absent-Store regression。 |
| 8 | revoked grant 不得 enqueue/drain/replay delivery。 | met | `delivery_outbox_hardening_test.exs` 及 core outbox suites。 |
| 9 | authority anchor 也必须 stamp canonical grant ID。 | met | `authority_anchor_validation_test.exs`；clean-start first boot inspection。 |
| 10 | 冷重启后旧 grant 继续 denied，新 grant 继续 authorized。 | met | `mix ci.clean_per_grant` 的 second normal-application process。 |
| 11 | Store、ledger、outbox、grantee index 的 exact-grant 状态原子收敛。 | met | Store transaction tests、delivery funnel 和 fault-injection suites。 |
| 12 | Store 是唯一 durable authority；live/snapshot/user row 不得成为第二真理源。 | met | `identity_caps_test.exs`、`clean_slate_grant_protocol_test.exs`、cleanup migration。 |
| 13 | 所有 runtime carrier 对 artifact 做整体验证，单个坏元素不被静默跳过。 | met | recipe/provider/snapshot/EventLog carrier owner suites。 |
| 14 | 旧 P2 `v1/v2`、`signing_version`、epoch、remint/cutover 全部删除。 | met | `clean_slate_grant_protocol_test.exs` source ratchet + empty-schema inspection。 |
| 15 | 旧 Identity cutover/dual-write/`users.caps_json` 全部删除。 | met | cleanup migration、source ratchet；`IdentityCaps.Store` sole-authority tests。 |
| 16 | 原 P2a “inactive epoch 同时接受 v1/v2”。 | superseded | 用户明确要求无版本、无 epoch；替代验收是唯一 canonical artifact，非法 artifact fail closed。 |
| 17 | 原 P2b Store remint、semantic diff、wipe/rebuild/activate。 | superseded | 无生产数据；替代为 disposable empty-DB migrate/seed/boot/cold-boot gate，不 remint 旧权限。 |
| 18 | 原 P2c production activation/smoke。 | superseded | 尚未生产；替代为 clean-start acceptance，本文不发布生产 cutover runbook。 |
| 19 | P2d `EntityCaps -> IdentityCaps`，safe list/architecture gates 同步。 | met | rename、ratchet 与 `IdentityCaps` regression suites。 |
| 20 | 开发数据库采用删除后重新初始化，不保留旧权限。 | met | destructive rebuild contract 写入设计、计划、PR；`ci.clean_per_grant` 对随机空库执行真实 migrate/seed/bootstrap 并清理。 |
| 21 | rebase latest `origin/main`，解决测试/架构冲突并 force-with-lease。 | met | merge-base 与 `origin/main` 均为 `00f4b3f5b`；remote implementation head `60f466753`。 |
| 22 | 最终只保留 target -> main PR，且不自行 merge。 | met | PR #1684 是 open draft；base `main`、head `feat/p2-per-cap-revocation`。 |
| 23 | touched suites、clean-start、fast、architecture、format/diff gates。 | met | 见下方逐项结果。 |
| 24 | 本地整包 `mix precommit` 单次进程零失败。 | not_met | 完整运行非零；所有报告失败文件在隔离进程通过，远端 deterministic CI green。合入前由 lead 对此例外作明确裁决。 |

## 验证证据

### 本地通过

- `MIX_ENV=test mix ci.clean_per_grant`：通过；真实临时 PostgreSQL 数据库完成
  migrate、seed、first boot、revoke/re-grant、cold boot 和 schema inspection。
- `MIX_ENV=test mix ci.fast`：core 688/0、identity 4/0、external mirror 39/0、
  session 8/0。
- `MIX_ENV=test mix gate.arch`：core 688/0、identity 4/0、external mirror 39/0、
  session 8/0。
- changed-area bundle：core 5/0、identity 54/0、agent 1/0、workspace 6/0、
  session 20/0、curl 3/0、world 13/0、web 7/0、CLI 4/0。
- `IdentityCaps` regression：11/0。
- delivery funnel：连续 10 次通过。
- Git workflow reconciliation/local-E2E/fault-injection：31/0。
- `mix format --check-formatted`：通过。
- `git diff --check`：通过。
- pre-push deterministic gate：warnings-as-errors compile、format、project
  invariants、URI-query scan、cc-sdk-worker Python tests 全部通过。

### 本地 aggregate gate 例外

`mix precommit` 完成了 umbrella 执行但 exit 2。日志中的失败集中为 DB sandbox owner
退出、live process timeout、registry/manifest residue 等跨 application 共享状态问题。
return 文档完成后的最终重跑同样 exit 2：clean-start migrate/seed/first boot/cold boot
通过；aggregate 中明确观测到 Session 25、CC 1、Hello 39、World 8、Git workflow
26 个失败，末尾 CLI 47/0 与 Python 6/0 通过。该次重跑没有改变以下隔离验证结论。
对应文件换到新的 BEAM 进程后均通过：

- core + Session：44/0；
- CC：2/0；
- Hello：94/0；
- World：7/0；
- Git workflow：31/0。

因此这不是“本地 precommit green”的证据；它是“报告失败均可在隔离环境复现为 green，
但单进程 aggregate 仍有环境/测试隔离债”的证据。

### 远端 CI

- code-head run：
  [GitHub Actions #30733279081](https://github.com/ezagent42/ezagent/actions/runs/30733279081)，
  head `60f46675315a7170993bfd78bcf27b752ccbc190`，conclusion `success`。
- 成功 jobs：gitleaks、frontend regression、`gate (deterministic)`；return advisory
  与 dev-together ownership checks 也成功。
- `full-suite` 与 canary deploy 按 workflow 条件 skipped；不得把 skipped 写成 passed。
- return 文档提交后的最终 PR-head 状态以
  [PR checks](https://github.com/ezagent42/ezagent/pull/1684/checks) 为准，避免在文档中
  固化一个会因本文提交本身而过期的 run ID。

## Proof paths

- 核心 artifact validator：
  `apps/ezagent_core/lib/ezagent/cap/grant_artifact.ex`
- 撤销 ledger：
  `apps/ezagent_core/lib/ezagent/cap/revocation_ledger.ex`
- 唯一 capability Store：
  `apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex`
- clean-start executable gate：
  `apps/ezagent_core/lib/mix/tasks/ezagent.cap_revocation.verify_clean_start.ex`
- clean-start scenario：
  `apps/ezagent_core/test/support/clean_start_scenario.ex`
- compatibility source ratchet：
  `apps/ezagent_core/test/invariants/clean_slate_grant_protocol_test.exs`
- final schema cleanup：
  `apps/ezagent_core/priv/repo/migrations/20260801000300_remove_identity_cap_compatibility.exs`
- detailed acceptance-to-test mapping：design §9 “Implementation evidence map”。

## Deferred follow-ups / 开放决策

1. **Lead gate decision:** 是否接受“远端 deterministic CI green + 所有本地失败文件隔离
   复跑 green”作为本 PR 的合入证据，或先修复 umbrella 测试共享状态，再要求单次
   `mix precommit` green。
2. **Full-suite policy:** 当前 draft PR 的 full-suite job 为 skipped。若合入策略要求该
   job 必须执行，lead 需要按仓库流程触发并等待 green。
3. **Developer reset:** 每个采用本分支的开发环境必须对精确 dev database 做 destructive
   drop/create/migrate/seed。不得导入、remint 或兼容旧 permission artifacts。
4. **Production migration:** 无。本 PR 有意不提供 production cutover；未来若在已有客户
   数据后再次改变协议，必须建立新的设计，不得复活本次删除的兼容 plane。

## Method friction

- 初始 handoff 的生产 cutover 假设与“尚未生产、可重建数据库”的真实业务状态不一致。
  如果直接实现原文，会永久增加一个无业务收益的安全状态机。设计阶段先把业务前提固定，
  才能安全删除版本、epoch 和 remint。
- 大范围 Store authority 收敛与 current-main 的 transport readiness、fixture 和 architecture
  ratchet 同时演进，rebase 产生六处测试/架构冲突。最终以 Store-only authority 和
  fail-closed 边界为裁决标准，而不是恢复 legacy fallback。
- umbrella 测试在同一 BEAM 进程内共享 DB/Registry/application 状态，导致 aggregate
  结果与独立文件结果分裂。return 将两类证据分开记录，避免把独立通过误写成整包通过。
- 早期历史 commit subject 中仍有 `v2`/epoch/cutover 字样；这些是被后续 clean-slate
  refactor 明确删除的演进记录，不代表最终 runtime contract。最终行为以当前 tree、
  source ratchet 和 clean-slate design 为准。

## Merge request

请 lead/coordinator 评审 [PR #1684](https://github.com/ezagent42/ezagent/pull/1684)：

- 确认 return 文档提交后的 PR-head checks；
- 对本地 aggregate `mix precommit` 例外和 skipped full-suite 作明确裁决；
- 若证据达到仓库合入标准，再把 draft 转为 ready 并由 coordinator 合入 `main`。

实现者的交付到此停止：不自行合并 PR，不直接合并 target branch 到 `main`。

## 给 lead 的 return message

> P2 clean-slate per-grant revocation 已返回到
> `feat/p2-per-cap-revocation`，最终 PR 为 #1684。实现 head `60f466753` 已 rebase 到
> `origin/main@00f4b3f5b`，远端 deterministic CI green。完整决策、三轮对抗评审、
> DoD 和验证例外见本文。请先复核 return-doc head checks，并裁决本地 aggregate
> `mix precommit` 非零及 full-suite skipped；通过后由 coordinator 合入 main。
