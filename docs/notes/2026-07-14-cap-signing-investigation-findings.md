# Cap-signing 无尾巴升级：调查结论

**日期：** 2026-07-14

**范围：** 仅调查与验证测试；未改产品代码，未开启 `require_signature:true`，未触碰线上 canary/beta/stable/dev/prod。

**结论：** 现在不能 flip enforce。全通配 cap 本身可以签；真正的尾巴来自“未经过 `Cap.issue/3` 的结构 cap / seed”以及“已有未签 cap 使幂等重派生提前跳过”。

## 方法与环境

从指定 dump
`~/Workspace/ezagent-deploy/backups/canary/20260713T200002Z/db.sql.gz`
恢复只读来源库 `ezagent_raw0714`，再从它克隆 ExUnit 分区库
`ezagent_pg_compat_testcapinv0714`。测试使用 `mix test --no-start`；test helper
只启动 core（Repo/registry），每个下游应用和每条正常生命周期路径都在同一个
SQL Sandbox 事务里显式启动/调用，测试结束回滚。没有使用会在 sandbox owner
建立前 boot 全应用的临时 `mix run` harness。

正式探针在：

- `apps/ezagent_domain_identity/test/integration/cap_signing_notail_investigation_test.exs`
- `apps/ezagent_core/test/ezagent/cap_test.exs`（全通配 `Cap.issue` / `Signing.sign`）

运行命令：

```sh
CAP_SIGNING_INVESTIGATION=1 \
MIX_TEST_PARTITION=capinv0714 \
MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps \
MIX_ENV=test \
EZAGENT_SIGNING_SEED_V1=0123456789abcdef0123456789abcdef \
POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=55450 \
POSTGRES_USER=ezagent POSTGRES_PASSWORD=ezagent \
NO_PROXY=127.0.0.1,localhost \
mix test apps/ezagent_domain_identity/test/integration/cap_signing_notail_investigation_test.exs \
  --no-start --seed 0 --max-cases 1
```

结果：调查测试 `1 test, 0 failures`；core wildcard 回归 `20 tests, 0 failures`。

仓库 gate 也执行了 `MIX_DEPS_PATH=/Users/h2oslabs/Workspace/esr-ng/deps mix precommit`，
但不能在当前默认 test 环境完成：跨应用测试统一遇到既有 test DB 缺
`recipe_cap_bindings.gc_pruned_at`（Postgres `42703`），随后 web test setup 又因此
worktree 没有 `node_modules/xterm/css/xterm.css` 以 exit 2 退出。隔离且已迁移的
`capinv0714` 数据库上的上述目标测试均为 green；本调查没有迁移/改写默认测试库，也没有
为通过 gate 安装前端依赖。

## 先纠正一个 grounding：指定干净 dump 不能复现 196

对指定 dump 做全新 restore 后，数据库是 **7 users、50 kind_snapshots、13 个
users.caps_json 元素**。同一份 main 代码下：

| 时点 | backfill dry-run |
|---|---:|
| 下游应用启动前 | scanned 15 / would_sign 0 / quarantined 8 / skipped 7 |
| curl/py/cc 及其 domain 正常启动后（sandbox 内） | scanned 15 / would_sign 0 / quarantined 8 / skipped 7 |

因此旧 note 的 `196 = 6 + 189 + 1` **不是这份 dump 的干净可复现基线**；它依赖
当时 harness 已经写入/物化过的 throwaway DB 状态。`196` 的 bucket 不能继续当成
“从指定 dump 重新跑一定得到”的事实，尤其 `users.caps_json = 99` 与干净 dump 的
13 也不一致。若 coordinator 仍需复核 196 个对象，必须提供当时已变异的 DB 或
产生那 181 个额外 candidate 的精确前置操作。

这个差异不影响下面的逐类结论：测试另外创建了 fresh user、fresh curl agent、
recipe binding、SessionTemplate 和 session/chat materialization，直接检查正常路径
产出的 artifact 是否带 `signature + key_id + grantee_uri`。

## 实测逐类差分

`Cap.issue/3` 是唯一完整的 authorize → provenance → key-id → sign chokepoint
（`apps/ezagent_core/lib/ezagent/cap.ex:33-39,204-210`）。
`Cap.verified_set/2` 只是 dual-read 验证/过滤，不会补签。

| cap 类 | 正常重派生会签？ | 实测/绕过点 | 达成 0 尾巴的动作 |
|---|---|---|---|
| admin genesis 全通配 `any/any/any/any` | **当前激活不会；但 `Cap.issue` 能签** | `initial_caps_for_spawn/1` 直接放入 raw genesis（`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:81-92`）；raw shape 来自 `apps/ezagent_core/lib/ezagent/capability.ex:249-259` | 显式 `Cap.issue({:genesis, admin}, admin, genesis)` 并持久化/absorb signed artifact；无需 wildcard/genesis 签名豁免 |
| user `caps_json` 已存 seed | **否** | fresh raw seed 经过 `Users.create` 后，users row 与激活 snapshot 都仍未签；直写点 `apps/ezagent_domain_identity/lib/ezagent/users.ex:112-120`，激活只 merge + verify（`behavior/identity.ex:288-315`） | 对所有现存 authorizer cap 做显式 re-issue-signed，再原子改写 `caps_json`；随后重载 user snapshot |
| 新 user 的受支持授权入口 | **是** | fresh `Workspace.create_user(..., caps: "*")` 后，users row 与激活 snapshot 中的全通配 cap 均 signed；workspace user-admin 在 `apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_user_admin.ex:221-245` 调 `Cap.issue`；mix task 在 `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.create.ex:226-253` 调 `Cap.issue` | 保留入口；收紧/审计所有直接调用 `Users.create` 且传 raw cap 的 caller |
| user / agent / template 的 self `Identity.list_caps` | **否** | fresh user、fresh agent、fresh SessionTemplate 均产出 unsigned；直接构造在 `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:249-260`，随后只 `verified_set`（143-178） | 产品实现阶段把结构 cap 送入一个可证明 authority 的 `Cap.issue` 路径；修复后重激活/重建，或对现存 snapshot 显式 re-issue |
| agent self `Sandbox.update_config` | **否** | fresh direct lifecycle 与 curl materialization 都 unsigned；`behavior/identity.ex:208-246` 直接构造 | 同上；当前“只重激活”不会自愈 |
| agent self `ConfigEvolve.reconcile_cascade` | **否** | fresh direct lifecycle 与 curl materialization 都 unsigned；`behavior/identity.ex:208-246` 直接构造 | 同上；当前“只重激活”不会自愈 |
| agent recipe cap | **是** | fresh `Sandbox.read` recipe artifact 已签，activate 后仍签；`RecipeCapBinding.issue_and_upsert` 在 `apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex:58-67,139-155` 调 `Cap.issue` | 重新 materialize/刷新 binding version 可 re-issue；仅 activate 同一 binding version 不会重新签 |
| agent creator `Manage` | **是（fresh）** | fresh curl agent 创建后 creator 持有 signed Manage；入口 `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:841-878`，最终 grant adapter 在 `apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex:218-233` 调 `Cap.issue` | fresh 无动作；已有同 authority 的 unsigned cap 会触发 852-853 的幂等 skip，故旧数据要显式 re-issue |
| owner `Sandbox.destroy` / `Terminable.terminate` (`spawned_by`) | **是（fresh）** | 干净 real snapshot 中两类均 signed；正常 session materializer 在 `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex:245-303` 经 Identity.Grant → `Cap.issue` | fresh 无动作；已存在 unsigned 等价 cap 时幂等检查可能跳过，旧数据仍应显式 re-issue |
| SessionTemplate owner `Template:any within_workspace` | **是** | fresh root template 给 admin 新增 signed Template cap；构造/授权在 `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:706-743`，grant adapter 再进 `Cap.issue` | fresh 无动作；旧 owner cap 显式 re-issue，不能只依赖 create/activate |
| session participation / chat (`receive`, `remove_participant`, `assign_role`) | **fresh 物化会签；cold rehydrate 不重签** | fresh session + chat materialization 各新增一枚 signed artifact；随后真实 terminate + `SpawnRegistry.ensure_live`，全 durable inventory 不变。membership 路径 `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex:1240-1267` 经 Identity.Grant → `Cap.issue` | 新物化可签；rehydrate 不是升级操作。已有 unsigned cap 会被 `already_authorized?` 当作已满足而跳过，旧数据要显式 re-issue 或先安全替换 |
| orchestrator scoped / socialware recipe caps | **是（issue 路径）** | recipe 类已由 fresh binding 实测；orchestrator issue loop 明确在 `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex:74-98` 调 `Cap.issue`，definition agent 先 bind 再 spawn（`session_creator/definition_agents.ex:303-317,667-674`） | 重新 bind/materialize 可签；同版本 activate 不足，旧 artifact 应 refresh binding 或显式 re-issue |

### 差分的关键含义

1. **简单 boot/activate 不是升级操作。** 对指定 dump，启动前后 inventory 完全相同。
2. **“新路径能签”不等于“旧数据会自愈”。** 多处先用能力匹配/identity 判断“已有”再
   skip；legacy unsigned artifact 仍能在 dual-read 下满足这个判断。
3. 目前真正可通过正常重派生升级的是 **recipe binding 的重新 issue/upsert**；
   session/socialware/creator/template 的 fresh materialization 会签，但清理已有尾巴仍应
   使用显式 re-issue-signed，而不是假设一次 restart 会替换它们。

## 全通配 cap 根因

结论：**全通配 axes 可以签，不需要 genesis exemption。** 干净 core 测试同时证明：

- `Cap.issue({:genesis, admin}, admin, Capability.admin_genesis_cap())` 成功；
- 对 issue 完成后的 artifact 直接调用 `Signing.sign/2` 成功并可 verify；
- 对 raw `admin_genesis_cap()` 直接调用低层 `Signing.sign/2`，稳定抛出
  `ArgumentError: cap signing URI is not canonicalizable: nil`。

异常与 wildcard 无关。`Signing.sign/2` 接受的是**已准备好的 artifact**，payload
要求 `grantee_uri`、`key_id`、issuer、timestamp 都可 canonicalize
（`apps/ezagent_core/lib/ezagent/cap/signing.ex:104-124`）。raw genesis 还没有
`grantee_uri` 和 `key_id`，先在 `canon_uri(nil)` 失败
（`signing.ex:226-230`）。相反，各 wildcard axis 都有明确编码：atom `:any`
（196）、behavior `:any`（198）、instance `:any`（207）、workspace `:any`
（218）。coordinator harness 的 13/13 `ArgumentError` 是把 seed/proposal 当成
artifact 直接喂给低层 signer，而不是 wildcard crypto edge。

## 建议的 0-tail 实现顺序（供 coordinator 决策）

1. **先修 future issue sites，仍保持 dual-read。** 将 Identity 结构 cap
   （user/agent/template self Identity，以及 agent Sandbox/ConfigEvolve）接入明确 authority
   的 `Cap.issue`；不要仅给 signer 填字段绕过授权。
2. **做一个显式、幂等的 re-issue-signed pass。** 扫描 users row 和 snapshot 两个 durable
   home；对每个 currently-held authorizer cap 解析真实 owner/issuer，经 `Cap.issue` 重发，
   无法解析的 quarantine，不 blind-sign。它至少要覆盖：legacy `caps_json`、admin genesis、
   结构 cap，以及会被幂等 skip 的 session/creator/template artifacts。
3. **recipe 使用 refresh/upsert。** 重新 materialize definition/recipe binding，让其通过现有
   issue loop 产出 signed artifacts；不要指望同版本 activate。
4. **做独立 audit，不再用 EventLog backfill 数字当 gate。** 直接扫描两个 durable home，
   按 class 报 unsigned authorizer caps；sentinel 单列。目标必须是 0。
5. **只有 audit=0 后再 flip enforce。** 本调查没有、也不应修改
   `require_signature:true`。

最终 operational rule 很简单：**fresh 路径已经过 `Cap.issue` 的类继续正常物化；所有
历史 held artifact 统一显式 re-issue-signed；结构 cap 的 issue site 修复后再重激活。**
